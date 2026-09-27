// IncrementalMarkdownParser+InlineRollback.swift

import Foundation

struct InlineRollbackSnapshot: Sendable, Equatable {
    var frozenByteCount: Int
    var frozenLineCount: Int
    var frozenRuns: [InlineRun]
    var leftContext: Character?
    var carriedStyle: StyleFlags
}

private enum InlineOpenerKind: Sendable, Equatable {
    case backtick(Int)
    case emphasis(Character, Int)
    case bracket
    case strike
    case dollar
    case angle
    case parenMath
}

private struct InlineOpener: Sendable, Equatable {
    var kind: InlineOpenerKind
    var byteOffset: Int
    var line: Int
    var linkStage = 0
    var trailingTicks = 0
}

/// A forced checkpoint keeps just the open constructs that can change earlier output.
struct InlineRollbackState: Sendable, Equatable {
    var snapshot: InlineRollbackSnapshot?
    private var openers: [InlineOpener] = []
    private var observedByteCount = 0

    mutating func rememberForcedFreeze(
        _ text: String, startByte: Int, startLine: Int, snapshot newSnapshot: InlineRollbackSnapshot
    ) {
        let candidates = danglingOpeners(in: text, startByte: startByte, startLine: startLine)
        if snapshot == nil && !candidates.isEmpty { snapshot = newSnapshot }
        for opener in candidates {
            if !openers.contains(where: { $0.kind == opener.kind }) { openers.append(opener) }
        }
        observedByteCount = max(observedByteCount, startByte + text.utf8.count)
    }

    mutating func matchingOpenerLine(in content: String) -> Int? {
        guard !openers.isEmpty, content.utf8.count > observedByteCount else {
            observedByteCount = max(observedByteCount, content.utf8.count)
            return nil
        }
        let bytes = content.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: observedByteCount)
        let newText = String(content[start...])
        let prior = String(content[..<start].suffix(3))
        let lookbehind = prior.utf8.count
        let context = prior + newText
        let emphasis = scanEmphasisDelimiterRuns(in: context)
        var earliest: Int?

        for index in openers.indices {
            let opener = openers[index]
            let matched: Bool
            switch opener.kind {
            case .backtick(let length):
                matched = advanceBacktickRun(&openers[index].trailingTicks, through: newText, length: length)
            case .emphasis(let char, let length):
                matched = emphasis.contains { run in
                    run.char == char && run.length >= length && run.canClose &&
                    context.utf8.distance(from: context.startIndex, to: run.range.upperBound) > lookbehind &&
                    !isAmbiguousTrailingRun(run, in: context)
                }
            case .bracket:
                matched = advanceLinkStage(&openers[index].linkStage, through: newText)
            case .strike:
                matched = context.contains("~~")
            case .dollar:
                matched = newText.contains("$")
            case .angle:
                matched = newText.contains(">")
            case .parenMath:
                matched = context.contains("\\)")
            }
            if matched { earliest = min(earliest ?? opener.line, opener.line) }
        }

        // A trailing length-1 run might still widen into "**"/"__" on the next byte (see
        // `nextEmphasisStep`'s `.pending`); hold `observedByteCount` at its start so it stays
        // in `newText`, not the lookbehind, until it resolves.
        if let trailing = emphasis.last, trailing.range.upperBound == context.endIndex,
           isAmbiguousTrailingRun(trailing, in: context) {
            let holdBackBytes = context.utf8.distance(from: trailing.range.lowerBound, to: context.endIndex)
            observedByteCount = max(observedByteCount, content.utf8.count - holdBackBytes)
        } else {
            observedByteCount = content.utf8.count
        }
        return earliest
    }
}

/// A single trailing `*`/`_` with nothing after it might still widen into a longer run on the
/// next append (mirrors `nextEmphasisStep`'s `.pending` case) -- not yet a settled closer.
private func isAmbiguousTrailingRun(_ run: EmphasisDelimiterRun, in context: String) -> Bool {
    run.length == 1 && run.range.upperBound == context.endIndex
}

private func danglingOpeners(in text: String, startByte: Int, startLine: Int) -> [InlineOpener] {
    let chars = Array(text)
    var result: [InlineOpener] = []
    var byte = startByte
    var line = startLine
    var code: InlineOpener?
    var strike: InlineOpener?
    var dollar: InlineOpener?
    var angle: InlineOpener?
    var bracket: InlineOpener?
    var parenMath: InlineOpener?
    var index = 0

    while index < chars.count {
        let char = chars[index]
        let next = index + 1 < chars.count ? chars[index + 1] : nil
        if char == "\\", next == "(" {
            parenMath = InlineOpener(kind: .parenMath, byteOffset: byte, line: line)
        } else if char == "\\", next == ")" {
            parenMath = nil
        } else if char == "`" {
            let length = chars[index...].prefix(while: { $0 == "`" }).count
            if let current = code, length >= backtickLength(current.kind) { code = nil }
            else if code == nil { code = InlineOpener(kind: .backtick(length), byteOffset: byte, line: line) }
        } else if code == nil {
            switch char {
            case "~" where next == "~":
                strike = strike == nil ? InlineOpener(kind: .strike, byteOffset: byte, line: line) : nil
            case "$":
                dollar = dollar == nil ? InlineOpener(kind: .dollar, byteOffset: byte, line: line) : nil
            case "<":
                angle = InlineOpener(kind: .angle, byteOffset: byte, line: line)
            case ">":
                angle = nil
            case "[":
                bracket = InlineOpener(kind: .bracket, byteOffset: byte, line: line)
            case "]":
                if bracket != nil { bracket!.linkStage = 1 }
            case "(":
                if bracket?.linkStage == 1 { bracket!.linkStage = 2 }
            case ")":
                if bracket?.linkStage == 2 { bracket = nil }
            default:
                if bracket?.linkStage == 1 { bracket!.linkStage = 0 }
            }
        }
        if char == "\n" { line += 1 }
        byte += String(char).utf8.count
        index += 1
    }

    for candidate in [code, strike, dollar, angle, bracket, parenMath] {
        if let candidate { result.append(candidate) }
    }
    result.append(contentsOf: danglingEmphasisOpeners(in: text, startByte: startByte, startLine: startLine))
    return result
}

/// One forward walk over `text` locates every dangling opener's byte offset and line, instead of
/// re-scanning the prefix from scratch per opener (which was O(n) per opener, O(n*k) overall).
private func danglingEmphasisOpeners(in text: String, startByte: Int, startLine: Int) -> [InlineOpener] {
    let delimiterRuns = scanEmphasisDelimiterRuns(in: text)
    let dangling = matchEmphasisDelimiters(delimiterRuns).danglingOpeners
    guard !dangling.isEmpty else { return [] }

    let order = dangling.indices.sorted { dangling[$0].range.lowerBound < dangling[$1].range.lowerBound }
    var offsets = [Int](repeating: 0, count: dangling.count)
    var lines = [Int](repeating: 0, count: dangling.count)

    var byte = startByte
    var line = startLine
    var cursor = text.startIndex
    for index in order {
        let target = dangling[index].range.lowerBound
        while cursor < target {
            let char = text[cursor]
            byte += String(char).utf8.count
            if char == "\n" { line += 1 }
            cursor = text.index(after: cursor)
        }
        offsets[index] = byte
        lines[index] = line
    }

    return dangling.indices.map { index in
        InlineOpener(
            kind: .emphasis(dangling[index].char, dangling[index].length),
            byteOffset: offsets[index], line: lines[index]
        )
    }
}

private func backtickLength(_ kind: InlineOpenerKind) -> Int {
    if case .backtick(let length) = kind { return length }
    return 0
}

private func advanceBacktickRun(_ run: inout Int, through text: String, length: Int) -> Bool {
    for char in text {
        if char == "`" {
            run += 1
            if run >= length { return true }
        } else {
            run = 0
        }
    }
    return false
}

private func advanceLinkStage(_ stage: inout Int, through text: String) -> Bool {
    for char in text {
        switch stage {
        case 0: if char == "]" { stage = 1 }
        case 1: stage = char == "(" ? 2 : 0
        default: if char == ")" { return true }
        }
    }
    return false
}

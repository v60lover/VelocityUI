// IncrementalMarkdownParser+InlineWindow.swift

import Foundation

/// Keeps the tokenized prefix of one open block while its ambiguous suffix changes.
struct OpenInlineWindow: Sendable, Equatable {
    var identity = -1
    var kind: MarkdownBlockKind?
    var frozenByteCount = 0
    var frozenLineCount = 0
    var frozenRuns: [InlineRun] = []
    var leftContext: Character?
    var carriedStyle: StyleFlags = []
    /// Ambiguous emphasis across checkpoints needs the complete block for delimiter pairing.
    var reparseWholeBlock = false
    /// Uniquely-owned copy of `frozenRuns + hot`, reused across calls so merging the small
    /// `hot` suffix doesn't force a COW copy of the whole frozen text every keystroke. Rebuilt
    /// from `frozenRuns` only when the frozen prefix itself grew; see `mergeIntoCachedResult`.
    var cachedResult: [InlineRun] = []
    var cachedResultFrozenRunCount = 0
    var cachedResultFrozenLastByteCount = 0
    var rollback = InlineRollbackState()
    var rollbackCount = 0
    var lastInvalidatedLineRange: Range<Int>?
    /// Byte length `content` had when the last rollback fired. The forced-freeze cap stays off
    /// so `safePrefixLength` gets first crack at resettling normally; it clears as soon as that
    /// succeeds, or -- if some other opener blocks it forever -- once content has grown past this
    /// point by another cap window, so the hold itself can never disable the cap indefinitely.
    var rollbackHoldUntilSafeByte: Int?

    static let unsettledLineLimit = 8
    static let unsettledByteLimit = 128

    mutating func runs(
        for content: String, kind newKind: MarkdownBlockKind, identity newIdentity: Int
    ) -> (runs: [InlineRun], tokenizedBytes: Int) {
        if identity != newIdentity || kind != newKind || content.utf8.count < frozenByteCount {
            let priorCount = rollbackCount
            self = OpenInlineWindow(identity: newIdentity, kind: newKind)
            rollbackCount = priorCount
        }

        if let line = rollback.matchingOpenerLine(in: content) {
            let currentBytes = content.utf8
            let currentSuffixStart = currentBytes.index(currentBytes.startIndex, offsetBy: frozenByteCount)
            let lastLine = frozenLineCount
                + content[currentSuffixStart...].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            lastInvalidatedLineRange = line..<(lastLine + 1)
            rollbackCount += 1
            if let snapshot = rollback.snapshot {
                frozenByteCount = snapshot.frozenByteCount
                frozenLineCount = snapshot.frozenLineCount
                frozenRuns = snapshot.frozenRuns
                leftContext = snapshot.leftContext
                carriedStyle = snapshot.carriedStyle
                // frozenRuns just changed out from under the merge cache -- force a rebuild
                // next time instead of trusting a stale byte-count match.
                cachedResult = []
                cachedResultFrozenRunCount = -1
            }
            rollback = InlineRollbackState()
            rollbackHoldUntilSafeByte = content.utf8.count
        }

        let bytes = content.utf8
        let suffixStart = bytes.index(bytes.startIndex, offsetBy: frozenByteCount)
        var unsettled = String(content[suffixStart...])
        if !reparseWholeBlock {
            let context = (leftContext.map(String.init) ?? "") + unsettled
            reparseWholeBlock = scanEmphasisDelimiterRuns(in: context).contains {
                $0.canOpen && $0.canClose
            }
        }
        let safeCount = safePrefixLength(in: unsettled, leftContext: leftContext)
        var tokenizedBytes = 0
        if safeCount > 0 {
            let cut = unsettled.index(unsettled.startIndex, offsetBy: safeCount)
            let settled = String(unsettled[..<cut])
            let parsed = tokenizedWithContext(settled)
            tokenizedBytes += settled.utf8.count + (leftContext.map { String($0).utf8.count } ?? 0)
            appendRuns(parsed, to: &frozenRuns)
            frozenByteCount += settled.utf8.count
            frozenLineCount += settled.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            leftContext = settled.last
            unsettled = String(unsettled[cut...])
            rollbackHoldUntilSafeByte = nil
        }

        let holdingAfterRollback = rollbackHoldUntilSafeByte.map {
            content.utf8.count <= $0 + Self.unsettledByteLimit
        } ?? false
        if !holdingAfterRollback { rollbackHoldUntilSafeByte = nil }

        if !holdingAfterRollback && !hasGrowingURL(in: unsettled) &&
           (unsettled.utf8.count > Self.unsettledByteLimit ||
           unsettled.reduce(0, { $0 + ($1 == "\n" ? 1 : 0) }) > Self.unsettledLineLimit) {
            let chars = Array(unsettled)
            let freezeCount = max(0, chars.count - 8)
            if freezeCount > 0 {
                let cut = unsettled.index(unsettled.startIndex, offsetBy: freezeCount)
                let settled = String(unsettled[..<cut])
                if settled.contains("*") || settled.contains("_") { reparseWholeBlock = true }
                let startByte = frozenByteCount
                let startLine = frozenLineCount
                let snapshot = InlineRollbackSnapshot(
                    frozenByteCount: frozenByteCount, frozenLineCount: frozenLineCount,
                    frozenRuns: frozenRuns, leftContext: leftContext, carriedStyle: carriedStyle
                )
                rollback.rememberForcedFreeze(
                    settled, startByte: startByte, startLine: startLine, snapshot: snapshot
                )
                let parsed = tokenizedWithContext(settled)
                tokenizedBytes += settled.utf8.count + (leftContext.map { String($0).utf8.count } ?? 0)
                appendRuns(parsed, to: &frozenRuns)
                carriedStyle = styleAtEnd(of: settled)
                frozenByteCount += settled.utf8.count
                frozenLineCount += settled.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                leftContext = settled.last
                unsettled = String(unsettled[cut...])
            }
        }

        let hot = tokenizedWithContext(unsettled)
        tokenizedBytes += unsettled.utf8.count + (leftContext.map { String($0).utf8.count } ?? 0)
        if reparseWholeBlock {
            return (inlineRuns(content), tokenizedBytes + content.utf8.count)
        }
        mergeIntoCachedResult(hot)
        return (cachedResult, tokenizedBytes)
    }

    /// Merges `hot` onto a persistently-owned copy of `frozenRuns` instead of re-sharing
    /// `frozenRuns`'s buffer on every call -- `appendRuns`'s in-place `+=` on the boundary run
    /// would otherwise force a full copy of the frozen text's buffer on every keystroke. Rebuilt
    /// from `frozenRuns` only when the frozen prefix actually grew (a real freeze, not every
    /// append); otherwise the previous merge is undone -- cheap, bounded by the small `hot`
    /// window -- and redone with the fresh runs.
    private mutating func mergeIntoCachedResult(_ hot: [InlineRun]) {
        let lastByteCount = frozenRuns.last?.text.utf8.count ?? 0
        if cachedResultFrozenRunCount != frozenRuns.count || cachedResultFrozenLastByteCount != lastByteCount {
            cachedResult = frozenRuns
            cachedResultFrozenRunCount = frozenRuns.count
            cachedResultFrozenLastByteCount = lastByteCount
        } else {
            cachedResult.removeLast(cachedResult.count - cachedResultFrozenRunCount)
            if cachedResultFrozenRunCount > 0 {
                let lastIndex = cachedResultFrozenRunCount - 1
                let bytes = cachedResult[lastIndex].text.utf8
                let cut = bytes.index(bytes.startIndex, offsetBy: cachedResultFrozenLastByteCount)
                cachedResult[lastIndex].text.removeSubrange(cut..<cachedResult[lastIndex].text.endIndex)
            }
        }
        appendRuns(hot, to: &cachedResult)
    }

    private func tokenizedWithContext(_ text: String) -> [InlineRun] {
        var runs = inlineRuns((leftContext.map(String.init) ?? "") + text)
        if leftContext != nil, !runs.isEmpty {
            runs[0].text.removeFirst()
            if runs[0].text.isEmpty { runs.removeFirst() }
        }
        if !carriedStyle.isEmpty {
            for index in runs.indices { runs[index].style.formUnion(carriedStyle) }
        }
        return runs
    }

    private func styleAtEnd(of text: String) -> StyleFlags {
        tokenizedWithContext(text + "x").last?.style ?? carriedStyle
    }
}

private func hasGrowingURL(in text: String) -> Bool {
    // A URL is still growing if it hasn't hit a terminator yet, or that terminator is still
    // inside the last 8 retained characters -- cutting now would slice through it.
    for scheme in ["https://", "http://"] {
        guard let range = text.range(of: scheme, options: .backwards) else { continue }
        let rest = text[range.upperBound...]
        guard let terminator = rest.firstIndex(where: { $0.isWhitespace || $0 == "<" }) else { return true }
        if text.distance(from: terminator, to: text.endIndex) < 8 { return true }
    }
    return false
}

extension IncrementalMarkdownParser {
    /// Number of late inline matches that invalidated frozen lines in this parser instance.
    var inlineRollbackCount: Int { inlineWindow.rollbackCount }
    /// Zero-based open-block line range from the most recent rollback.
    var lastInvalidatedInlineLineRange: Range<Int>? { inlineWindow.lastInvalidatedLineRange }
}

private func appendRuns(_ incoming: [InlineRun], to result: inout [InlineRun]) {
    guard let first = incoming.first else { return }
    if let last = result.indices.last, result[last].style == first.style,
       result[last].url == nil, result[last].mathSource == nil,
       first.url == nil, first.mathSource == nil {
        result[last].text += first.text
    } else {
        result.append(first)
    }
    result.append(contentsOf: incoming.dropFirst())
}

/// A checkpoint needs a plain character after every completed construct and eight characters
/// of lookahead. Holding potential openers is conservative: it may postpone a freeze, never
/// commit text that a later byte can reclassify.
private func safePrefixLength(in text: String, leftContext: Character?) -> Int {
    let chars = Array(text)
    guard chars.count > 8 else { return 0 }
    var safe = 0
    var i = 0
    var italic: Character?
    var bold: Character?
    var strike = false
    let contextLength = leftContext == nil ? 0 : 1
    let classified = (leftContext.map(String.init) ?? "") + text
    let delimiterRuns = scanEmphasisDelimiterRuns(in: classified)
    var delimiterIndex = 0

    while i < chars.count {
        let char = chars[i]
        switch protectedEnd(in: chars, at: i, previous: i == 0 ? leftContext : chars[i - 1]) {
        case .blocked:
            return safe
        case .advance(let end):
            i = end
            continue
        case .none:
            break
        }
        if char == "\\" {
            if i + 1 == chars.count { break }
            i += 2
            continue
        }
        if char == "~", i + 1 < chars.count, chars[i + 1] == "~" {
            strike.toggle()
            i += 2
            continue
        }
        if char == "*" || char == "_" {
            let count = scanEmphasisStep(
                text: classified,
                at: classified.index(classified.startIndex, offsetBy: contextLength + i),
                runs: delimiterRuns, runIndex: &delimiterIndex,
                italic: &italic, bold: &bold
            )
            i += count
            continue
        }
        if char == "!", i + 1 == chars.count { break }
        if italic == nil, bold == nil, !strike, i < chars.count - 8 { safe = i + 1 }
        i += 1
    }
    return safe
}

private func scanEmphasisStep(
    text: String, at index: String.Index, runs: [EmphasisDelimiterRun], runIndex: inout Int,
    italic: inout Character?, bold: inout Character?
) -> Int {
    let step = nextEmphasisStep(
        chars: text[index...], text: text, delimiterRuns: runs, runIndex: &runIndex,
        italicOpenChar: &italic, boldOpenChar: &bold
    )
    switch step {
    case .literal(let count), .pending(let count), .toggle(_, let count): return count
    }
}

private enum ProtectedEnd {
    case none
    case blocked
    case advance(Int)
}

private func protectedEnd(in chars: [Character], at i: Int, previous: Character?) -> ProtectedEnd {
    let char = chars[i]
    if char == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
        guard let close = findSequence(["\\", ")"], in: chars, from: i + 2) else { return .blocked }
        return .advance(close + 2)
    }
    if char == "`" {
        let length = chars[i...].prefix(while: { $0 == "`" }).count
        let marker = Array(repeating: Character("`"), count: length)
        guard let close = findSequence(marker, in: chars, from: i + length) else { return .blocked }
        return .advance(close + length)
    }
    if char == "[" || (char == "!" && i + 1 < chars.count && chars[i + 1] == "[") {
        let bracket = char == "!" ? i + 1 : i
        guard let close = chars[(bracket + 1)...].firstIndex(of: "]"),
              close + 1 < chars.count, chars[close + 1] == "(",
              let paren = chars[(close + 2)...].firstIndex(of: ")") else { return .blocked }
        return .advance(paren + 1)
    }
    if char == "<" {
        guard let close = chars[(i + 1)...].firstIndex(of: ">") else { return .blocked }
        return .advance(close + 1)
    }
    if char == "$", i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != "\n" {
        guard let close = chars[(i + 1)...].firstIndex(of: "$") else { return .blocked }
        return .advance(close + 1)
    }
    if char == "h", previous?.isLetter != true, previous?.isNumber != true,
       String(chars[i...].prefix(8)).hasPrefix("http") {
        guard let end = chars[i...].firstIndex(where: { $0.isWhitespace || $0 == "<" }) else { return .blocked }
        return .advance(end)
    }
    return .none
}

private func findSequence(_ needle: [Character], in haystack: [Character], from start: Int) -> Int? {
    guard start + needle.count <= haystack.count else { return nil }
    for index in start...(haystack.count - needle.count) where haystack[index..<(index + needle.count)].elementsEqual(needle) {
        return index
    }
    return nil
}

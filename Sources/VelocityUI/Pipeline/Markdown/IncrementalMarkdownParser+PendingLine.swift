// IncrementalMarkdownParser+PendingLine.swift

import Foundation

/// Caches the still-open, not-yet-newline-terminated trailing line's block kind once it can no
/// longer change, so re-materializing it on every keystroke costs O(new bytes) instead of
/// O(whole-line). Only paragraph/blockquote/list-item lines settle here. Headings stay on the
/// slow path on purpose: real headings are short, so the O(line) re-scan per append (quadratic
/// only for a multi-KB single-line heading) is an accepted cost. Fences/mathBlock/table/
/// thematicBreak/image are handled by other fast paths or stay on the slow `step()` path.
struct PendingLineFastPath: Equatable {
    enum Kind: Equatable {
        case paragraph
        case blockquote
        case listItem(ordered: Bool, number: Int, depth: Int, checked: Bool?)
    }

    var kind: Kind
    /// Raw growing line text, byte-for-byte what `step()` would store in `OpenBlockCache.text`.
    var text: String
    /// listItem only: `text` with its leading marker stripped, fed straight into `inlineWindow`
    /// instead of recomputing `stripListMarker(text)` (an O(text length) copy) every call.
    var strippedText: String?
    /// UTF-8 bytes of the pending line already folded into `text`/`strippedText`.
    var consumedByteCount: Int
}

extension IncrementalMarkdownParser {
    /// First non-whitespace characters that could still start a fence, math block, heading, or
    /// image -- anything else guarantees the line can only ever resolve as `.paragraph`. `-`,
    /// `*`, `_` also gate `.listItem` vs `.thematicBreak` ambiguity below.
    private static let pendingLineTriggerChars: Set<Character> = ["`", "~", "#", "$", "\\", "!"]
    private static let dashLikeMarkerChars: Set<Character> = ["-", "*", "_"]

    /// Tries to settle the still-open `line`'s block kind from a bounded prefix. Returns nil
    /// when settlement isn't possible yet (still inside an ambiguous prefix window -- e.g. `-`
    /// could still become `---`) or the kind isn't one this fast path handles.
    static func settlePendingLineFastPath(_ line: Substring) -> PendingLineFastPath? {
        let spaces = leadingSpaceCount(line)
        guard spaces < 4, let first = line.dropFirst(spaces).first else { return nil }

        if first == ">" {
            guard isBlockquoteMarkerLine(line) else { return nil }
            return PendingLineFastPath(kind: .blockquote, text: String(line), consumedByteCount: line.utf8.count)
        }
        if first == "#" || pendingLineTriggerChars.contains(first) {
            return nil  // heading/fence/mathBlock/image opener -- stay on the slow path.
        }
        if dashLikeMarkerChars.contains(first) || first == "+" || first.isNumber {
            return settleListLikeFastPath(line, spaces: spaces, first: first)
        }
        return PendingLineFastPath(kind: .paragraph, text: String(line), consumedByteCount: line.utf8.count)
    }

    /// `-`/`*`/`_` double as thematic-break markers, so a bare "marker + space" isn't enough to
    /// settle `.listItem` -- the rest of the line could still turn out to be "- - -" (3+ of the
    /// same char, only spaces between). Settling waits for one character that's neither the
    /// marker char nor a space, which rules `isThematicBreakLine` out for good. `+` and digit
    /// markers have no such overlap and settle as soon as `listMarkerInfo` resolves.
    private static func settleListLikeFastPath(
        _ line: Substring, spaces: Int, first: Character
    ) -> PendingLineFastPath? {
        guard let info = listMarkerInfo(line) else { return nil }
        // Wait until a possible task marker is complete before caching the list kind and
        // stripped text; either can change while "[ ]" or "[x]" is still arriving.
        let markerContent = line.dropFirst(spaces).drop { $0 != " " }.drop { $0 == " " }
        if markerContent.first == "[" {
            let prefix = Array(markerContent.prefix(3))
            if prefix.count < 3 && (prefix.count == 1 || prefix[1] == " " || prefix[1] == "x" || prefix[1] == "X") {
                return nil
            }
            if markerContent.count == 3, Self.taskMarkerChecked(markerContent) != nil {
                return nil
            }
        }
        if dashLikeMarkerChars.contains(first) {
            let rest = line.dropFirst(spaces + 2)  // marker char + its required space
            guard rest.contains(where: { $0 != first && $0 != " " }) else { return nil }
        }
        let markerByteLength = listMarkerPrefixByteLength(line.dropFirst(spaces))
        let strippedStart = line.index(line.startIndex, offsetBy: spaces + markerByteLength)
        var fast = PendingLineFastPath(
            kind: .listItem(ordered: info.ordered, number: info.number, depth: info.depth, checked: info.checked),
            text: String(line), consumedByteCount: line.utf8.count
        )
        fast.strippedText = String(line[strippedStart...])
        return fast
    }

    /// Byte length of `stripListMarker`'s leading-marker match against `rest` (the line with
    /// leading spaces already dropped) -- mirrors its char classes exactly so the two never
    /// disagree about where the marker ends.
    private static func listMarkerPrefixByteLength(_ rest: Substring) -> Int {
        var s = rest
        s = s.drop { $0 == "-" || $0 == "*" || $0 == "+" || $0.isNumber || $0 == "." || $0 == ")" }
        s = s.drop { $0 == " " }
        if Self.taskMarkerChecked(s) != nil {
            s = s.dropFirst(3).drop { $0 == " " }
        }
        return rest.utf8.count - s.utf8.count
    }

    /// Extends an already-settled fast path with newly-arrived bytes from `line` -- an O(delta)
    /// append, never re-deriving `text`/`strippedText` from scratch. Returns the delta byte
    /// count copied (0 if `line` hasn't grown since the last call).
    @discardableResult
    static func extendPendingLineFastPath(_ fast: inout PendingLineFastPath, line: Substring) -> Int {
        guard fast.consumedByteCount < line.utf8.count else { return 0 }
        let bytes = line.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: fast.consumedByteCount)
        let delta = line[start...]
        let deltaByteCount = line.utf8.count - fast.consumedByteCount
        fast.text += delta
        if fast.strippedText != nil { fast.strippedText! += delta }
        fast.consumedByteCount = line.utf8.count
        return deltaByteCount
    }
}

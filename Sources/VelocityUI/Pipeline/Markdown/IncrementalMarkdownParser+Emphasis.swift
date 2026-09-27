// IncrementalMarkdownParser+Emphasis.swift

import Foundation

/// One delimiter run of consecutive `*`/`_`, classified by CommonMark's left/right-flanking rule
/// (spec 6.2, cmark's `scan_delims`). Only lengths 1/2/3 are recognized as a unit; 4+ is literal
/// (matches the old naive toggler's `*`/`**`/`***` special-casing, not cmark's general algorithm).
struct EmphasisDelimiterRun {
    var char: Character
    var length: Int
    var canOpen: Bool
    var canClose: Bool
    var range: Range<String.Index>
}

private func isUnicodeWhitespace(_ c: Character) -> Bool {
    c.isWhitespace
}

/// CommonMark's "punctuation" class for flanking: ASCII punctuation plus Unicode punctuation/symbol.
private func isUnicodePunctuation(_ c: Character) -> Bool {
    for scalar in c.unicodeScalars {
        let props = scalar.properties
        switch props.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            continue
        }
    }
    return false
}

/// Scans `text` for `*`/`_` runs and classifies each by CommonMark's left/right-flanking rule,
/// using the character immediately before/after (string edges count as whitespace). `_` additionally
/// refuses to open/close when both-flanking unless punctuation-adjacent, so `snake_case` stays literal
/// while intraword `*` (`a*b*c`) is allowed to pair, per spec 6.2.
nonisolated func scanEmphasisDelimiterRuns(in text: String) -> [EmphasisDelimiterRun] {
    var runs: [EmphasisDelimiterRun] = []
    var idx = text.startIndex
    while idx < text.endIndex {
        let c = text[idx]
        guard c == "*" || c == "_" else {
            idx = text.index(after: idx)
            continue
        }
        var end = idx
        while end < text.endIndex, text[end] == c {
            end = text.index(after: end)
        }
        let length = text.distance(from: idx, to: end)

        let before: Character? = idx > text.startIndex ? text[text.index(before: idx)] : nil
        let after: Character? = end < text.endIndex ? text[end] : nil

        let followedByWhitespace = after.map(isUnicodeWhitespace) ?? true
        let followedByPunctuation = after.map(isUnicodePunctuation) ?? false
        let precededByWhitespace = before.map(isUnicodeWhitespace) ?? true
        let precededByPunctuation = before.map(isUnicodePunctuation) ?? false

        let leftFlanking = !followedByWhitespace && (!followedByPunctuation || precededByWhitespace || precededByPunctuation)
        let rightFlanking = !precededByWhitespace && (!precededByPunctuation || followedByWhitespace || followedByPunctuation)

        let canOpen: Bool
        let canClose: Bool
        if c == "*" {
            canOpen = leftFlanking
            canClose = rightFlanking
        } else {
            canOpen = leftFlanking && (!rightFlanking || precededByPunctuation)
            canClose = rightFlanking && (!leftFlanking || followedByPunctuation)
        }

        // Only lengths 1/2/3 participate in matching (see doc comment); a longer run is literal.
        if length >= 1 && length <= 3 {
            runs.append(EmphasisDelimiterRun(char: c, length: length, canOpen: canOpen, canClose: canClose, range: idx..<end))
        }
        idx = end
    }
    return runs
}

/// What `inlineRuns`'s main loop should do at a `*`/`_` position.
enum EmphasisStep {
    case literal(count: Int)
    case toggle(StyleFlags, count: Int)
    /// Consume `count` chars without appending or toggling -- a single trailing marker with
    /// nothing after it, which might still widen into "**"/"__" on the next append. Matches the
    /// pre-flanking-rules behavior: it neither renders nor commits, so a still-growing block's
    /// final flush just keeps whatever flags were already open.
    case pending(count: Int)
}

/// Decides the action for the `*`/`_` run starting at `chars.startIndex`, using the precomputed
/// `delimiterRuns` and the currently-open marker state (`italicOpenChar`/`boldOpenChar` -- the
/// character, `*` or `_`, of whichever run is presently open, so the two markers never cross-close
/// each other). Advances `runIndex` and updates the open-char state in place; the caller just
/// applies the returned step to `buffer`/`flags`/`chars`.
func nextEmphasisStep(
    chars: Substring,
    text: String,
    delimiterRuns: [EmphasisDelimiterRun],
    runIndex: inout Int,
    italicOpenChar: inout Character?,
    boldOpenChar: inout Character?
) -> EmphasisStep {
    let first = chars.first!

    // Advance to the run starting at this position. Every `*`/`_` position has a corresponding
    // entry unless its run is 4+ long (never recorded -- see `scanEmphasisDelimiterRuns`), in
    // which case each of its characters falls through as literal.
    while runIndex < delimiterRuns.count, delimiterRuns[runIndex].range.lowerBound < chars.startIndex {
        runIndex += 1
    }
    guard runIndex < delimiterRuns.count, delimiterRuns[runIndex].range.lowerBound == chars.startIndex else {
        return .literal(count: 1)
    }
    let run = delimiterRuns[runIndex]
    runIndex += 1
    let consumeLen = min(run.length, 3)

    // Only a single trailing marker with truly nothing after it (not even more of the same
    // char) is ambiguous -- it might still widen into "**"/"__" on the next append, same as the
    // old pre-flanking-rules guard. A run that's already 2-3 long, or one that's followed by
    // more text, is a complete, final shape: for a SEALED block `text` never grows again, so
    // deferring it here would wrongly strip a legitimate trailing closer (e.g. "**bold**").
    if consumeLen == 1, run.range.upperBound == text.endIndex {
        return .pending(count: consumeLen)
    }

    if consumeLen >= 3, run.canClose, boldOpenChar == first, italicOpenChar == first {
        boldOpenChar = nil
        italicOpenChar = nil
        return .toggle([.bold, .italic], count: 3)
    }
    if consumeLen >= 2, run.canClose, boldOpenChar == first {
        boldOpenChar = nil
        return .toggle(.bold, count: 2)
    }
    if run.canClose, italicOpenChar == first {
        italicOpenChar = nil
        return .toggle(.italic, count: 1)
    }
    if consumeLen >= 3, run.canOpen {
        boldOpenChar = first
        italicOpenChar = first
        return .toggle([.bold, .italic], count: 3)
    }
    if consumeLen >= 2, run.canOpen {
        boldOpenChar = first
        return .toggle(.bold, count: 2)
    }
    if run.canOpen {
        italicOpenChar = first
        return .toggle(.italic, count: 1)
    }
    // Neither opens nor closes under flanking rules (whitespace-flanked "* *", intraword "_"
    // like snake_case) -- literal, per CommonMark 6.2.
    return .literal(count: consumeLen)
}

/// A matched (opener, closer) pair of same-length delimiter runs — the span between them gets
/// `.italic` (length 1), `.bold` (length 2), or both (length 3).
struct EmphasisMatch {
    var opener: EmphasisDelimiterRun
    var closer: EmphasisDelimiterRun
}

/// Left-to-right delimiter-stack pass (cmark's `process_emphasis`, restricted to exact-length
/// matching). Each closer pops the nearest same-char/same-length open opener and discards anything
/// above it (bypassed, so literal). Runs never closed are `danglingOpeners`.
///
/// `inlineRuns` uses the simpler single-open-marker toggle in `nextEmphasisStep`.
/// The open-block rollback window uses `danglingOpeners` to find possible late closers.
func matchEmphasisDelimiters(_ runs: [EmphasisDelimiterRun]) -> (matches: [EmphasisMatch], danglingOpeners: [EmphasisDelimiterRun]) {
    var stack: [EmphasisDelimiterRun] = []
    var matches: [EmphasisMatch] = []
    for run in runs {
        if run.canClose {
            if let openerIndex = stack.lastIndex(where: { $0.char == run.char && $0.length == run.length && $0.canOpen }) {
                matches.append(EmphasisMatch(opener: stack[openerIndex], closer: run))
                stack.removeSubrange(openerIndex...)
                continue
            }
        }
        if run.canOpen {
            stack.append(run)
        }
        // else: neither opens nor closes (or closer found no match and can't open either) -> literal, drop.
    }
    return (matches, stack)
}

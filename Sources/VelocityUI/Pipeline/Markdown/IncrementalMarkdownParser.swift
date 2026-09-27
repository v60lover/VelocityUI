// IncrementalMarkdownParser.swift

import Foundation
import CoreGraphics

// MARK: - MarkdownBlockKind

/// Per-column GFM table alignment, parsed from the delimiter row's leading/trailing `:`
/// (`:---` left, `:--:` center, `---:` right, `---` no alignment specified).
public enum TableColumnAlignment: Sendable, Equatable, Hashable {
    case left, center, right, none
}

/// The markdown block shapes this parser recognizes. Drives which `TextDescriptor` style
/// `IncrementalMarkdownParser.blocks(itemID:width:)` picks — with one exception (`.image`,
/// which maps to `FragmentContent.image` instead), everything else renders as styled text
/// (`Block` only wraps `.text`/`.image`/`.geometry` — see `Block.swift`).
public enum MarkdownBlockKind: Sendable, Equatable, Hashable {
    case paragraph
    case heading(level: Int)
    case codeFence(language: String?)
    /// `number` is the literal digit run the source used (e.g. `3.` -> 3), meaningless when
    /// `ordered` is false. `depth` is the nesting level inferred from leading indentation.
    /// `checked` is nil for a plain list item, `false`/`true` for a GFM task item's `[ ]`/`[x]`
    /// marker — nil is distinct from `false` so `style()` can tell "no checkbox" from "unchecked
    /// checkbox" and only swap in the checkbox glyph for an actual task item.
    case listItem(ordered: Bool, number: Int, depth: Int, checked: Bool?)
    case blockquote
    /// A GFM table, grouped into ONE block from a header row + delimiter row + zero or more
    /// body rows. `alignments` (one per column, from the delimiter row) lives here because
    /// render styling switches on it independent of cell text; the actual grid — header row
    /// plus body rows, each cell tokenized via `inlineRuns(_:)` — lives in
    /// `ParsedMDBlock.tableRows`, not in this case.
    case table(alignments: [TableColumnAlignment])
    /// A `---`/`***`/`___` rule line.
    case thematicBreak
    /// Block LaTeX math (`$$...$$` or `\[...\]`), parallel to `.codeFence`. `text` (via
    /// `style()`) holds the raw TeX with delimiter lines stripped, same convention as
    /// `.codeFence` stripping its fence markers.
    case mathBlock
    /// A markdown image (`![alt](url)`) alone on its own line. Block-level only — an image
    /// mixed into running paragraph text is out of scope (`Fragment` carries one
    /// `FragmentContent` per block, and adding mixed text+image content per block is a
    /// materially bigger change). Alt text is parsed to validate the syntax but not stored:
    /// nothing in the codebase consumes an image alt/accessibility label today.
    case image(url: URL)
}

/// A styled span within a text block's content, produced by `inlineRuns(_:)`. `url` is only
/// meaningful when `style` contains `.link`.
struct InlineRun: Equatable, Sendable {
    var text: String
    var style: StyleFlags
    var url: String?
    /// Raw TeX source when this run is inline math (`$...$` / `\(...\)`); nil otherwise. A
    /// dedicated field rather than a `StyleFlags` bit, because the payload is data (the TeX
    /// string), not a style toggle. `text` also carries the same raw TeX so a caller that
    /// doesn't branch on `mathSource` (everything before the inline-math renderer lands) still
    /// shows literal text instead of nothing.
    var mathSource: String? = nil
}

/// Inline markdown emphasis a run can carry, independent of the block-level `MarkdownBlockKind`.
/// Mirrors `VFontTraits`'s OptionSet shape (NodeTable.swift).
struct StyleFlags: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let bold = StyleFlags(rawValue: 1 << 0)
    static let italic = StyleFlags(rawValue: 1 << 1)
    static let code = StyleFlags(rawValue: 1 << 2)
    static let strike = StyleFlags(rawValue: 1 << 3)
    static let link = StyleFlags(rawValue: 1 << 4)
}

/// Tokenizes one text block's content into styled spans. Pure and deterministic: toggles a
/// `StyleFlags` accumulator on delimiter runs, treats code spans as literal, and recurses into
/// `[text](url)` bodies for their own emphasis. Unclosed/malformed syntax degrades to literal
/// text instead of mis-nesting.
/// CommonMark's escapable ASCII punctuation set — a backslash before any of these consumes
/// itself and the following char is emitted literally, bypassing whatever markup meaning it
/// would otherwise carry.
private func isEscapableMarkdownPunctuation(_ c: Character) -> Bool {
    switch c {
    case "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
         ":", ";", "<", "=", ">", "?", "@", "[", "\\", "]", "^", "_", "`", "{", "|", "}", "~":
        return true
    default:
        return false
    }
}

/// Schemes `inlineRuns` recognizes for bare/angle-bracket autolinking. Longest-first so
/// `matchedBareURLScheme` never stops at "http://" when the text actually reads "https://".
private let bareURLSchemes = ["https://", "http://"]

/// Returns the scheme prefix (if any) `s` starts with, from `bareURLSchemes`.
private func matchedBareURLScheme(_ s: some StringProtocol) -> String? {
    bareURLSchemes.first(where: { s.hasPrefix($0) })
}

private func isWordChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber
}

/// Strips CommonMark's conservative trailing-punctuation set off a bare-URL match. No
/// paren-balance heuristic (GFM's Wikipedia-style rule) -- out of scope, matches the bead's
/// "stop at whitespace/trailing punctuation" wording.
private func trimBareURLTrailingPunctuation(_ s: Substring) -> Substring {
    var s = s
    while let last = s.last, ".,;:!?)]}'\"".contains(last) {
        s = s.dropLast()
    }
    return s
}

nonisolated func inlineRuns(_ text: String) -> [InlineRun] {
    var runs: [InlineRun] = []
    var buffer = ""
    var flags: StyleFlags = []

    func flush() {
        guard !buffer.isEmpty else { return }
        runs.append(InlineRun(text: buffer, style: flags, url: nil))
        buffer = ""
    }

    // CommonMark flanking classification for every `*`/`_` run, precomputed once (+Emphasis.swift).
    let delimiterRuns = scanEmphasisDelimiterRuns(in: text)
    var delimiterRunIndex = 0
    var italicOpenChar: Character?
    var boldOpenChar: Character?

    var chars = Substring(text)
    while !chars.isEmpty {
        if chars.hasPrefix("~~") {
            flush()
            flags.formSymmetricDifference(.strike)
            chars = chars.dropFirst(2)
            continue
        }
        if chars.hasPrefix("\\$") {
            // Escaped dollar is a literal '$', never a math delimiter.
            buffer.append("$")
            chars = chars.dropFirst(2)
            continue
        }
        if chars.hasPrefix("\\(") {
            let afterOpen = chars.dropFirst(2)
            if let closeRange = afterOpen.range(of: "\\)") {
                flush()
                let tex = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                runs.append(InlineRun(text: tex, style: flags, url: nil, mathSource: tex))
                chars = afterOpen[closeRange.upperBound...]
                continue
            }
            // No matching close yet — still streaming. Render the marker literally, same
            // discipline as an unclosed code span: no raw-TeX flash, no misparse.
            buffer.append(contentsOf: chars.prefix(2))
            chars = chars.dropFirst(2)
            continue
        }
        if chars.first == "\\" {
            let rest = chars.dropFirst()
            guard let next = rest.first else {
                // Trailing lone backslash mid-stream — its partner char isn't known yet, so
                // drop it pending rather than committing to "literal backslash", same discipline
                // as a trailing lone `*`/`_` above.
                chars = rest
                continue
            }
            if isEscapableMarkdownPunctuation(next) {
                buffer.append(next)
                chars = rest.dropFirst()
                continue
            }
            buffer.append("\\")
            chars = rest
            continue
        }
        if chars.first == "$" {
            if chars.dropFirst().first == "$" {
                // "$$" mid-paragraph is neither the block form (only recognized at line-start
                // in parseTail) nor valid inline syntax — emit one literal '$' rather than guess.
                buffer.append("$")
                chars = chars.dropFirst()
                continue
            }
            let afterOpen = chars.dropFirst()
            // Pandoc's tex_math_dollars heuristic: the char right after the opening '$' and the
            // char right before the closing '$' must both be non-space. Without this, "$5 and
            // $10" (two literal prices) would misparse as one formula spanning "5 and ".
            if let openNext = afterOpen.first, openNext != " ", openNext != "\n" {
                var idx = afterOpen.startIndex
                var prevChar = openNext
                var closeIndex: Substring.Index?
                while idx < afterOpen.endIndex {
                    let c = afterOpen[idx]
                    if c == "$", prevChar != " " {
                        closeIndex = idx
                        break
                    }
                    prevChar = c
                    idx = afterOpen.index(after: idx)
                }
                if let closeIndex {
                    flush()
                    let tex = String(afterOpen[afterOpen.startIndex..<closeIndex])
                    runs.append(InlineRun(text: tex, style: flags, url: nil, mathSource: tex))
                    chars = afterOpen[afterOpen.index(after: closeIndex)...]
                    continue
                }
            }
            // Unclosed, or rejected by the guard above — literal dollar, no misparse.
            buffer.append("$")
            chars = chars.dropFirst()
            continue
        }
        if chars.first == "*" || chars.first == "_" {
            // Decision logic (flanking rules, open/close matching, end-of-text streaming guard)
            // lives in +Emphasis.swift so this loop stays a thin dispatch on its result.
            switch nextEmphasisStep(
                chars: chars, text: text, delimiterRuns: delimiterRuns,
                runIndex: &delimiterRunIndex, italicOpenChar: &italicOpenChar, boldOpenChar: &boldOpenChar
            ) {
            case .literal(let count):
                buffer.append(contentsOf: chars.prefix(count))
                chars = chars.dropFirst(count)
            case .toggle(let delta, let count):
                flush()
                flags.formSymmetricDifference(delta)
                chars = chars.dropFirst(count)
            case .pending(let count):
                // Ambiguous trailing marker, might still widen next append. Consume without
                // appending or toggling flags -- same as the old pre-flanking-rules behavior.
                chars = chars.dropFirst(count)
            }
            continue
        }
        if chars.first == "`" {
            let markerLen = chars.prefix { $0 == "`" }.count
            let marker = String(repeating: "`", count: markerLen)
            let afterOpen = chars.dropFirst(markerLen)
            if let closeRange = afterOpen.range(of: marker) {
                flush()
                let code = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                runs.append(InlineRun(text: code, style: flags.union(.code), url: nil))
                chars = afterOpen[closeRange.upperBound...]
                continue
            }
            // No matching close yet — still streaming. Treat the marker literally.
            buffer.append(contentsOf: chars.prefix(markerLen))
            chars = chars.dropFirst(markerLen)
            continue
        }
        if chars.first == "<" {
            let afterOpen = chars.dropFirst()
            if let closeIndex = afterOpen.firstIndex(of: ">") {
                let inner = afterOpen[afterOpen.startIndex..<closeIndex]
                if !inner.contains(where: { $0 == " " || $0 == "\n" || $0 == "<" }),
                   let scheme = matchedBareURLScheme(inner), inner.count > scheme.count {
                    flush()
                    let url = String(inner)
                    runs.append(InlineRun(text: url, style: flags.union(.link), url: url))
                    chars = afterOpen[afterOpen.index(after: closeIndex)...]
                    continue
                }
            }
            // No '>' yet, or the span isn't a bare http(s) autolink -- literal '<'. The whole
            // text is re-scanned from scratch on every append(), so a still-streaming autolink
            // gets retried once its '>' actually lands (same discipline as an unclosed backtick).
            buffer.append("<")
            chars = chars.dropFirst()
            continue
        }
        if chars.first == "h", let scheme = matchedBareURLScheme(chars) {
            let precededByWordChar: Bool
            if chars.startIndex > text.startIndex {
                precededByWordChar = isWordChar(text[text.index(before: chars.startIndex)])
            } else {
                precededByWordChar = false
            }
            if !precededByWordChar {
                let afterScheme = chars.dropFirst(scheme.count)
                let rawBody = afterScheme.prefix { !$0.isWhitespace && $0 != "<" }
                let body = trimBareURLTrailingPunctuation(rawBody)
                if !body.isEmpty {
                    flush()
                    let url = scheme + String(body)
                    runs.append(InlineRun(text: url, style: flags.union(.link), url: url))
                    chars = chars.dropFirst(scheme.count + body.count)
                    continue
                }
                // Scheme typed but no host char yet (hot tail literally ends in "https://") --
                // still streaming, don't link. Falls through to the literal single-char append
                // below; re-evaluated fresh once a host char streams in on a later append().
            }
        }
        if chars.first == "[" {
            if let closeBracket = chars.dropFirst().firstIndex(of: "]") {
                let afterBracket = chars.index(after: closeBracket)
                if afterBracket < chars.endIndex, chars[afterBracket] == "(",
                   let closeParen = chars[afterBracket...].firstIndex(of: ")") {
                    let linkText = String(chars[chars.index(after: chars.startIndex)..<closeBracket])
                    let linkURL = String(chars[chars.index(after: afterBracket)..<closeParen])
                    flush()
                    let innerRuns = inlineRuns(linkText)
                    if innerRuns.isEmpty {
                        runs.append(InlineRun(text: "", style: flags.union(.link), url: linkURL))
                    } else {
                        for inner in innerRuns {
                            runs.append(InlineRun(text: inner.text, style: flags.union(inner.style).union(.link), url: linkURL, mathSource: inner.mathSource))
                        }
                    }
                    chars = chars[chars.index(after: closeParen)...]
                    continue
                }
            }
            buffer.append("[")
            chars = chars.dropFirst()
            continue
        }
        buffer.append(chars.first!)
        chars = chars.dropFirst()
    }
    flush()
    return runs
}

/// One cell of a `.table` block: its raw text plus tokenized inline emphasis spans
/// (`inlineRuns(_:)`), so table rendering never has to re-tokenize per cell.
struct TableCell: Equatable {
    var text: String
    var runs: [InlineRun]
}

/// One markdown block the incremental parser has classified: a kind plus its raw source text
/// (lines joined by `\n`, marker/underline syntax stripped where it isn't part of the rendered
/// content — e.g. a setext `===` underline or a table delimiter row) plus its tokenized inline
/// spans (empty for kinds that don't render as free-form styled text).
struct ParsedMDBlock: Equatable {
    var kind: MarkdownBlockKind
    var text: String
    var runs: [InlineRun] = []
    /// Populated only when `kind` is `.table`: `tableRows[0]` is the header row, `tableRows[1...]`
    /// are body rows, each cell already tokenized. Empty for every other kind.
    var tableRows: [[TableCell]] = []
}

// MARK: - IncrementalMarkdownParser

/// Consumes an appended markdown stream and splits it into two tiers at a monotonically
/// non-decreasing frontier `F`: **sealed** blocks (`source[0..<F)`), guaranteed never to
/// change and safe to `freeze()`, and **hot** blocks (the open tail), which may still be
/// retyped. A deliberately simplified CommonMark subset (heuristic list/blockquote
/// continuation, no fence nesting), not full compliance.
public struct IncrementalMarkdownParser: Sendable, Equatable {

    /// Finalized, immutable blocks — never touched again once appended here.
    private(set) var sealedBlocks: [ParsedMDBlock] = []
    private(set) var sealedBlockIDs: [BlockID] = []

    /// Resumable scanner state for the hot region: every *complete* (newline-terminated) line
    /// seen so far has already been classified and folded in here — `append(_:)` never
    /// re-feeds a line that's already in `hotScan`. See `IncrementalMarkdownParser+HotScan.swift`.
    private var hotScan = HotScanState()

    /// Raw text of the current, not-yet-newline-terminated trailing line. Reprocessed in full
    /// on every `append(_:)` (its classification can still change — see `HotScanState.step`),
    /// but this is bounded by one line's length, not by the whole hot region.
    var hotPendingLine = ""

    /// Diagnostics distinguishing genuinely new scan work from necessary reconsideration and
    /// from reused/cached work. Owned per parser instance — no singleton.
    private(set) var scanCounters = MarkdownScanCounters()

    private(set) var hotBlockIDs: [BlockID] = []
    private var nextBlockID = 0

    /// Materialized hot blocks, computed at most once per `append(_:)` call and simply read
    /// (never recomputed) by every consumer in between -- `blockList`, `renderableBlocks`, etc.
    /// See `append(_:)`'s tail for how this gets refreshed.
    private(set) var hotBlocksState: [ParsedMDBlock] = []
    /// Trailing UTF-8 byte offset of `hotPendingLine` already merged into the open fence/mathBlock
    /// via `appendPendingCharsToFenceFastPath`. Bytes, not graphemes -- O(1) `UTF8View` indexing
    /// vs O(n) `String.Index(offsetBy:)`. Reset to 0 whenever a real line completes.
    private var materializedPendingByteCount = 0
    /// Once the still-open pending line's block kind (paragraph/blockquote/listItem) can no
    /// longer change, this caches it so growing the line costs O(delta), not O(line length).
    /// Reset to nil wherever `materializedPendingByteCount` resets -- both mark "new pending
    /// line, nothing settled yet". See `IncrementalMarkdownParser+PendingLine.swift`.
    private var pendingLineFastPath: PendingLineFastPath?
    /// Tokenized prefix of the current open Tier-2 block.
    var inlineWindow = OpenInlineWindow()

    public init() {}

    /// Sealed-block count — the frontier `F` passed to `diff(previous:new:frontier:)`.
    /// Monotonically non-decreasing: `sealedBlocks` is only ever appended to.
    public var frontier: Int { sealedBlocks.count }

    /// Appends `text` to the accumulated stream, resuming the hot-region scan instead of
    /// re-scanning it from scratch. Only the newly-completed lines (plus the still-open
    /// trailing line, in `dryRun` mode) are fed through the classifier; everything already
    /// folded into `hotScan` from a previous call is never revisited. Any block that becomes
    /// provably sealed is moved into `sealedBlocks` permanently; everything still open stays hot.
    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        // `hotPendingLine`'s existing content is always newline-free (this loop's own invariant),
        // so any "\n" this call finds must be inside the newly-appended `text` -- scanning from
        // `priorByteCount` instead of `hotPendingLine.startIndex` keeps `firstIndex(of:)` bounded
        // by the new bytes, not by however long the pending line has already grown (which made a
        // single very long open line's per-keystroke cost O(line-length), i.e. O(n^2) overall).
        let priorByteCount = hotPendingLine.utf8.count
        hotPendingLine += text
        var searchFromByte = priorByteCount

        while let newline = Self.firstNewline(in: hotPendingLine, fromByte: searchFromByte) {
            let completedLine = String(hotPendingLine[hotPendingLine.startIndex..<newline])
            hotPendingLine.removeSubrange(hotPendingLine.startIndex...newline)
            searchFromByte = 0  // remaining content is an unscanned tail of this call's `text`

            // Continuing an open fence/mathBlock: fold the line in place (O(delta)), not a full
            // re-alias every line. Drop the mirror first so `step()`'s mutation is uniquely-owned.
            let continuingFence = (hotScan.inFence || hotScan.inMathBlock) && !hotBlocksState.isEmpty
            if continuingFence {
                hotBlocksState[hotBlocksState.count - 1].text = ""
                // Undo the fast path's speculative pre-merge of this line (plus its leading "\n")
                // before `step()` re-adds it canonically, or the line duplicates. Suffix removal on
                // a uniquely-owned buffer, so still O(delta).
                if materializedPendingByteCount > 0, hotScan.openBlockCache != nil {
                    let removeCount = materializedPendingByteCount + 1
                    let utf8 = hotScan.openBlockCache!.text.utf8
                    let cut = utf8.index(utf8.endIndex, offsetBy: -removeCount)
                    hotScan.openBlockCache!.text.removeSubrange(cut..<hotScan.openBlockCache!.text.endIndex)
                }
            }
            let openIndex = hotScan.blocks.count
            let retainedRuns: [InlineRun]?
            if let cache = hotScan.openBlockCache, openIndex < hotBlocksState.count,
               hotBlocksState[openIndex].kind == hotScan.openKind,
               hotBlocksState[openIndex].text == cache.text {
                retainedRuns = hotBlocksState[openIndex].runs
            } else {
                retainedRuns = nil
            }
            Self.step(Substring(completedLine), into: &hotScan, retainedOpenRuns: retainedRuns)
            scanCounters.linesScannedNew += 1
            sealCommittedPrefixIfNeeded()

            if continuingFence, hotScan.inFence || hotScan.inMathBlock, let cache = hotScan.openBlockCache {
                hotBlocksState[hotBlocksState.count - 1].text = cache.text  // cheap mirror refresh
                scanCounters.fenceBytesCopiedTotal += completedLine.utf8.count + 1
            } else {
                rebuildHotBlocksStateFromScan()  // opened/closed/non-fence: infrequent, full resync is fine
            }
            materializedPendingByteCount = 0
            pendingLineFastPath = nil
        }

        var hotCount = hotScan.blocks.count
        if !hotPendingLine.isEmpty {
            if hotScan.inFence || hotScan.inMathBlock {
                // No branch in `step()` reclassifies mid-fence, so merging directly is safe.
                appendPendingCharsToFenceFastPath()
                hotCount = hotScan.blocks.count + 1
            } else {
                scanCounters.partialLineReconsiderations += 1
                let line = Substring(hotPendingLine)
                // A pending line the fast path has settled (or can settle right now) can only be
                // non-blank real content -- `settlePendingLineFastPath` returns nil for an
                // all-whitespace line -- so it can never resolve a seal point later. Skip the
                // O(line-length) dry-run `step()` entirely in that case; it exists only to answer
                // "did this line just become a blank-line seal?" and "would-be non-fence open kind
                // count", both already known once the fast path has settled.
                if (hotScan.openKind == nil &&
                    (pendingLineFastPath != nil || Self.settlePendingLineFastPath(line) != nil)) ||
                   continuationFastPathEligible(line) {
                    hotCount = hotScan.blocks.count + 1
                } else {
                    // Every other open kind's pending line is ambiguous until `\n` arrives --
                    // dry-run first to count blocks, then materialize for real once, below.
                    var transient = hotScan
                    Self.step(line, into: &transient, dryRun: true)
                    if transient.pendingSealBlockCount > hotScan.pendingSealBlockCount {
                        scanCounters.partialLineSeals += 1
                    }
                    hotCount = transient.blocks.count
                    if transient.openKind != nil { hotCount += 1 }
                }
                materializeNonFenceHotBlocksState()
            }
        } else if hotScan.openKind != nil {
            hotCount += 1
        }
        hotBlockIDs = reconciledIDs(existing: hotBlockIDs, count: hotCount)
    }

    /// Finds the first "\n" in `line` at or after `fromByte`, without scanning any bytes before
    /// it -- keeps the newline check bounded by how much is new, not by the pending line's total
    /// length so far.
    private static func firstNewline(in line: String, fromByte: Int) -> String.Index? {
        let bytes = line.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: fromByte)
        return line[start...].firstIndex(of: "\n")
    }

    /// Rebuilds `hotBlocksState` from `hotScan` alone (no pending trailing line to merge). Cheap:
    /// `blockFromCache` shares `cache.text`'s buffer via COW, no copy happens here.
    private mutating func rebuildHotBlocksStateFromScan() {
        var hot = hotScan.blocks
        if let kind = hotScan.openKind, let cache = hotScan.openBlockCache {
            hot.append(materializedOpenBlock(kind: kind, cache: cache, identity: sealedBlocks.count + hot.count))
        }
        hotBlocksState = hot
    }

    /// Classifies the trailing line against a scratch scan. The inline window keeps settled
    /// runs across these materializations; the raw block text is still joined for consumers.
    ///
    /// `hotBlocksState[last].runs` mirrors `inlineWindow`'s own merge buffer -- drop it first so
    /// that buffer stays uniquely-owned across calls (mirrors the `.text` clear-before/refresh-
    /// after trick in `appendPendingCharsToFenceFastPath`, applied to inline runs instead).
    private mutating func materializeNonFenceHotBlocksState() {
        if !hotBlocksState.isEmpty { hotBlocksState[hotBlocksState.count - 1].runs = [] }

        // Fast path #1: the pending line hasn't committed to an open block yet (`hotScan.openKind
        // == nil`). Once its own kind (paragraph/blockquote/listItem) is settled, growing it here
        // is O(delta) instead of re-running `step()` -- which would otherwise force a COW copy of
        // `hotScan.openBlockCache.text` via `var scratch = hotScan` on every keystroke.
        if hotScan.openKind == nil, let block = materializedPendingLineFastPath() {
            var hot = hotScan.blocks
            hot.append(block)
            hotBlocksState = hot
            scanCounters.hotFullMaterializations += 1
            return
        }
        // Fast path #2: the pending line IS extending an already multi-line open paragraph or
        // blockquote (`hotScan.openKind != nil`). Same COW hazard as fast path #1, just one line
        // later -- see `materializedOpenContinuationFastPath`'s doc comment.
        if let block = materializedOpenContinuationFastPath() {
            var hot = hotScan.blocks
            hot.append(block)
            hotBlocksState = hot
            scanCounters.hotFullMaterializations += 1
            return
        }
        pendingLineFastPath = nil

        var scratch = hotScan
        Self.step(Substring(hotPendingLine), into: &scratch)
        var hot = scratch.blocks
        if let kind = scratch.openKind, let cache = scratch.openBlockCache {
            hot.append(materializedOpenBlock(kind: kind, cache: cache, identity: sealedBlocks.count + hot.count))
        }
        hotBlocksState = hot
        scanCounters.hotFullMaterializations += 1
    }

    /// True when the still-open trailing `line` is guaranteed to just extend the CURRENT
    /// `.paragraph`/`.blockquote` open block once it completes. Shared by `append`'s block-count
    /// dry run and `materializedOpenContinuationFastPath` -- both need to skip the exact but
    /// O(line-length) `step()` classification for the same reason (see that function's doc).
    /// Excludes `.listItem` (a plain continuation line under an open list item always closes it
    /// and starts a new paragraph -- see `step()`'s final fallback) and the one-line-old
    /// paragraph whose first line contains "|" (still eligible for retroactive promotion to
    /// `.table`, so it must stay on the slow, exact path).
    private func continuationFastPathEligible(_ line: Substring) -> Bool {
        guard let openKind = hotScan.openKind, openKind == .paragraph || openKind == .blockquote,
              hotScan.openBlockCache != nil else { return false }
        if openKind == .paragraph, hotScan.openLineCount == 1, hotScan.firstOpenLine?.contains("|") == true {
            return false
        }
        let settledKind = pendingLineFastPath?.kind ?? Self.settlePendingLineFastPath(line)?.kind
        switch (settledKind, openKind) {
        case (.paragraph, .paragraph), (.blockquote, .blockquote): return true
        default: return false
        }
    }

    /// Growing the still-uncommitted trailing line of an ALREADY multi-line open paragraph or
    /// blockquote had no fast path: the slow branch below runs a real (non-dry-run) `step()` on
    /// a scratch copy of `hotScan` every keystroke, which mutates `scratch.openBlockCache!.text`
    /// -- since that buffer is still COW-shared with the real `hotScan.openBlockCache!.text`,
    /// every keystroke forced a full copy of the WHOLE open block's accumulated text, i.e.
    /// O(open-block-size) per keystroke (the exact defect class `PendingLineFastPath` fixes for
    /// a not-yet-multi-line block, one line later). See `continuationFastPathEligible` for why
    /// this is safe to take.
    private mutating func materializedOpenContinuationFastPath() -> ParsedMDBlock? {
        let line = Substring(hotPendingLine)
        guard continuationFastPathEligible(line), let openKind = hotScan.openKind else { return nil }
        if pendingLineFastPath == nil {
            guard let settled = Self.settlePendingLineFastPath(line) else { return nil }
            pendingLineFastPath = PendingLineFastPath(
                kind: settled.kind,
                text: hotScan.openBlockCache!.text + "\n" + settled.text,
                consumedByteCount: settled.consumedByteCount
            )
        } else if pendingLineFastPath!.consumedByteCount != line.utf8.count {
            if !hotBlocksState.isEmpty { hotBlocksState[hotBlocksState.count - 1].text = "" }
            let deltaByteCount = Self.extendPendingLineFastPath(&pendingLineFastPath!, line: line)
            scanCounters.pendingLineFastPathBytesCopiedTotal += deltaByteCount
        }
        guard let fast = pendingLineFastPath else { return nil }
        scanCounters.pendingLineFastPathAppends += 1
        let identity = sealedBlocks.count + hotScan.blocks.count
        return materializedOpenBlock(kind: openKind, cache: OpenBlockCache(kind: openKind, text: fast.text), identity: identity)
    }

    /// Tries to settle (or extend an already-settled) `PendingLineFastPath` for the still-open
    /// trailing line. Returns nil when the kind isn't settled yet or isn't fast-pathed (heading,
    /// fence/mathBlock/image openers) -- callers fall back to the exact `step()` path then.
    private mutating func materializedPendingLineFastPath() -> ParsedMDBlock? {
        let line = Substring(hotPendingLine)
        if pendingLineFastPath == nil {
            pendingLineFastPath = Self.settlePendingLineFastPath(line)
        } else if pendingLineFastPath!.consumedByteCount != line.utf8.count {
            // The previous call's ParsedMDBlock.text (mirrored into hotBlocksState below) aliases
            // this same String buffer -- drop that reference first, or `fast.text +=` below forces
            // a full COW copy of the whole line on every keystroke (the same hazard the `.text`
            // clear-before/refresh-after trick in `appendPendingCharsToFenceFastPath` guards against
            // for the fence buffer).
            if !hotBlocksState.isEmpty { hotBlocksState[hotBlocksState.count - 1].text = "" }
            let deltaByteCount = Self.extendPendingLineFastPath(&pendingLineFastPath!, line: line)
            scanCounters.pendingLineFastPathBytesCopiedTotal += deltaByteCount
        }
        guard let fast = pendingLineFastPath else { return nil }
        scanCounters.pendingLineFastPathAppends += 1

        let identity = sealedBlocks.count + hotScan.blocks.count
        switch fast.kind {
        case .paragraph:
            return materializedOpenBlock(
                kind: .paragraph, cache: OpenBlockCache(kind: .paragraph, text: fast.text), identity: identity
            )
        case .blockquote:
            return materializedOpenBlock(
                kind: .blockquote, cache: OpenBlockCache(kind: .blockquote, text: fast.text), identity: identity
            )
        case .listItem(let ordered, let number, let depth, let checked):
            let kind = MarkdownBlockKind.listItem(ordered: ordered, number: number, depth: depth, checked: checked)
            let result = inlineWindow.runs(for: fast.strippedText ?? "", kind: kind, identity: identity)
            scanCounters.tier2CharsTokenizedTotal += result.tokenizedBytes
            return ParsedMDBlock(kind: kind, text: fast.text, runs: result.runs)
        }
    }

    private mutating func materializedOpenBlock(
        kind: MarkdownBlockKind, cache: OpenBlockCache, identity: Int
    ) -> ParsedMDBlock {
        switch kind {
        case .paragraph, .heading, .blockquote:
            let result = inlineWindow.runs(for: cache.text, kind: kind, identity: identity)
            scanCounters.tier2CharsTokenizedTotal += result.tokenizedBytes
            return ParsedMDBlock(kind: kind, text: cache.text, runs: result.runs)
        default:
            let block = Self.blockFromCache(kind: kind, cache: cache)
            if case .listItem = kind {
                scanCounters.tier2CharsTokenizedTotal += cache.text.utf8.count
            }
            return block
        }
    }

    /// O(delta) fast path: merges only newly-arrived `hotPendingLine` chars into the open
    /// fence/mathBlock's text. `hotScan.openBlockCache!.text` is the buffer that grows;
    /// `hotBlocksState[last].text` is a mirror, cleared before and refreshed after each
    /// mutation so it's always uniquely-owned (no COW copy -- the round-3 bug this replaces).
    private mutating func appendPendingCharsToFenceFastPath() {
        guard hotScan.openBlockCache != nil, !hotBlocksState.isEmpty else {
            rebuildHotBlocksStateFromScan()
            scanCounters.hotFullMaterializations += 1
            return
        }
        let last = hotBlocksState.count - 1
        hotBlocksState[last].text = ""
        if materializedPendingByteCount == 0 {
            hotScan.openBlockCache!.text += "\n"
        }
        let bytes = hotPendingLine.utf8
        let deltaStart = bytes.index(bytes.startIndex, offsetBy: materializedPendingByteCount)
        let deltaByteCount = hotPendingLine.utf8.distance(from: deltaStart, to: bytes.endIndex)
        hotScan.openBlockCache!.text += hotPendingLine[deltaStart...]
        hotBlocksState[last].text = hotScan.openBlockCache!.text
        materializedPendingByteCount = hotPendingLine.utf8.count
        scanCounters.hotFastPathAppends += 1
        scanCounters.fenceBytesCopiedTotal += deltaByteCount
    }

    /// Moves any newly-sealed prefix out of `hotScan.blocks` into `sealedBlocks` permanently,
    /// truncating `hotScan` back to just the still-hot remainder. Called right after any
    /// `step()` that may have advanced `hotScan.pendingSealBlockCount`.
    private mutating func sealCommittedPrefixIfNeeded() {
        let sealedCount = min(hotScan.pendingSealBlockCount, hotScan.blocks.count)
        guard sealedCount > 0 else { return }
        let newlySealed = Array(hotScan.blocks[0..<sealedCount])
        let sealedIDs = reconciledIDs(existing: hotBlockIDs, count: newlySealed.count)
        sealedBlocks.append(contentsOf: newlySealed)
        sealedBlockIDs.append(contentsOf: sealedIDs)
        hotBlockIDs = Array(hotBlockIDs.dropFirst(newlySealed.count))
        hotScan.blocks.removeFirst(sealedCount)
        hotScan.pendingSealBlockCount = 0
    }

    /// Builds the `[Block]` list a caller feeds into `diff(previous:new:frontier:)` —
    /// `sealed + hot`, with `Block.key.index` matching each block's position in that combined
    /// list (so `BlockKey`'s positional identity lines up with `frontier`).
    public func blockList<ID: Hashable & Sendable>(
        itemID: ID, width: CGFloat, theme: MarkdownTheme = .default
    ) -> [Block] {
        let hot = hotBlocksState
        var blocks: [Block] = []
        blocks.reserveCapacity(sealedBlocks.count + hot.count)
        let combined = sealedBlocks + hot
        let lastIndex = combined.count - 1
        for (index, pair) in zip(combined, sealedBlockIDs + hotBlockIDs).enumerated() {
            let lifecycle: BlockLifecycle = index < sealedBlocks.count ? .sealed : .hot
            // Only the still-open trailing block can retroactively promote paragraph -> table
            // (see parseTail's paragraph->table join). Any earlier single-line "|" paragraph
            // was already finalized as a plain paragraph by something else arriving after it, so
            // it is not ambiguous and must render its pipes literally.
            let isPendingTableHeader = index == lastIndex && lifecycle == .hot && Self.isPendingTableCandidate(pair.0)
            blocks.append(Self.makeBlock(pair.0, itemID: itemID, index: index, blockID: pair.1, width: width, lifecycle: lifecycle, theme: theme, isPendingTableHeader: isPendingTableHeader))
        }
        return blocks
    }

    /// True for a hot, one-line, unfinalized paragraph whose only line contains `|` — the window
    /// where `parseTail` cannot yet tell whether the next line will be a table delimiter row
    /// (-> promote to `.table`) or ordinary text (-> stays `.paragraph`, pipes literal).
    /// Painting this line's raw pipes would flash `|a|b|` for one or more frames before the
    /// table lays out; see VelocityUI-wmss.3.
    static func isPendingTableCandidate(_ parsed: ParsedMDBlock) -> Bool {
        guard case .paragraph = parsed.kind else { return false }
        return parsed.text.contains("|") && !parsed.text.contains("\n")
    }

    // MARK: - Block construction

    private static func makeBlock<ID: Hashable & Sendable>(
        _ parsed: ParsedMDBlock, itemID: ID, index: Int, blockID: BlockID, width: CGFloat,
        lifecycle: BlockLifecycle, theme: MarkdownTheme, isPendingTableHeader: Bool = false
    ) -> Block {
        let frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let content: FragmentContent
        if case .image(let url) = parsed.kind {
            content = .image(imageDescriptor(url: url))
        } else {
            content = .text(makeDescriptor(parsed, theme: theme, isPendingTableHeader: isPendingTableHeader))
        }
        let fragment = Fragment(id: index, blockID: blockID, content: content, frame: frame)
        return Block(
            key: BlockKey(itemID: itemID, blockID: blockID),
            fragment: fragment,
            layout: ResolvedLayout(totalFrame: frame),
            lifecycle: lifecycle
        )
    }

    /// Builds an `ImageDescriptor` for a markdown image block by constructing the same
    /// `AsyncImageNode` the production `StreamingMarkdownText.renderNode` path returns, then
    /// copying its own `layoutHash`/`appearanceHash` — reuses the one hash formula
    /// `AsyncImageNode` already owns instead of re-deriving a second one here (Section 3
    /// cross-site consistency: the same defaults, the same hashes, only one call site
    /// disagreeing with itself is impossible by construction).
    private static func imageDescriptor(url: URL) -> ImageDescriptor {
        let node = AsyncImageNode(url: url)
        return ImageDescriptor(
            url: node.url,
            aspectRatio: node.aspectRatio,
            contentMode: node.contentMode.rawValue,
            cornerRadius: node.cornerRadius,
            layoutHash: node.layoutHash,
            appearanceHash: node.appearanceHash,
            thumbnailData: node.thumbnailData,
            blurHash: node.blurHash,
            customPlaceholderPayload: node.customPlaceholderPayload
        )
    }

    private mutating func reconciledIDs(existing: [BlockID], count: Int) -> [BlockID] {
        var ids = Array(existing.prefix(count))
        while ids.count < count {
            ids.append(BlockID(nextBlockID))
            nextBlockID += 1
        }
        return ids
    }

    /// A block's rendered text plus its font — shared by `makeDescriptor` and `renderNodes`
    /// so the two representations can't silently diverge. Color/line-break are each
    /// caller's own separate default. `runs` is empty for kinds `tokenizableRuns` never
    /// tokenizes (codeFence/table/thematicBreak) or when `parsed.runs` itself is empty —
    /// both `makeDescriptor` and `renderNodes` pass it straight through to their respective
    /// `TextDescriptor`/`TextNode`.
    struct StyledText {
        var content: String
        var font: VFontDescriptor
        var runs: [TextRun] = []
    }

    /// `isPendingTableHeader` is true only for the still-open trailing paragraph whose single
    /// line contains `|` with no `\n` yet — see `isPendingTableCandidate`. Rendered as empty
    /// text rather than the raw pipe source, so a header row never flashes literal `|`
    /// characters before the delimiter row confirms (or denies) the table.
    static func style(_ parsed: ParsedMDBlock, theme: MarkdownTheme = .default, isPendingTableHeader: Bool = false) -> StyledText {
        if isPendingTableHeader {
            return StyledText(content: "", font: theme.body, runs: [])
        }
        let font: VFontDescriptor
        var content = parsed.text
        var prefix = ""
        switch parsed.kind {
        case .heading(let level):
            font = theme.heading(level: level)
        case .codeFence:
            font = theme.code
            // Strip the fence marker lines. The opening line always exists; only drop the
            // closing line when it's actually shaped like one — otherwise a still-streaming
            // fence would hide its most recently typed line.
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty {
                lines.removeFirst()
            }
            if let last = lines.last, Self.isFenceCloseShaped(last) {
                lines.removeLast()
            }
            content = lines.joined(separator: "\n")
        case .table:
            font = theme.body
        case .mathBlock:
            font = theme.code
            // Strip the `$$`/`\[...\]` delimiters the same way codeFence strips its fence
            // markers — until gojy.3's rasterizer lands, this is what StreamingMarkdownText's
            // default TextNode branch shows: the bare TeX source as literal text, no raw
            // delimiter flash, no misparse of a still-streaming (unclosed) block.
            content = Self.stripMathBlockDelimiters(content)
        case .listItem(let ordered, let number, let depth, let checked):
            font = theme.body
            let indent = String(repeating: "  ", count: depth)
            if let checked {
                prefix = indent + (checked ? checkedTaskGlyph : uncheckedTaskGlyph) + " "
            } else {
                prefix = indent + (ordered ? "\(number). " : "• ")
            }
            content = Self.stripListMarker(content)
        case .blockquote:
            font = theme.body
        case .paragraph:
            font = theme.body
        case .image:
            // Dead in practice: both call sites (`makeBlock` and `StreamingMarkdownText.
            // renderNode`) branch away to build an `.image` fragment/`AsyncImageNode` before
            // ever reaching `style()`. Kept only so this switch stays exhaustive.
            font = theme.body
            content = ""
        case .thematicBreak:
            font = theme.body
            // A single invisible space, not the raw "---"/"***"/"___" source: the rule itself is
            // drawn into the raster by `rasterizeText` off `TextDescriptor.ruleColor` (set below,
            // via `textDecoration(for:)`), so the "text" here exists only to give the block a
            // line-height-derived box with margin above and below the rule.
            content = " "
        }
        // Runs cover the base text too (inlineRuns always emits at least one plain run for
        // non-empty text), so a block's own color -- muted for .blockquote -- has to flow in
        // here, not just onto TextDescriptor.color: `styledContentAndRuns`'s run path (taken
        // whenever `parsed.runs` is non-empty, effectively always) ignores TextDescriptor.color
        // entirely and paints from each run's own color instead.
        let baseColor = Self.textDecoration(for: parsed.kind).color
        let (finalContent, runs) = Self.styledContentAndRuns(
            parsed, fallbackContent: content, prefix: prefix, baseFont: font, baseColor: baseColor
        )
        return StyledText(content: finalContent, font: font, runs: runs)
    }

    /// Folds `parsed.runs` (the tokenized inline spans) into the block's final rendered content
    /// and matching `TextRun`s. `fallbackContent` — already fence-stripped/marker-stripped by
    /// `style()` — is used verbatim when `parsed.runs` is empty (codeFence/table/thematicBreak,
    /// or a tokenizable block whose text tokenized to nothing): those kinds render as single-style
    /// text, same as before this bead. `prefix` (a listItem's indent + bullet/number) always
    /// renders in the base style ahead of the tokenized spans, so it never picks up the first
    /// span's emphasis.
    private static func styledContentAndRuns(
        _ parsed: ParsedMDBlock, fallbackContent: String, prefix: String,
        baseFont: VFontDescriptor, baseColor: VColorDescriptor
    ) -> (content: String, runs: [TextRun]) {
        guard !parsed.runs.isEmpty else { return (prefix + fallbackContent, []) }

        var content = prefix
        var runs: [TextRun] = []
        if !prefix.isEmpty {
            runs.append(TextRun(length: prefix.utf16.count, font: baseFont, color: baseColor))
        }
        for run in parsed.runs {
            content += run.text
            runs.append(Self.textRun(for: run, baseFont: baseFont, baseColor: baseColor))
        }
        return (content, runs)
    }

    /// Task-list checkbox glyphs, rendered in place of a `.listItem`'s bullet/number when
    /// `checked` is non-nil — plain text glyphs (no CALayer), same rasterization path as any
    /// other prefix text.
    private static let uncheckedTaskGlyph = "☐"
    private static let checkedTaskGlyph = "☑"

    /// Subtle background pill for inline code, drawn into the raster via `.backgroundColor` —
    /// never a CALayer cornerRadius.
    private static let codeBackgroundColor = VColorDescriptor(red: 0.51, green: 0.55, blue: 0.59, alpha: 0.2)
    private static let codeFontFamily = "Menlo"
    /// Matches UIColor.link's light-mode RGB (0, 122, 255).
    private static let linkColor = VColorDescriptor(red: 0, green: 0.478, blue: 1, alpha: 1)
    /// Muted body-text tint for a `.blockquote`, distinct from `.primary` so a quote reads as
    /// de-emphasized next to a normal paragraph.
    private static let blockquoteTextColor = VColorDescriptor(red: 0.44, green: 0.44, blue: 0.46, alpha: 1)
    /// Fill for a blockquote's left bar — a shade darker than its muted text so the bar reads as
    /// a rule, not just more muted text.
    private static let blockquoteBarColor = VColorDescriptor(red: 0.64, green: 0.64, blue: 0.66, alpha: 1)
    private static let blockquoteBarWidth: CGFloat = 3
    private static let blockquoteBarGap: CGFloat = 10
    /// Fill for a `.thematicBreak`'s horizontal rule — a light separator gray, distinct from
    /// (and lighter than) the blockquote bar so a rule reads as a subtle divider, not a callout.
    private static let thematicBreakRuleColor = VColorDescriptor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1)

    /// Text color plus left-bar/rule decoration for a block kind — `.blockquote`'s muted color and
    /// vertical bar, `.thematicBreak`'s horizontal rule, `.primary` with neither for everything
    /// else. Shared by `makeDescriptor` (the `blockList` layout path) and `renderNode(for:)` (the
    /// `TextNode` DSL path) so the two can't silently diverge on how a block paints (Section 3
    /// cross-site consistency).
    static func textDecoration(
        for kind: MarkdownBlockKind
    ) -> (color: VColorDescriptor, barColor: VColorDescriptor?, barWidth: CGFloat, barGap: CGFloat, ruleColor: VColorDescriptor?) {
        switch kind {
        case .blockquote:
            return (blockquoteTextColor, blockquoteBarColor, blockquoteBarWidth, blockquoteBarGap, nil)
        case .thematicBreak:
            return (.primary, nil, 0, 0, thematicBreakRuleColor)
        default:
            return (.primary, nil, 0, 0, nil)
        }
    }

    /// One `InlineRun`'s markdown emphasis mapped onto a `TextRun` layered over `baseFont`/
    /// `baseColor`. Bold becomes a heavier weight — `VFontTraits` only defines `.italic`
    /// (NodeTable.swift:37), so bold is never a symbolic trait. Flags combine freely: a code
    /// span nested inside bold gets both the heavier weight AND the mono family + pill.
    ///
    /// Internal (not private): `TableCellLayout.swift` reuses this so table-cell emphasis
    /// mapping never drifts from paragraph/heading emphasis mapping (Section 3 cross-site
    /// consistency) — one formula, two call sites.
    static func textRun(for run: InlineRun, baseFont: VFontDescriptor, baseColor: VColorDescriptor) -> TextRun {
        var weight = baseFont.weight
        var traits = baseFont.traits
        var family = baseFont.family
        var color = baseColor
        var backgroundColor: VColorDescriptor?
        var strikethroughStyle = 0
        var linkURL: URL?

        if run.style.contains(.bold) {
            weight = VFontDescriptor.boldWeight
        }
        if run.style.contains(.italic) {
            traits.insert(.italic)
        }
        if run.style.contains(.code) {
            family = Self.codeFontFamily
            backgroundColor = Self.codeBackgroundColor
        }
        if run.style.contains(.strike) {
            strikethroughStyle = VUnderlineStyle.single.rawValue
        }
        if run.style.contains(.link) {
            color = Self.linkColor
            linkURL = run.url.flatMap(URL.init(string:))
        }

        return TextRun(
            length: run.text.utf16.count,
            font: VFontDescriptor(size: baseFont.size, weight: weight, family: family, traits: traits),
            color: color,
            strikethroughStyle: strikethroughStyle,
            backgroundColor: backgroundColor,
            linkURL: linkURL,
            mathSource: run.mathSource
        )
    }

    private static func makeDescriptor(_ parsed: ParsedMDBlock, theme: MarkdownTheme, isPendingTableHeader: Bool = false) -> TextDescriptor {
        let styled = style(parsed, theme: theme, isPendingTableHeader: isPendingTableHeader)

        // `styled.runs` must fold into the hash: two blocks with identical rendered content but
        // different inline styling (e.g. plain "bold" vs "**bold**", both rendering to the
        // content "bold") would otherwise collide onto the same layoutHash/appearanceHash and
        // serve a stale cached raster from HotBlockRasterizerStore/BlockDiff.
        var hasher = Hasher()
        hasher.combine(parsed.kind)
        hasher.combine(styled.content)
        hasher.combine(styled.runs)
        let hash = hasher.finalize()
        let decoration = Self.textDecoration(for: parsed.kind)

        return TextDescriptor(
            content: styled.content,
            font: styled.font,
            color: decoration.color,
            lineLimit: nil,
            lineBreakMode: 0,
            runs: styled.runs,
            leadingBarColor: decoration.barColor,
            leadingBarWidth: decoration.barWidth,
            leadingBarGap: decoration.barGap,
            ruleColor: decoration.ruleColor,
            layoutHash: hash,
            appearanceHash: hash
        )
    }

    private static func stripListMarker(_ line: String) -> String {
        var s = Substring(line)
        s = s.drop { $0 == " " }
        s = s.drop { $0 == "-" || $0 == "*" || $0 == "+" || $0.isNumber || $0 == "." || $0 == ")" }
        s = s.drop { $0 == " " }
        if Self.taskMarkerChecked(s) != nil {
            s = s.dropFirst(3).drop { $0 == " " }
        }
        return s.description
    }

    /// Recognizes a GFM task-list marker (`[ ]` unchecked, `[x]`/`[X]` checked) at the very
    /// start of `rest` — nil when `rest` doesn't start with one. Shared by the parser's
    /// `listMarkerInfo` (decides `MarkdownBlockKind.listItem`'s `checked`) and `stripListMarker`
    /// (drops the marker from rendered content), so the two can't disagree on what counts as a
    /// task marker.
    static func taskMarkerChecked(_ rest: Substring) -> Bool? {
        let chars = Array(rest.prefix(4))
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
        guard chars.count == 3 || chars[3] == " " else { return nil }
        switch chars[1] {
        case " ": return false
        case "x", "X": return true
        default: return nil
        }
    }

    /// listItem tokenizes the same marker-stripped text `style()` renders, via the same
    /// `stripListMarker` helper, so runs never disagree with what's painted. codeFence/table/
    /// thematicBreak never render as free-form styled text, so they get no runs — a `.table`
    /// block's cells are tokenized separately, per cell, into `ParsedMDBlock.tableRows`.
    static func tokenizableRuns(for kind: MarkdownBlockKind, text: String) -> [InlineRun] {
        switch kind {
        case .paragraph, .heading, .blockquote:
            return inlineRuns(text)
        case .listItem:
            return inlineRuns(Self.stripListMarker(text))
        case .codeFence, .table, .thematicBreak, .mathBlock, .image:
            return []
        }
    }

    /// True when `line` is a run of >= 3 backticks or tildes (CommonMark's fence-marker
    /// minimum), optionally padded with whitespace.
    private static func isFenceCloseShaped(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "`" } || trimmed.allSatisfy { $0 == "~" }
    }

    /// Strips a `.mathBlock`'s `$$`/`\[...\]` delimiters from its raw multi-line text, leaving
    /// bare TeX — the same convention `style()` uses to strip codeFence's fence-marker lines.
    /// Only the LEADING marker is ever assumed present (block detection guarantees it); the
    /// TRAILING marker is stripped only when it's actually shaped like one, so a still-streaming
    /// (unclosed) block never hides its most recently typed line.
    private static func stripMathBlockDelimiters(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return text }
        let trimmedFirst = first.drop { $0 == " " }
        let closeMarker: String
        if trimmedFirst.hasPrefix("$$") {
            closeMarker = "$$"
        } else if trimmedFirst.hasPrefix("\\[") {
            closeMarker = "\\]"
        } else {
            return text
        }
        var afterOpen = trimmedFirst.dropFirst(2)
        if afterOpen.first == " " { afterOpen = afterOpen.dropFirst() }

        if lines.count == 1 {
            if let closeRange = afterOpen.range(of: closeMarker) {
                var body = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                if body.last == " " { body = body.dropLast() }
                return String(body)
            }
            return String(afterOpen)
        }

        // When the marker sits alone on the opening line (the common "$$\nformula\n$$" shape),
        // drop that line entirely rather than leaving an empty first element — otherwise the
        // join below would prepend a stray blank line ("\nformula") ahead of the real content.
        if afterOpen.isEmpty {
            lines.removeFirst()
        } else {
            lines[0] = afterOpen
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == closeMarker {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

}

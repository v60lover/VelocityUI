// IncrementalMarkdownParser+HotScan.swift

import Foundation

/// Distinguishes genuinely new scan work from necessary reconsideration of ambiguous,
/// still-open input, so a regression that starts rescanning sealed-adjacent content again
/// shows up as a counter jump, not just a slower frame.
struct MarkdownScanCounters: Sendable, Equatable {
    /// Complete (newline-terminated) lines fed through the classifier for the first time.
    var linesScannedNew = 0
    /// Times the still-open trailing (not yet newline-terminated) line was reprocessed from
    /// scratch. Necessary, not a bug: its classification can still change until the newline
    /// arrives (e.g. "---" might still become a thematic break or a setext underline).
    var partialLineReconsiderations = 0
    /// Times reprocessing the still-open trailing line found it WOULD advance the seal boundary
    /// if it ended right there. Diagnostic only — that classification is provisional until a
    /// real newline arrives, so `append(_:)` never commits it early.
    var partialLineSeals = 0
    /// Times `hotBlocksState` was rebuilt by fully re-tokenizing/re-joining the open block's
    /// committed text (O(open-block size)) — `rebuildHotBlocksStateFromScan`/
    /// `materializeNonFenceHotBlocksState`. Capped at one per `append(_:)` call by construction
    /// (never per read); a regression that makes reads trigger this again shows up as a jump
    /// disproportionate to the number of `append(_:)` calls.
    var hotFullMaterializations = 0
    /// Times the `.codeFence`/`.mathBlock` O(delta) fast path ran instead of a full
    /// materialization — `appendPendingCharsToFenceFastPath`.
    var hotFastPathAppends = 0
    /// UTF-8 bytes actually copied into an open `.codeFence`/`.mathBlock`'s materialized text,
    /// summed across `appendPendingCharsToFenceFastPath` calls and per-line fence folds in
    /// `append(_:)`. Should grow by O(delta) per call, not O(block-size-so-far) -- a regression
    /// that re-copies the whole open fence on every line shows up as this counter growing
    /// quadratically with fence size instead of linearly.
    var fenceBytesCopiedTotal = 0
    /// UTF-8 bytes fed into `inlineRuns` while materializing open Tier-2 blocks. Includes the
    /// one-character left context when a frozen prefix exists. A lone unmatched opener keeps
    /// the suffix unsettled, so its measured cost may still grow with block length.
    var tier2CharsTokenizedTotal = 0
    /// Times the still-open pending line's block kind was already settled (paragraph/blockquote/
    /// listItem) and `PendingLineFastPath` grew it by delta bytes instead of re-running `step()`
    /// on the whole line -- see `settlePendingLineFastPath`/`extendPendingLineFastPath`.
    var pendingLineFastPathAppends = 0
    /// UTF-8 bytes actually copied while extending a settled `PendingLineFastPath` (`text` plus
    /// `strippedText` when present), summed across calls. Should grow by O(delta) per call, not
    /// O(line-size-so-far) -- a regression re-copying the whole pending line shows up as this
    /// counter growing quadratically with line size instead of linearly.
    var pendingLineFastPathBytesCopiedTotal = 0
}

/// Resumable scanner state for `IncrementalMarkdownParser`'s hot region. Every field here is
/// the running total of everything folded in via `step(_:into:)` so far — restarting a scan
/// from `HotScanState()` and replaying the same lines produces the same state as any prefix
/// checkpoint, which is what makes `append(_:)` resumable instead of a full rescan.
struct HotScanState: Equatable {
    /// Finalized blocks not yet sealed away (`sealCommittedPrefixIfNeeded()` in
    /// `IncrementalMarkdownParser.swift` moves a prefix of these into `sealedBlocks`).
    var blocks: [ParsedMDBlock] = []
    /// How many leading entries of `blocks` are provably sealed as of the last processed line.
    var pendingSealBlockCount = 0

    var openKind: MarkdownBlockKind?
    /// Count of lines folded into the current open block. Only ever compared against 1 (a
    /// setext/table promotion can only happen while exactly one line is buffered) — the lines
    /// themselves don't need to be retained past the first one, see `firstOpenLine`.
    var openLineCount = 0
    /// The open block's first line, kept only for setext-heading and paragraph->table
    /// promotion (both only fire while `openLineCount == 1`). Every other line's content lives
    /// solely in `openBlockCache`, so this never needs to grow into a full line array.
    var firstOpenLine: Substring?
    var openBlockCache: OpenBlockCache?

    var inFence = false
    var fenceMarker: Substring = ""
    var inMathBlock = false
    var mathBlockCloseMarker = ""
    var inContainer = false
    var containerBlankSeen = false
    /// `blocks.count` at the moment a blank line was seen inside an open container — the seal
    /// point to retroactively commit to if the container turns out to be closed, mirroring the
    /// old algorithm's `containerBlankCut`.
    var containerBlankCutBlockCount: Int?
}

/// Incrementally-maintained materialization of the still-open trailing block, so
/// `blockFromCache` doesn't have to rejoin every line and re-tokenize the whole block on every
/// `append(_:)` call — only the newly-added line's contribution is folded in.
struct OpenBlockCache: Equatable {
    var kind: MarkdownBlockKind
    var text: String
    /// Cached `[[TableCell]]` rows for a `.table` open block, extended one row at a time.
    var tableRows: [[TableCell]] = []
    /// Count of lines folded into `text` so far — used only to find the delimiter row (line
    /// index 1) so it's skipped the same way `parseTableRows` skips it.
    var lineCount = 0
}

extension IncrementalMarkdownParser {

    /// Builds a `ParsedMDBlock` from an already-materialized `OpenBlockCache` instead of
    /// rejoining/re-tokenizing raw lines — the resumable counterpart to `makeParsedBlock`.
    /// Must stay output-identical to `makeParsedBlock(kind:lines:)` for the same content;
    /// this is asserted by the differential oracle test.
    static func blockFromCache(
        kind: MarkdownBlockKind, cache: OpenBlockCache, retainedRuns: [InlineRun]? = nil
    ) -> ParsedMDBlock {
        var block = ParsedMDBlock(
            kind: kind, text: cache.text,
            runs: retainedRuns ?? Self.tokenizableRuns(for: kind, text: cache.text)
        )
        if case .table = kind {
            block.tableRows = cache.tableRows
        }
        return block
    }

    private static func makeOpenBlockCache(kind: MarkdownBlockKind, firstLine: Substring) -> OpenBlockCache {
        OpenBlockCache(kind: kind, text: String(firstLine), tableRows: [], lineCount: 1)
    }

    /// Extends `cache` with one more line already appended to the open block. Mirrors
    /// `makeParsedBlock`'s text-join (`\n`-separated) and `parseTableRows`'s row-skip rule
    /// (line index 1, the delimiter row, contributes no `TableCell` row) incrementally.
    private static func extendOpenBlockCache(_ cache: inout OpenBlockCache, newLine: Substring) {
        cache.text += "\n" + newLine
        cache.lineCount += 1
        if case .table(let alignments) = cache.kind, cache.lineCount != 2 {
            let cells = Self.splitTableRowCells(newLine, columnCount: alignments.count)
            cache.tableRows.append(cells.map { TableCell(text: $0, runs: inlineRuns($0)) })
        }
    }

    /// Folds one more line into `state`. This is the resumable counterpart to the per-line
    /// loop body inside the full-rescan test oracle (`IncrementalMarkdownParser+TestHooks.swift`):
    /// identical classification logic (same shared `static func` helpers), but each call only
    /// processes ONE new line instead of re-splitting and re-classifying the whole hot region
    /// every `append(_:)`. `append(_:)` calls this once per newly-completed line.
    ///
    /// `dryRun` is used for the still-open trailing partial line: it runs every classification
    /// branch below (so seal-boundary bookkeeping stays correct) but skips all
    /// `OpenBlockCache` string/array mutation. Without this, materializing the open block's
    /// full text fresh on every appended character would force a Copy-on-Write copy of the
    /// whole open block every keystroke — O(open-block-size) work per append instead of O(1).
    static func step(
        _ line: Substring, into state: inout HotScanState, dryRun: Bool = false,
        retainedOpenRuns: [InlineRun]? = nil
    ) {
        var retainedOpenRuns = retainedOpenRuns
        func finalizeOpenBlock() {
            guard let kind = state.openKind, state.openLineCount > 0 else { return }
            let block: ParsedMDBlock
            if dryRun {
                block = ParsedMDBlock(kind: kind, text: "")
            } else if let cache = state.openBlockCache {
                block = Self.blockFromCache(kind: kind, cache: cache, retainedRuns: retainedOpenRuns)
            } else {
                block = ParsedMDBlock(kind: kind, text: "")
            }
            state.blocks.append(block)
            state.openKind = nil
            state.openLineCount = 0
            state.firstOpenLine = nil
            state.openBlockCache = nil
            retainedOpenRuns = nil
        }
        func beginOpenBlock(_ kind: MarkdownBlockKind, line: Substring) {
            state.openKind = kind
            state.openLineCount = 1
            state.firstOpenLine = line
            if !dryRun {
                state.openBlockCache = Self.makeOpenBlockCache(kind: kind, firstLine: line)
            }
        }
        func appendToOpenBlock(_ line: Substring) {
            state.openLineCount += 1
            if !dryRun, state.openBlockCache != nil {
                Self.extendOpenBlockCache(&state.openBlockCache!, newLine: line)
            }
        }
        func retagOpenKind(_ kind: MarkdownBlockKind) {
            state.openKind = kind
            if !dryRun, state.openBlockCache != nil {
                state.openBlockCache!.kind = kind
            }
        }

        if state.inFence {
            appendToOpenBlock(line)
            if isFenceCloseShapedLine(line, opening: state.fenceMarker) {
                state.inFence = false
                finalizeOpenBlock()
                state.pendingSealBlockCount = state.blocks.count
            }
            return
        }

        if state.inMathBlock {
            appendToOpenBlock(line)
            if line.trimmingCharacters(in: .whitespaces) == state.mathBlockCloseMarker {
                state.inMathBlock = false
                finalizeOpenBlock()
                state.pendingSealBlockCount = state.blocks.count
            }
            return
        }

        if isBlankLine(line) {
            if state.inContainer {
                state.containerBlankSeen = true
                state.containerBlankCutBlockCount = state.blocks.count
                return
            }
            finalizeOpenBlock()
            state.pendingSealBlockCount = state.blocks.count
            return
        }

        if let (marker, language) = fenceOpenMarker(line) {
            finalizeOpenBlock()
            state.inContainer = false
            state.containerBlankSeen = false
            state.inFence = true
            state.fenceMarker = marker
            beginOpenBlock(.codeFence(language: language), line: line)
            return
        }

        if let (closeMarker, rest) = mathBlockOpenMarker(line) {
            finalizeOpenBlock()
            state.inContainer = false
            state.containerBlankSeen = false
            if rest.range(of: closeMarker) != nil {
                beginOpenBlock(.mathBlock, line: line)
                finalizeOpenBlock()
                return
            }
            state.inMathBlock = true
            state.mathBlockCloseMarker = closeMarker
            beginOpenBlock(.mathBlock, line: line)
            return
        }

        if let (level, headingText) = atxHeading(line) {
            finalizeOpenBlock()
            state.inContainer = false
            state.containerBlankSeen = false
            beginOpenBlock(.heading(level: level), line: Substring(headingText))
            finalizeOpenBlock()
            return
        }

        if case .paragraph = state.openKind, state.openLineCount == 1, let level = setextUnderlineLevel(line) {
            retagOpenKind(.heading(level: level))
            return
        }

        if isThematicBreakLine(line) {
            finalizeOpenBlock()
            state.inContainer = false
            state.containerBlankSeen = false
            beginOpenBlock(.thematicBreak, line: line)
            finalizeOpenBlock()
            return
        }

        if let url = imageLineURL(line) {
            finalizeOpenBlock()
            state.inContainer = false
            state.containerBlankSeen = false
            beginOpenBlock(.image(url: url), line: line)
            finalizeOpenBlock()
            return
        }

        if case .paragraph = state.openKind, state.openLineCount == 1, let first = state.firstOpenLine,
           first.contains("|"), let alignments = tableDelimiterRowAlignments(line) {
            // Promotion: the single buffered paragraph line was the header row all along — back
            // fill it as table row 0 before folding in the delimiter row (skipped, see below).
            if state.openBlockCache != nil {
                let headerCells = Self.splitTableRowCells(first, columnCount: alignments.count)
                state.openBlockCache!.tableRows = [headerCells.map { TableCell(text: $0, runs: inlineRuns($0)) }]
            }
            retagOpenKind(.table(alignments: alignments))
            appendToOpenBlock(line)
            return
        }
        if case .table = state.openKind, line.contains("|") {
            appendToOpenBlock(line)
            return
        }

        // A fresh column-0, non-marker line after a blank was seen inside an open container
        // definitively closes it — retroactively promotes the withheld blank-line seal.
        if state.inContainer, state.containerBlankSeen, !isListMarkerLine(line), !isBlockquoteMarkerLine(line),
           leadingSpaceCount(line) == 0 {
            state.inContainer = false
            state.containerBlankSeen = false
            if let cutCount = state.containerBlankCutBlockCount {
                state.pendingSealBlockCount = cutCount
            }
            state.containerBlankCutBlockCount = nil
        }

        if let info = listMarkerInfo(line) {
            finalizeOpenBlock()
            state.inContainer = true
            state.containerBlankSeen = false
            beginOpenBlock(
                .listItem(ordered: info.ordered, number: info.number, depth: info.depth, checked: info.checked),
                line: line
            )
            finalizeOpenBlock()
            return
        }

        if isBlockquoteMarkerLine(line) {
            if case .blockquote = state.openKind {
                appendToOpenBlock(line)
            } else {
                finalizeOpenBlock()
                beginOpenBlock(.blockquote, line: line)
            }
            state.inContainer = true
            state.containerBlankSeen = false
            return
        }

        if state.openKind == nil {
            beginOpenBlock(.paragraph, line: line)
        } else if case .paragraph = state.openKind {
            appendToOpenBlock(line)
        } else {
            finalizeOpenBlock()
            beginOpenBlock(.paragraph, line: line)
        }
    }
}

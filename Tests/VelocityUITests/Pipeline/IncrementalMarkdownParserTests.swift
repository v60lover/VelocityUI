// IncrementalMarkdownParserTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-k8qe: the incremental parser's sealed/hot two-tier emission, the three
/// named hazards from the spike (INCREMENTAL_PARSER_STABILITY_SPIKE.md), F-monotonicity, sealed-
/// index stability, and the generalized `diff(previous:new:frontier:)` split. Pure — no UIKit,
/// runs on plain `swift test`.
final class IncrementalMarkdownParserTests: XCTestCase {

    // MARK: - Hazard A: setext heading

    func testHazardA_SetextHeading_StaysHotUntilUnderlineAndBlankLineBothArrive() {
        var parser = IncrementalMarkdownParser()

        parser.append("Foo")
        XCTAssertEqual(parser.frontier, 0, "an open one-line paragraph with no blank line yet must stay hot")
        guard case .paragraph = parser.hotBlocksState.first?.kind else {
            return XCTFail("before the underline arrives this must still classify as a paragraph")
        }

        parser.append("\n===\n")
        XCTAssertEqual(parser.frontier, 0, "the heading conversion happens while still hot — no blank line has sealed it yet")
        guard case .heading(let level) = parser.hotBlocksState.first?.kind else {
            return XCTFail("Foo/=== must retroactively convert to a heading while still hot")
        }
        XCTAssertEqual(level, 1)

        parser.append("\n")
        XCTAssertEqual(parser.frontier, 1, "the trailing blank line finally seals the heading")
        guard case .heading(let sealedLevel) = parser.sealedBlocks[0].kind else {
            return XCTFail("the sealed block must be the heading — NEVER a stale paragraph bitmap")
        }
        XCTAssertEqual(sealedLevel, 1)
        XCTAssertEqual(parser.sealedBlocks[0].text, "Foo")
    }

    func testHazardA_SetextH2_DashUnderline() {
        var parser = IncrementalMarkdownParser()
        parser.append("Bar\n---\n\n")
        XCTAssertEqual(parser.frontier, 1)
        guard case .heading(let level) = parser.sealedBlocks[0].kind else {
            return XCTFail("Bar/--- must seal as a heading")
        }
        XCTAssertEqual(level, 2)
    }

    // MARK: - Hazard B: GFM table

    func testHazardB_TableDelimiterRow_JoinsPrecedingParagraphWhileHot() {
        var parser = IncrementalMarkdownParser()

        parser.append("| a | b |\n")
        XCTAssertEqual(parser.frontier, 0)
        guard case .paragraph = parser.hotBlocksState.first?.kind else {
            return XCTFail("before the delimiter row arrives this must still classify as a paragraph")
        }

        parser.append("|---|---|\n")
        XCTAssertEqual(parser.frontier, 0, "the table conversion happens while still hot")
        guard case .table(let alignments) = parser.hotBlocksState.first?.kind else {
            return XCTFail("the paragraph + delimiter row must join into ONE table block while hot")
        }
        XCTAssertEqual(alignments, [.none, .none])
        XCTAssertEqual(parser.hotBlocksState.count, 1, "must stay ONE block, not two separate ones")

        parser.append("\n")
        XCTAssertEqual(parser.frontier, 1, "the trailing blank line seals the joined table block")
        guard case .table = parser.sealedBlocks[0].kind else {
            return XCTFail("the sealed block must be the table — never a stale bare paragraph")
        }
    }

    // MARK: - VelocityUI-8ge8.1: grouped table cell grid, column count, per-column alignment

    func testGroupedTable_ParsesToOneBlockWithCellGridColumnCountAndAlignment() {
        var parser = IncrementalMarkdownParser()
        parser.append("| Name | Role |\n|:---|---:|\n| Ann | Lead |\n| Bo | Eng |\n\n")

        XCTAssertEqual(parser.frontier, 1, "the whole table must seal as one block")
        guard case .table(let alignments) = parser.sealedBlocks[0].kind else {
            return XCTFail("expected a .table block")
        }
        XCTAssertEqual(alignments, [.left, .right], "delimiter markers :--- and ---: must parse to left/right")

        let rows = parser.sealedBlocks[0].tableRows
        XCTAssertEqual(rows.count, 3, "header + 2 body rows")
        XCTAssertTrue(rows.allSatisfy { $0.count == 2 }, "every row must have exactly one cell per column")
        XCTAssertEqual(rows[0].map(\.text), ["Name", "Role"], "row 0 is the header")
        XCTAssertEqual(rows[1].map(\.text), ["Ann", "Lead"])
        XCTAssertEqual(rows[2].map(\.text), ["Bo", "Eng"])
    }

    func testGroupedTable_StreamingAppendsRowsWithoutRestylingAlreadySealedTable() {
        var parser = IncrementalMarkdownParser()
        parser.append("| a | b |\n|---|---|\n| 1 | 2 |\n")
        XCTAssertEqual(parser.frontier, 0, "still hot — no blank line yet")
        XCTAssertEqual(parser.hotBlocksState.last?.tableRows.count, 2, "header + 1 body row so far")

        parser.append("| 3 | 4 |\n")
        XCTAssertEqual(parser.hotBlocksState.last?.tableRows.count, 3, "a new body row appends while still hot")

        parser.append("\n")
        XCTAssertEqual(parser.frontier, 1, "the trailing blank line seals the table")
        let sealedRowsAtSealTime = parser.sealedBlocks[0].tableRows
        XCTAssertEqual(sealedRowsAtSealTime.count, 3)

        parser.append("An unrelated paragraph typed after the table.\n\n")
        XCTAssertEqual(parser.sealedBlocks[0].tableRows, sealedRowsAtSealTime,
            "content streamed in after the table must never restyle or mutate its already-sealed rows")
    }

    // MARK: - VelocityUI-wmss.3: suppress raw pipe flash before the delimiter row resolves

    /// Before the delimiter row arrives, the still-open header-candidate line must render as
    /// empty text — never the literal "| a | b |" pipe source — so no frame paints raw pipes.
    func testWmss3_HeaderLineBeforeDelimiter_RendersEmptyNotRawPipes() {
        var parser = IncrementalMarkdownParser()

        parser.append("| a | b |\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks.last?.fragment.content else {
            return XCTFail("expected a text fragment for the pending header line")
        }
        XCTAssertFalse(descriptor.content.contains("|"), "must never paint the raw pipe source while the row is still ambiguous")
        XCTAssertEqual(descriptor.content, "", "pending header line renders as empty text until the delimiter resolves it")
    }

    /// Once the delimiter row arrives, suppression lifts and the joined table row renders its
    /// real content again (not stuck permanently blank).
    func testWmss3_HeaderLineThenDelimiter_SuppressionLiftsAndTableRenders() {
        var parser = IncrementalMarkdownParser()

        parser.append("| a | b |\n")
        parser.append("|---|---|\n")
        guard case .table = parser.hotBlocksState.last?.kind else {
            return XCTFail("the paragraph + delimiter row must join into a table block")
        }
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks.last?.fragment.content else {
            return XCTFail("expected a text fragment for the joined table row")
        }
        XCTAssertFalse(descriptor.content.isEmpty, "the joined table row must render its real cell content, not stay suppressed")
        XCTAssertTrue(descriptor.content.contains("a"), "the header cell text must actually paint")
    }

    /// A line with pipes that turns out NOT to be a table (a plain line follows instead of a
    /// delimiter row) must still render as a normal paragraph with literal pipes — suppression
    /// only withholds rendering while genuinely ambiguous, never permanently.
    func testWmss3_PipeLineNotFollowedByDelimiter_RendersLiteralPipesAsPlainParagraph() {
        var parser = IncrementalMarkdownParser()

        parser.append("a | b | c\n")
        parser.append("not a table\n")
        guard case .paragraph = parser.hotBlocksState.last?.kind else {
            return XCTFail("no delimiter row followed — this must stay a plain paragraph")
        }
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks.last?.fragment.content else {
            return XCTFail("expected a text fragment for the resolved paragraph")
        }
        XCTAssertTrue(descriptor.content.contains("a | b | c"), "once resolved as non-table, the original pipe line must render literally")
    }

    // MARK: - Hazard C: fenced code block, blank line inside must NOT seal

    func testHazardC_BlankLineInsideOpenFence_NeverSealsPartialCodeBlock() {
        var parser = IncrementalMarkdownParser()

        parser.append("```\n")
        XCTAssertEqual(parser.frontier, 0)
        parser.append("first stanza\n")
        XCTAssertEqual(parser.frontier, 0)

        // The blank line here is INSIDE the open fence — it must NOT seal, unlike every other
        // blank line this test file exercises.
        parser.append("\n")
        XCTAssertEqual(parser.frontier, 0, "a blank line inside an open fence must not seal a partial code block")
        guard case .codeFence = parser.hotBlocksState.first?.kind else {
            return XCTFail("the fence must still be one open hot block")
        }
        XCTAssertEqual(parser.hotBlocksState.count, 1, "must stay ONE block spanning the blank line, not split in two")

        parser.append("second stanza\n")
        XCTAssertEqual(parser.frontier, 0)

        // The closing fence line itself is an unconditional seal point (a closed block is never
        // reopened) — no further blank line is required.
        parser.append("```\n")
        XCTAssertEqual(parser.frontier, 1, "a CLOSED fence seals immediately, without waiting for a trailing blank line")
        guard case .codeFence = parser.sealedBlocks[0].kind else {
            return XCTFail("the sealed block must be the whole fence, fence markers included in source")
        }
        XCTAssertEqual(parser.sealedBlocks[0].text, "```\nfirst stanza\n\nsecond stanza\n```",
            "the raw sealed block retains its fence markers — ParsedMDBlock.text is the raw source")

        // The rendered TextDescriptor content (what actually paints) strips the fence markers —
        // that stripping is IncrementalMarkdownParser.makeDescriptor's job, not ParsedMDBlock's.
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("a codeFence block must render as .text")
        }
        XCTAssertEqual(descriptor.content, "first stanza\n\nsecond stanza",
            "rendered content must include the blank line that was INSIDE the fence, and exclude the ``` markers")
    }

    func testHazardC_UnclosedFence_NeverSealsAtEOF() {
        var parser = IncrementalMarkdownParser()
        parser.append("```swift\nlet x = 1\n\nlet y = 2\n")
        XCTAssertEqual(parser.frontier, 0, "an unclosed fence must never seal, even across blank lines and many appends")
        XCTAssertEqual(parser.hotBlocksState.count, 1)
    }

    // Regression for L1: `makeDescriptor`'s `.codeFence` case used to drop the LAST line
    // unconditionally (assuming it was always the closing ``` marker). For a still-open
    // (streaming) fence the last line is real code, so that dropped the most recently streamed
    // code line from the rendered content until the fence closed — a real render bug on the
    // streaming-chat flagship path. The fix only drops the last line when it is actually shaped
    // like a closing fence marker.
    func testHazardC_UnclosedFence_RenderedContentIncludesLastStreamedCodeLine() {
        var parser = IncrementalMarkdownParser()
        parser.append("```\nlet x = 1\nlet y = 2\n")
        XCTAssertEqual(parser.frontier, 0, "still open — must not have sealed")

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks.last?.fragment.content else {
            return XCTFail("the open fence must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("let y = 2"),
            "the most recently streamed code line must NOT be dropped while the fence is still open")
        XCTAssertTrue(descriptor.content.contains("let x = 1"),
            "earlier streamed code lines must still render too")
    }

    // MARK: - F monotonicity + sealed-index stability

    func testFrontier_NeverDecreasesAcrossManyAppends() {
        var parser = IncrementalMarkdownParser()
        let chunks = [
            "Intro paragraph one.\n\n", "Second paragraph, ", "still growing.\n\n",
            "# A heading\n\n", "```\n", "code line 1\n", "\n", "code line 2\n", "```\n\n",
            "- item one\n", "- item two\n", "\n", "Not a list anymore.\n\n",
            "Final ", "trailing ", "paragraph",
        ]
        var lastFrontier = 0
        for chunk in chunks {
            parser.append(chunk)
            XCTAssertGreaterThanOrEqual(parser.frontier, lastFrontier, "F must be monotonically non-decreasing")
            lastFrontier = parser.frontier
        }
        XCTAssertGreaterThan(parser.frontier, 0, "at least some blocks must have sealed across this stream")
    }

    func testSealedBlocks_StableContentAcrossLaterAppends() {
        var parser = IncrementalMarkdownParser()
        parser.append("First paragraph.\n\n")
        XCTAssertEqual(parser.frontier, 1)
        let sealedSnapshot = parser.sealedBlocks[0]

        // A long, unrelated stream of further content must never perturb an already-sealed block.
        parser.append("Second paragraph.\n\n# Heading\n\n```\ncode\n```\n\n- item\n\nmore text")
        XCTAssertEqual(parser.sealedBlocks[0].kind, sealedSnapshot.kind)
        XCTAssertEqual(parser.sealedBlocks[0].text, sealedSnapshot.text)
        XCTAssertGreaterThan(parser.frontier, 1, "later content must still go on sealing further blocks")
    }

    func testBlockList_ParserIDsPersistFromHotCreationThroughSealing() {
        var parser = IncrementalMarkdownParser()
        parser.append("Growing")
        let hotID = parser.blockList(itemID: "msg", width: 300).first?.key.blockID
        XCTAssertNotNil(hotID)

        parser.append(" paragraph\n\n")
        let sealed = parser.blockList(itemID: "msg", width: 300)
        XCTAssertEqual(sealed.first?.key.blockID, hotID)
        XCTAssertEqual(sealed.first?.fragment.blockID, hotID)
    }

    // MARK: - List/blockquote backoff: trailing open container is not sealed across a blank line

    func testListBackoff_BlankLineInsideOpenList_DoesNotSealUntilContainerCloses() {
        var parser = IncrementalMarkdownParser()
        parser.append("- one\n- two\n")
        XCTAssertEqual(parser.frontier, 0)

        // A blank line after the last item does not by itself prove the list is done — a later
        // line could still fold in as a loose continuation.
        parser.append("\n")
        XCTAssertEqual(parser.frontier, 0, "a trailing open list must not be sealed by a single blank line")

        // A genuinely new, non-list paragraph at column 0 confirms the list really closed — NOW
        // it is safe to seal both items in one batch. The new paragraph's OWN trailing blank
        // line seals it too, in the same append.
        parser.append("Not a list item.\n\n")
        XCTAssertEqual(parser.frontier, 3, "closing the list seals both items, and the new paragraph's own blank line seals it too")
        guard case .listItem = parser.sealedBlocks[0].kind else { return XCTFail("block 0 must be a list item") }
        guard case .listItem = parser.sealedBlocks[1].kind else { return XCTFail("block 1 must be a list item") }
        guard case .paragraph = parser.sealedBlocks[2].kind else { return XCTFail("block 2 must be the new paragraph") }
    }

    // MARK: - diff(previous:new:frontier:) driven directly off the parser's output

    func testParserOutput_FeedsDiffCorrectly_UnchangedSealedVolatile() {
        var parser = IncrementalMarkdownParser()
        parser.append("Sealed paragraph.\n\n")
        let firstBlocks = parser.blockList(itemID: "msg", width: 300)
        XCTAssertEqual(firstBlocks.count, 1)

        parser.append("Second, still hot")
        let secondBlocks = parser.blockList(itemID: "msg", width: 300)
        XCTAssertEqual(secondBlocks.count, 2)

        let d = diff(previous: firstBlocks, new: secondBlocks, frontier: parser.frontier)
        XCTAssertEqual(d.unchanged, [0], "the sealed paragraph must be reported unchanged")
        XCTAssertEqual(d.sealedChanged, [])
        XCTAssertEqual(d.volatile, 1..<2, "the still-open second block must be volatile")
    }

    func testParserOutput_DebugSealedPrefixTripwire() {
        var parser = IncrementalMarkdownParser()
        parser.append("Sealed paragraph.\n\n")
        let firstBlocks = parser.blockList(itemID: "msg", width: 300)
        parser.append("more hot text")
        XCTAssertTrue(parser.debugSealedPrefixMatches(firstBlocks, itemID: "msg", width: 300),
            "an unrelated hot-region append must never perturb the already-sealed prefix")
    }

    // MARK: - Cost shape: hot region stays small for ordinary prose (bounded-reach theorem)

    func testBoundedReach_HotRegionStaysSmallAcrossManySealedParagraphs() {
        // Streaming N short, blank-line-separated paragraphs: the hot region (the still-open
        // tail) must stay small and NOT grow with N — the parser-level counterpart to 6qd's
        // flat-per-token-cost trend, asserted structurally (character count) rather than via
        // wall-clock timing to avoid flaking on loaded CI.
        var parser = IncrementalMarkdownParser()
        var maxHotChars = 0
        for i in 0..<200 {
            parser.append("Paragraph number \(i) with a bit of filler text to bulk it out.\n\n")
            let hotChars = parser.hotBlocksState.reduce(0) { $0 + $1.text.count }
            maxHotChars = max(maxHotChars, hotChars)
        }
        XCTAssertEqual(parser.frontier, 200, "every fully blank-line-terminated paragraph must have sealed")
        // A single filler paragraph is on the order of ~60 characters — the hot region must stay
        // within a small constant multiple of ONE paragraph's size, never scale with N=200.
        XCTAssertLessThan(maxHotChars, 200, "the hot region must stay O(1) in message length, not grow with N")
    }

    // MARK: - Unclosed/huge fence: correctness holds; O(appended)-per-token rasterization is a
    // known, separately-tracked gap (see VelocityUI-k8qe's design notes) — NOT claimed by this
    // test. What IS asserted: the fence never incorrectly seals mid-growth (matches
    // testHazardC_UnclosedFence_NeverSealsAtEOF above), and the hot block's reported byte size
    // tracks exactly what has streamed so far (no unbounded/duplicated growth bug).

    func testUnclosedFence_HotBlockSizeTracksStreamedContentExactly() {
        var parser = IncrementalMarkdownParser()
        var previousLen = 0
        for i in 0..<50 {
            parser.append("line \(i)\n")
            XCTAssertEqual(parser.frontier, 0)
        }
        // Establish the fence AFTER the loop above would have made these lines plain paragraphs;
        // re-run properly fenced this time.
        parser = IncrementalMarkdownParser()
        parser.append("```\n")
        for i in 0..<50 {
            parser.append("line \(i)\n")
            let currentLen = parser.hotBlocksState.reduce(0) { $0 + $1.text.count }
            XCTAssertGreaterThanOrEqual(currentLen, previousLen, "the open fence's tracked content must grow monotonically as lines stream in")
            previousLen = currentLen
        }
        XCTAssertEqual(parser.frontier, 0, "still unclosed — must not have sealed")
    }

    // MARK: - T2: flat per-token cost through the parser, asserted via call counts (not timing)

    /// Where the test above proxies the Theta(n) vs Theta(n^2) claim via hot-region character
    /// count, this one proxies it directly: drives the real parser -> diff -> freeze pipeline and
    /// asserts `measure`/`rasterize` CALL COUNTS — once a block seals and freezes, it must incur
    /// ZERO further calls no matter how much more streams in after it. Reuses
    /// `BlockReuseTests.MeasureRasterizeSpy` and avoids `Task.sleep`/wall-clock timing (flake risk
    /// on loaded CI) — purely structural call-count arithmetic.
    func testFlatPerTokenCost_SealedBlocksIncurZeroFurtherMeasureRasterizeCallsAsStreamGrows() {
        let spy = BlockReuseTests.MeasureRasterizeSpy()
        var cache: [BlockKey: FreezeState] = [:]
        var parser = IncrementalMarkdownParser()
        var previousBlocks: [Block] = []
        var sealedFrozenCount = 0

        for i in 0..<100 {
            parser.append("Paragraph number \(i) with a bit of filler text to bulk it out.\n\n")
            let newBlocks = parser.blockList(itemID: "msg", width: 300)
            let d = diff(previous: previousBlocks, new: newBlocks, frontier: parser.frontier)

            // Mirrors the bind site's persist path: freeze exactly the newly-sealed indices this
            // round. `d.unchanged` (everything sealed on an EARLIER round) is intentionally never
            // touched here — that is the whole point of the assertion below.
            for idx in d.sealedChanged {
                freeze(newBlocks[idx], scale: 2, cache: &cache, measure: spy.measure, rasterize: spy.rasterize)
                sealedFrozenCount += 1
            }
            previousBlocks = newBlocks
        }

        XCTAssertEqual(parser.frontier, 100, "every fully blank-line-terminated paragraph must have sealed")
        XCTAssertGreaterThan(sealedFrozenCount, 0, "at least some paragraphs must have sealed and been frozen")
        XCTAssertEqual(spy.measureCallCount, sealedFrozenCount,
            "cumulative measure calls must equal the number of sealed blocks frozen (each measured exactly once) — "
            + "if a sealed block were re-measured on a later round, this would grow past sealedFrozenCount as the stream grows")
        XCTAssertEqual(spy.rasterizeCallCount, sealedFrozenCount,
            "cumulative rasterize calls must equal the number of sealed blocks frozen, for the same reason")
    }

    // MARK: - VelocityUI-fzvf.4: frontier holds with inline runs present (bold/italic/code/link)

    /// Same shape as `testSealedBlocks_StableContentAcrossLaterAppends`, but the sealed block
    /// carries inline emphasis, an inline code span, and a link — the case the earlier
    /// plain-text-only coverage never exercised. `runs` (not just `text`) must stay identical.
    func testSealedBlocks_StableRunsAcrossLaterAppends_WithInlineMarkup() {
        var parser = IncrementalMarkdownParser()
        parser.append("A **bold** and *italic* word with `code` and a [link](https://example.com).\n\n")
        XCTAssertEqual(parser.frontier, 1)
        let sealedSnapshot = parser.sealedBlocks[0]
        XCTAssertGreaterThan(sealedSnapshot.runs.count, 1, "precondition: the sealed block must actually carry multiple inline runs")

        // A long, unrelated stream of further mixed markdown must never perturb the already-sealed
        // block's tokenized runs.
        parser.append(
            "Second **paragraph** with `more code`.\n\n# Heading\n\n```\ncode\n```\n\n"
            + "- item with *emphasis*\n\nmore text with a [link](https://other.example)"
        )
        XCTAssertEqual(parser.sealedBlocks[0].kind, sealedSnapshot.kind)
        XCTAssertEqual(parser.sealedBlocks[0].text, sealedSnapshot.text)
        XCTAssertEqual(parser.sealedBlocks[0].runs, sealedSnapshot.runs, "a sealed block's tokenized inline runs must never change once frozen")
        XCTAssertGreaterThan(parser.frontier, 1, "later content must still go on sealing further blocks")
    }

    /// `debugSealedPrefixMatches` (the tripwire `FeedScrollView`/callers rely on) must still hold
    /// when the sealed prefix contains inline runs, not just plain text.
    func testParserOutput_DebugSealedPrefixTripwire_WithInlineMarkup() {
        var parser = IncrementalMarkdownParser()
        parser.append("A **bold** word, `inline code`, and a [link](https://example.com) here.\n\n")
        let firstBlocks = parser.blockList(itemID: "msg", width: 300)
        parser.append("more hot text with *italic* and `code` too")
        XCTAssertTrue(parser.debugSealedPrefixMatches(firstBlocks, itemID: "msg", width: 300),
            "an unrelated hot-region append must never perturb an already-sealed prefix, even when that prefix carries inline runs")
    }

    /// Locks in the claim documented at `IncrementalMarkdownParser.makeDescriptor`'s comment
    /// (IncrementalMarkdownParser.swift:648-651): two blocks that render to the SAME final text
    /// but differ only in inline styling must NOT collide onto the same `contentHash` — otherwise
    /// `HotBlockRasterizerStore`/`BlockDiff` would serve a stale cached raster for the wrong style.
    func testContentHash_DistinguishesInlineStylingFromPlainTextWithSameRenderedContent() {
        var plainParser = IncrementalMarkdownParser()
        plainParser.append("just bold text\n\n")
        var boldParser = IncrementalMarkdownParser()
        boldParser.append("**just bold text**\n\n")

        let plainBlock = plainParser.blockList(itemID: "msg", width: 300)[0]
        let boldBlock = boldParser.blockList(itemID: "msg", width: 300)[0]

        guard case .text(let plainDescriptor) = plainBlock.fragment.content,
              case .text(let boldDescriptor) = boldBlock.fragment.content else {
            return XCTFail("both blocks must render as .text fragments")
        }
        XCTAssertEqual(plainDescriptor.content, boldDescriptor.content, "precondition: both must render to the identical final string once markers are stripped")
        XCTAssertNotEqual(plainBlock.contentHash, boldBlock.contentHash,
            "contentHash must reflect TextRuns, not just rendered text — a plain vs. all-bold block with identical text must not collide")
    }

    /// Extends `testFlatPerTokenCost_SealedBlocksIncurZeroFurtherMeasureRasterizeCallsAsStreamGrows`
    /// to blocks that carry inline runs (bold/code/link per paragraph) — proves inline-run
    /// tokenization on the hot tail doesn't leak into re-measuring/re-rasterizing already-sealed
    /// blocks as the stream grows.
    func testFlatPerTokenCost_SealedBlocksWithInlineRuns_IncurZeroFurtherCalls() {
        let spy = BlockReuseTests.MeasureRasterizeSpy()
        var cache: [BlockKey: FreezeState] = [:]
        var parser = IncrementalMarkdownParser()
        var previousBlocks: [Block] = []
        var sealedFrozenCount = 0

        for i in 0..<100 {
            parser.append("Paragraph **\(i)** with `inline code` and a [link](https://example.com/\(i)).\n\n")
            let newBlocks = parser.blockList(itemID: "msg", width: 300)
            let d = diff(previous: previousBlocks, new: newBlocks, frontier: parser.frontier)

            for idx in d.sealedChanged {
                freeze(newBlocks[idx], scale: 2, cache: &cache, measure: spy.measure, rasterize: spy.rasterize)
                sealedFrozenCount += 1
            }
            previousBlocks = newBlocks
        }

        XCTAssertEqual(parser.frontier, 100, "every fully blank-line-terminated paragraph must have sealed")
        XCTAssertGreaterThan(sealedFrozenCount, 0, "at least some paragraphs must have sealed and been frozen")
        XCTAssertEqual(spy.measureCallCount, sealedFrozenCount,
            "cumulative measure calls must equal the number of sealed blocks frozen, even with inline runs present on every block — "
            + "if a sealed block were re-measured on a later round, this would grow past sealedFrozenCount as the stream grows")
        XCTAssertEqual(spy.rasterizeCallCount, sealedFrozenCount,
            "cumulative rasterize calls must equal the number of sealed blocks frozen, for the same reason")
    }
}

// IncrementalMarkdownParserExtensionsTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-fzvf.1: ATX headings, code-fence language capture, ordered-list
/// number/depth, thematic breaks, and inline-run tokenization. Pure — no UIKit, runs on plain
/// `swift test`. Regression coverage for setext/sealing behavior already lives in
/// IncrementalMarkdownParserTests.swift and is untouched by this bead.
final class IncrementalMarkdownParserExtensionsTests: XCTestCase {

    // MARK: - ATX headings

    func testATXHeading_StripsHashesAndCapturesLevel() {
        var parser = IncrementalMarkdownParser()
        parser.append("# Title\n\n")
        XCTAssertEqual(parser.frontier, 1)
        guard case .heading(let level) = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as a heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(parser.sealedBlocks[0].text, "Title", "the leading '#' + space must be stripped")
    }

    func testATXHeading_LevelSixAndRejectsSeven() {
        var parser = IncrementalMarkdownParser()
        parser.append("###### H6\n\n")
        guard case .heading(let level) = parser.sealedBlocks[0].kind else {
            return XCTFail("###### must be a level-6 heading")
        }
        XCTAssertEqual(level, 6)

        var parser2 = IncrementalMarkdownParser()
        parser2.append("####### not a heading\n\n")
        guard case .paragraph = parser2.sealedBlocks[0].kind else {
            return XCTFail("7+ '#' is not a valid ATX marker — must fall back to a paragraph")
        }
    }

    func testATXHeading_RequiresSpaceAfterHashes() {
        var parser = IncrementalMarkdownParser()
        parser.append("#nospace\n\n")
        guard case .paragraph = parser.sealedBlocks[0].kind else {
            return XCTFail("'#' with no following space must not classify as a heading")
        }
    }

    func testSetextHeading_StillWorksAlongsideATX() {
        // Regression guard: ATX detection must not shadow the pre-existing setext path.
        var parser = IncrementalMarkdownParser()
        parser.append("Title\n===\n\n")
        guard case .heading(let level) = parser.sealedBlocks[0].kind else {
            return XCTFail("setext underline must still convert the preceding paragraph to a heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(parser.sealedBlocks[0].text, "Title")
    }

    // MARK: - Code-fence language

    func testCodeFence_CapturesInfoStringAsLanguage() {
        var parser = IncrementalMarkdownParser()
        parser.append("```swift\nlet x = 1\n```\n\n")
        guard case .codeFence(let language) = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as a code fence")
        }
        XCTAssertEqual(language, "swift")
    }

    func testCodeFence_NoInfoStringIsNilLanguage() {
        var parser = IncrementalMarkdownParser()
        parser.append("```\nplain\n```\n\n")
        guard case .codeFence(let language) = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as a code fence")
        }
        XCTAssertNil(language)
    }

    // MARK: - Ordered list number + depth

    // These list-block assertions read `hotBlocksState`, not `sealedBlocks`: a single trailing
    // blank line after list items never seals them (see the pre-existing
    // testListBackoff_BlankLineInsideOpenList_DoesNotSealUntilContainerCloses in
    // IncrementalMarkdownParserTests.swift) — the classification is already correct while hot,
    // which is all these tests check.

    func testOrderedList_PreservesActualNumberAcrossItems() {
        var parser = IncrementalMarkdownParser()
        parser.append("1. first\n2. second\n\n")
        XCTAssertGreaterThanOrEqual(parser.hotBlocksState.count, 2)
        guard case .listItem(let ordered0, let number0, _) = parser.hotBlocksState[0].kind else {
            return XCTFail("block 0 must be a list item")
        }
        XCTAssertTrue(ordered0)
        XCTAssertEqual(number0, 1)
        guard case .listItem(let ordered1, let number1, _) = parser.hotBlocksState[1].kind else {
            return XCTFail("block 1 must be a list item")
        }
        XCTAssertTrue(ordered1)
        XCTAssertEqual(number1, 2)
    }

    func testOrderedList_NonSequentialStartNumberIsPreservedVerbatim() {
        var parser = IncrementalMarkdownParser()
        parser.append("7. seven\n\n")
        guard case .listItem(_, let number, _) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(number, 7, "the literal digit run from the source must be kept, not renumbered from 1")
    }

    func testOrderedList_NestedItemGetsGreaterDepth() {
        var parser = IncrementalMarkdownParser()
        parser.append("1. top\n  2. nested\n\n")
        guard case .listItem(_, _, let topDepth) = parser.hotBlocksState[0].kind else {
            return XCTFail("block 0 must be a list item")
        }
        guard case .listItem(_, _, let nestedDepth) = parser.hotBlocksState[1].kind else {
            return XCTFail("block 1 must be a list item")
        }
        XCTAssertEqual(topDepth, 0)
        XCTAssertGreaterThan(nestedDepth, topDepth, "the 2-space-indented item must carry a deeper nesting depth")
    }

    func testUnorderedList_RendersBulletNotNumber() {
        var parser = IncrementalMarkdownParser()
        parser.append("- item\n\n")
        guard case .listItem(let ordered, _, _) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertFalse(ordered)
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("•"), "an unordered item must still render a bullet")
    }

    func testOrderedList_RendersActualNumberNotBullet() {
        var parser = IncrementalMarkdownParser()
        parser.append("3. third\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("3."), "ordered items must render their real number instead of collapsing to a bullet")
        XCTAssertFalse(descriptor.content.contains("•"), "ordered items must not fall back to the unordered bullet")
    }

    // MARK: - Thematic break

    func testThematicBreak_DashStarUnderscore_AllRecognized() {
        for marker in ["---", "***", "___"] {
            var parser = IncrementalMarkdownParser()
            parser.append("\(marker)\n\n")
            guard case .thematicBreak = parser.sealedBlocks[0].kind else {
                return XCTFail("'\(marker)' must classify as a thematic break")
            }
        }
    }

    func testThematicBreak_DoesNotShadowSetextH2() {
        // '---' immediately after a single open paragraph line is a setext underline, not a
        // thematic break — CommonMark's own precedence, unchanged by adding thematic breaks.
        var parser = IncrementalMarkdownParser()
        parser.append("Heading\n---\n\n")
        guard case .heading(let level) = parser.sealedBlocks[0].kind else {
            return XCTFail("'---' after a single paragraph line must still convert it to a setext heading")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(parser.sealedBlocks.count, 1, "must be ONE heading block, not heading + thematic break")
    }

    // MARK: - inlineRuns: single-style spans

    func testInlineRuns_PlainText_IsOneUnstyledRun() {
        let runs = inlineRuns("hello world")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "hello world")
        XCTAssertEqual(runs[0].style, [])
        XCTAssertNil(runs[0].url)
    }

    func testInlineRuns_Bold() {
        let runs = inlineRuns("**bold**")
        XCTAssertEqual(runs, [InlineRun(text: "bold", style: .bold, url: nil)])
    }

    func testInlineRuns_ItalicStar() {
        let runs = inlineRuns("*italic*")
        XCTAssertEqual(runs, [InlineRun(text: "italic", style: .italic, url: nil)])
    }

    func testInlineRuns_ItalicUnderscore() {
        let runs = inlineRuns("_italic_")
        XCTAssertEqual(runs, [InlineRun(text: "italic", style: .italic, url: nil)])
    }

    func testInlineRuns_BoldItalicCombined() {
        let runs = inlineRuns("***both***")
        XCTAssertEqual(runs, [InlineRun(text: "both", style: [.bold, .italic], url: nil)])
    }

    func testInlineRuns_InlineCode() {
        let runs = inlineRuns("`code`")
        XCTAssertEqual(runs, [InlineRun(text: "code", style: .code, url: nil)])
    }

    func testInlineRuns_Strikethrough() {
        let runs = inlineRuns("~~strike~~")
        XCTAssertEqual(runs, [InlineRun(text: "strike", style: .strike, url: nil)])
    }

    func testInlineRuns_Link() {
        let runs = inlineRuns("[t](u)")
        XCTAssertEqual(runs, [InlineRun(text: "t", style: .link, url: "u")])
    }

    func testInlineRuns_MixedPlainAndStyled() {
        let runs = inlineRuns("plain **bold** plain")
        XCTAssertEqual(runs, [
            InlineRun(text: "plain ", style: [], url: nil),
            InlineRun(text: "bold", style: .bold, url: nil),
            InlineRun(text: " plain", style: [], url: nil),
        ])
    }

    // MARK: - inlineRuns: nested spans (bold containing code)

    func testInlineRuns_BoldContainingCode_SplitsIntoThreeRuns() {
        let runs = inlineRuns("**bold `code` text**")
        XCTAssertEqual(runs, [
            InlineRun(text: "bold ", style: .bold, url: nil),
            InlineRun(text: "code", style: [.bold, .code], url: nil),
            InlineRun(text: " text", style: .bold, url: nil),
        ])
    }

    func testInlineRuns_LinkTextCarriesItsOwnEmphasis() {
        let runs = inlineRuns("[**bold link**](u)")
        XCTAssertEqual(runs, [InlineRun(text: "bold link", style: [.bold, .link], url: "u")])
    }

    // MARK: - inlineRuns: streaming mid-token prefixes

    func testInlineRuns_UnclosedBold_DegradesToLiteralText() {
        let runs = inlineRuns("**still typ")
        XCTAssertEqual(runs, [InlineRun(text: "still typ", style: .bold, url: nil)],
            "an opened-but-not-yet-closed delimiter must not crash — the still-streaming text renders under the opened style")
    }

    func testInlineRuns_UnclosedCode_FallsBackToLiteralBacktick() {
        let runs = inlineRuns("`still typing")
        XCTAssertEqual(runs, [InlineRun(text: "`still typing", style: [], url: nil)],
            "an unmatched opening backtick must render literally rather than swallowing the rest of the line")
    }

    func testInlineRuns_UnclosedLinkBracket_FallsBackToLiteralBracket() {
        let runs = inlineRuns("[still typing")
        XCTAssertEqual(runs, [InlineRun(text: "[still typing", style: [], url: nil)])
    }

    // MARK: - ParsedMDBlock.runs wiring: only text-bearing kinds tokenize

    func testParagraphBlock_CarriesTokenizedRuns() {
        var parser = IncrementalMarkdownParser()
        parser.append("**bold** text\n\n")
        XCTAssertEqual(parser.sealedBlocks[0].runs, [
            InlineRun(text: "bold", style: .bold, url: nil),
            InlineRun(text: " text", style: [], url: nil),
        ])
    }

    func testCodeFenceBlock_NeverTokenizesItsContentAsMarkdown() {
        var parser = IncrementalMarkdownParser()
        parser.append("```\n**not bold**\n```\n\n")
        XCTAssertEqual(parser.sealedBlocks[0].runs, [], "code-fence content must never be inline-tokenized")
    }

    func testListItemBlock_TokenizesMarkerStrippedContent() {
        // Single trailing blank line after a list item does not seal it (see the hotBlocksState
        // note above) — read the hot block, which already carries the final classification.
        var parser = IncrementalMarkdownParser()
        parser.append("- **bold** item\n\n")
        guard case .listItem = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(parser.hotBlocksState[0].runs, [
            InlineRun(text: "bold", style: .bold, url: nil),
            InlineRun(text: " item", style: [], url: nil),
        ], "the '- ' marker must never leak into the tokenized runs")
    }
}

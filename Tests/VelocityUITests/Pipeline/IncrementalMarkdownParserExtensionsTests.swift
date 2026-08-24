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

    // MARK: - VelocityUI-fzvf.2: InlineRun -> TextRun mapping onto TextDescriptor.runs

    private func descriptor(for markdown: String) -> TextDescriptor {
        var parser = IncrementalMarkdownParser()
        parser.append(markdown)
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            fatalError("must render as .text")
        }
        return descriptor
    }

    /// Content must be rebuilt from the tokenized runs, not the raw markdown source — the bug
    /// this bead fixes: markdown delimiters used to ride straight through into rendered content.
    func testMixedInlineMarkdown_ContentHasNoLeftoverDelimitersAndRunsCoverItExactly() {
        let d = descriptor(for: "**bold** *italic* ***both*** `code` ~~strike~~ [link](https://example.com)\n\n")
        XCTAssertFalse(d.content.contains("*"), "asterisks must not leak into rendered content")
        XCTAssertFalse(d.content.contains("`"), "backticks must not leak into rendered content")
        XCTAssertFalse(d.content.contains("~"), "tildes must not leak into rendered content")
        XCTAssertFalse(d.content.contains("["), "link brackets must not leak into rendered content")
        let totalRunLength = d.runs.reduce(0) { $0 + $1.length }
        XCTAssertEqual(totalRunLength, d.content.utf16.count, "run lengths must sum to exactly the rendered content")
    }

    func testBold_MapsToBoldWeight() {
        let d = descriptor(for: "**bold**\n\n")
        XCTAssertEqual(d.runs.count, 1)
        XCTAssertEqual(d.runs[0].font.weight, VFontDescriptor.boldWeight)
    }

    func testItalic_MapsToItalicTraitAtRegularWeight() {
        let d = descriptor(for: "*italic*\n\n")
        XCTAssertEqual(d.runs.count, 1)
        XCTAssertTrue(d.runs[0].font.traits.contains(.italic))
        XCTAssertEqual(d.runs[0].font.weight, VFontDescriptor.regularWeight)
    }

    func testBoldItalic_MapsToBoldWeightAndItalicTraitTogether() {
        let d = descriptor(for: "***both***\n\n")
        XCTAssertEqual(d.runs.count, 1)
        XCTAssertEqual(d.runs[0].font.weight, VFontDescriptor.boldWeight)
        XCTAssertTrue(d.runs[0].font.traits.contains(.italic))
    }

    func testInlineCode_MapsToMonoFamilyAndBackgroundPill() {
        let d = descriptor(for: "`code`\n\n")
        XCTAssertEqual(d.runs.count, 1)
        XCTAssertEqual(d.runs[0].font.family, "Menlo")
        XCTAssertNotNil(d.runs[0].backgroundColor, "inline code must carry a background pill drawn into the bitmap")
    }

    func testStrikethrough_SetsStrikethroughStyle() {
        let d = descriptor(for: "~~strike~~\n\n")
        XCTAssertEqual(d.runs.count, 1)
        XCTAssertEqual(d.runs[0].strikethroughStyle, VUnderlineStyle.single.rawValue)
    }

    func testLink_CarriesURLAndRecolors() {
        let d = descriptor(for: "[tap me](https://example.com)\n\n")
        XCTAssertEqual(d.runs.count, 1)
        XCTAssertEqual(d.runs[0].linkURL, URL(string: "https://example.com"))
        XCTAssertNotEqual(d.runs[0].color, VColorDescriptor.primary, "a link must recolor away from the base ink color")
    }

    /// The nested-style acceptance criterion: a code span inside bold text must render BOTH —
    /// bold weight AND the mono family + pill, not just one or the other.
    func testNestedBoldContainingCode_RendersBothStyles() {
        let d = descriptor(for: "**bold `code` text**\n\n")
        guard let codeRun = d.runs.first(where: { $0.font.family == "Menlo" }) else {
            return XCTFail("must contain a run carrying the mono family")
        }
        XCTAssertEqual(codeRun.font.weight, VFontDescriptor.boldWeight, "the nested code span must keep the enclosing bold weight")
        XCTAssertNotNil(codeRun.backgroundColor, "the nested code span must still carry its background pill")
    }

    func testListItemPrefix_StaysBaseStyleEvenWhenFirstSpanIsStyled() {
        var parser = IncrementalMarkdownParser()
        parser.append("- **bold** item\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let d) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(d.content.hasPrefix("• "), "the bullet prefix must render before the styled text")
        XCTAssertEqual(d.runs.first?.length, "• ".utf16.count, "the prefix must be its own leading run")
        XCTAssertEqual(d.runs.first?.font.weight, VFontDescriptor.regularWeight, "the bullet prefix must never inherit the first span's emphasis")
    }

    /// Regression guard for the hash-collision bug found while implementing this bead: plain
    /// "bold" text and "**bold**" markdown both render to the SAME content ("bold"), but they
    /// must NOT collide onto the same contentHash — HotBlockRasterizerStore/BlockDiff key their
    /// cached raster off Block.contentHash, so a collision would serve a stale bitmap for one of
    /// the two after only the other one's styling changed.
    func testDifferentInlineStylingWithIdenticalRenderedText_ProducesDifferentContentHash() {
        var plainParser = IncrementalMarkdownParser()
        plainParser.append("bold\n\n")
        let plainBlock = plainParser.blockList(itemID: "msg", width: 300)[0]

        var boldParser = IncrementalMarkdownParser()
        boldParser.append("**bold**\n\n")
        let boldBlock = boldParser.blockList(itemID: "msg", width: 300)[0]

        guard case .text(let plainDescriptor) = plainBlock.fragment.content,
              case .text(let boldDescriptor) = boldBlock.fragment.content else {
            return XCTFail("both must render as .text")
        }
        XCTAssertEqual(plainDescriptor.content, boldDescriptor.content, "both must render to the same visible text")
        XCTAssertNotEqual(plainBlock.contentHash, boldBlock.contentHash,
            "identical rendered text with different inline styling must not collide onto the same contentHash")
    }
}

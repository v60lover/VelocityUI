// IncrementalMarkdownParserMathTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-gojy.2: inline math (`$...$` / `\(...\)`) and block math (`$$...$$` / `\[...\]`)
/// parsing in the incremental markdown parser. Parser-only scope — rendering/rasterization lands
/// in gojy.3/.4. Pure — no UIKit, runs on plain `swift test`.
final class IncrementalMarkdownParserMathTests: XCTestCase {

    // MARK: - Inline math: `$...$` (dollar delimiters)

    func testInlineDollarMath_ParsesToRunCarryingRawTeX() {
        let runs = inlineRuns("$x^2$")
        XCTAssertEqual(runs.count, 1, "must produce exactly one run")
        XCTAssertEqual(runs[0].text, "x^2", "text must hold the raw TeX without delimiters")
        XCTAssertEqual(runs[0].mathSource, "x^2", "mathSource must hold the same raw TeX")
        XCTAssertEqual(runs[0].style, [], "math runs must have no emphasis style flags")
        XCTAssertNil(runs[0].url, "math runs must have no URL")
    }

    func testInlineDollarMath_WithComplexFormula() {
        let runs = inlineRuns("$a_{i,j}^{2} + \\sqrt{b}$")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].mathSource, "a_{i,j}^{2} + \\sqrt{b}")
    }

    // MARK: - Inline math: `\(...\)` (parenthesis delimiters)

    func testInlineParenthesisMath_ParsesToRunCarryingRawTeX() {
        let runs = inlineRuns("\\(x^2\\)")
        XCTAssertEqual(runs.count, 1, "must produce exactly one run")
        XCTAssertEqual(runs[0].text, "x^2", "text must hold the raw TeX without delimiters")
        XCTAssertEqual(runs[0].mathSource, "x^2", "mathSource must hold the same raw TeX")
        XCTAssertEqual(runs[0].style, [], "math runs must have no emphasis style flags")
        XCTAssertNil(runs[0].url)
    }

    func testInlineParenthesisMath_WithComplexFormula() {
        let runs = inlineRuns("\\(\\frac{a}{b}\\)")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].mathSource, "\\frac{a}{b}")
    }

    // MARK: - Inline math: no emphasis tokenization inside delimiters

    func testInlineDollarMath_DoesNotTokenizeEmphasisMarkers() {
        let runs = inlineRuns("$a_b * c$")
        XCTAssertEqual(runs.count, 1, "underscore and asterisk inside math must not split the run")
        XCTAssertEqual(runs[0].mathSource, "a_b * c", "raw TeX must be preserved exactly including the markers")
        XCTAssertEqual(runs[0].style, [], "no italic or other style from the underscores and asterisks")
    }

    func testInlineParenthesisMath_DoesNotTokenizeEmphasisMarkers() {
        let runs = inlineRuns("\\(*x* + _y_\\)")
        XCTAssertEqual(runs.count, 1, "asterisks and underscores inside math must not split the run")
        XCTAssertEqual(runs[0].mathSource, "*x* + _y_")
        XCTAssertEqual(runs[0].style, [])
    }

    func testInlineParenthesisMath_ProtectsBackticksAndBoldfromTokenization() {
        let runs = inlineRuns("\\(`code` **bold**\\)")
        XCTAssertEqual(runs.count, 1, "backticks and bold markers inside math must be literal")
        XCTAssertEqual(runs[0].mathSource, "`code` **bold**")
        XCTAssertEqual(runs[0].style, [])
    }

    // MARK: - Escaped dollar `\$` is literal, never a delimiter

    func testEscapedDollar_RendersAsLiteralNotMathDelimiter() {
        let runs = inlineRuns("\\$5")
        XCTAssertEqual(runs.count, 1, "escaped dollar must be treated as a single run")
        XCTAssertEqual(runs[0].text, "$5", "the backslash must be consumed and the dollar rendered literally")
        XCTAssertNil(runs[0].mathSource, "escaped dollar is not a math delimiter")
        XCTAssertEqual(runs[0].style, [])
    }

    func testEscapedDollar_MultipleInOneRun() {
        let runs = inlineRuns("\\$5 and \\$10")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "$5 and $10")
        XCTAssertNil(runs[0].mathSource)
    }

    // MARK: - Unclosed inline `$...$` degrades to literal

    func testUnclosedInlineDollarMath_FallsBackToLiteralDollar() {
        let runs = inlineRuns("$x^2")
        XCTAssertEqual(runs.count, 1, "no crash on unclosed delimiter")
        XCTAssertEqual(runs[0].text, "$x^2", "the opening dollar must be rendered literally when no close arrives")
        XCTAssertNil(runs[0].mathSource, "unclosed syntax must not set mathSource")
    }

    func testUnclosedInlineDollarMath_EmptyContent() {
        let runs = inlineRuns("$")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "$")
        XCTAssertNil(runs[0].mathSource)
    }

    // MARK: - Unclosed inline `\(...\)` degrades to literal

    func testUnclosedInlineParenthesisMath_FallsBackToLiteralMarker() {
        let runs = inlineRuns("\\(x^2")
        XCTAssertEqual(runs.count, 1, "no crash on unclosed delimiter")
        XCTAssertEqual(runs[0].text, "\\(x^2", "the opening marker must be rendered literally when no close arrives")
        XCTAssertNil(runs[0].mathSource)
    }

    func testUnclosedInlineParenthesisMath_EmptyContent() {
        let runs = inlineRuns("\\(")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "\\(")
        XCTAssertNil(runs[0].mathSource)
    }

    // MARK: - Two literal dollar amounts do not misparse as spanning math

    func testTwoDollarAmountsInOneSentence_NoMathMisparse() {
        let runs = inlineRuns("$5 and $10")
        XCTAssertTrue(runs.allSatisfy { $0.mathSource == nil },
            "two dollars separated by text must not create a math span — the space after the opening dollar prevents the match")
        // The exact run count and text distribution is an implementation detail; the key invariant
        // is that no run has non-nil mathSource.
    }

    func testDollarAmountWithSpaceAfter_NotMathDelimiter() {
        let runs = inlineRuns("$ 5")
        XCTAssertTrue(runs.allSatisfy { $0.mathSource == nil },
            "a dollar followed by space must not open math (Pandoc's heuristic: no space after opening delimiter)")
    }

    // MARK: - Streaming safety for inline math: no premature mathSource

    func testInlineDollarMath_StreamingSafety_NoMathSourceUntilClosed() {
        assertNoMathSourceUntilClosed(forEveryPrefixOf: "$x^2$")
    }

    func testInlineParenthesisMath_StreamingSafety_NoMathSourceUntilClosed() {
        assertNoMathSourceUntilClosed(forEveryPrefixOf: "\\(x^2\\)")
    }

    private func assertNoMathSourceUntilClosed(forEveryPrefixOf source: String, file: StaticString = #filePath, line: UInt = #line) {
        for length in 1...source.count {
            let prefix = String(source.prefix(length))
            let runs = inlineRuns(prefix)
            let allUnclosed = runs.allSatisfy { $0.mathSource == nil }
            let allClosed = runs.allSatisfy { $0.mathSource != nil }
            XCTAssertTrue(allUnclosed || (length == source.count && allClosed),
                "prefix '\(prefix)' must have either ALL runs with mathSource==nil (still streaming) or (at full length) ALL with mathSource set — never mixed",
                file: file, line: line)
        }
    }

    // MARK: - Block math: `$$...$$` single-line form

    func testBlockDollarMath_SingleLineForm_SealsAndStripsDelimiters() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$ x^2 $$\n\n")
        XCTAssertEqual(parser.frontier, 1, "a closed single-line math block must seal immediately")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }
        XCTAssertEqual(parser.sealedBlocks[0].text, "$$ x^2 $$",
            "the raw sealed block text retains the delimiters (same as codeFence marker convention)")

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "x^2", "rendered content must strip the $$ delimiters and surrounding spaces")
    }

    func testBlockDollarMath_SingleLineForm_NoSpaceInside() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$x^2$$\n\n")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "x^2")
    }

    // MARK: - Block math: `\[...\]` single-line form

    func testBlockBracketMath_SingleLineForm_SealsAndStripsDelimiters() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[ x^2 \\]\n\n")
        XCTAssertEqual(parser.frontier, 1)
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "x^2", "rendered content must strip the \\[ \\] delimiters and surrounding spaces")
    }

    func testBlockBracketMath_SingleLineForm_NoSpaceInside() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[x^2\\]\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "x^2")
    }

    // MARK: - Block math: multi-line `$$...$$ ` stays hot until closed

    func testBlockDollarMath_MultiLine_UnclosedStaysHot() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\nx^2\n")
        XCTAssertEqual(parser.frontier, 0, "an unclosed $$ block must never seal, even across a new line")
        guard case .mathBlock = parser.hotBlocksState.first?.kind else {
            return XCTFail("must classify as .mathBlock while hot")
        }
        XCTAssertEqual(parser.hotBlocksState.count, 1, "must remain one open hot block")
    }

    func testBlockDollarMath_MultiLine_SealsOnClosingLine() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\nx^2\n$$\n")
        XCTAssertEqual(parser.frontier, 1, "a closed $$ block must seal immediately on the closing line without requiring a trailing blank")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock after sealing")
        }

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "x^2", "rendered content must strip the $$ delimiters, opening-marker-only line included")
    }

    func testBlockDollarMath_MultiLine_WithLeadingAndTrailingSpace() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\na + b\n$$\n")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "a + b")
    }

    func testBlockDollarMath_MultiLine_ClosingMarkerWithWhitespace() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\nformula\n  $$  \n")
        XCTAssertEqual(parser.frontier, 1, "a closing $$ with surrounding whitespace must still close the block")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }
    }

    // MARK: - Block math: multi-line `\[...\]` stays hot until closed

    func testBlockBracketMath_MultiLine_UnclosedStaysHot() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[\nx^2\n")
        XCTAssertEqual(parser.frontier, 0, "an unclosed \\[ block must never seal")
        guard case .mathBlock = parser.hotBlocksState.first?.kind else {
            return XCTFail("must classify as .mathBlock while hot")
        }
    }

    func testBlockBracketMath_MultiLine_SealsOnClosingLine() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[\nx^2\n\\]\n")
        XCTAssertEqual(parser.frontier, 1, "a closed \\[ block must seal immediately on the \\] line")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "x^2", "rendered content must strip the \\[ \\] delimiters, opening-marker-only line included")
    }

    func testBlockBracketMath_MultiLine_ClosingMarkerWithWhitespace() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[\nformula\n  \\]  \n")
        XCTAssertEqual(parser.frontier, 1)
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }
    }

    // MARK: - Block math: no emphasis tokenization inside the body

    func testBlockDollarMath_DoesNotTokenizeEmphasisInsideBody() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\n*a* _b_ **c** __d__\n$$\n")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "*a* _b_ **c** __d__",
            "emphasis markers must be rendered literally inside a math block, never tokenized to create bold/italic")
        XCTAssertTrue(descriptor.runs.isEmpty, "math blocks must not produce TextRuns (tokenizableRuns returns [] for .mathBlock)")
    }

    func testBlockBracketMath_DoesNotTokenizeEmphasisInsideBody() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[\n`code` ~~strike~~\n\\]\n")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "`code` ~~strike~~", "backticks and strikethrough must be literal")
        XCTAssertTrue(descriptor.runs.isEmpty)
    }

    // MARK: - Block math: rendering with multiple lines of TeX

    func testBlockDollarMath_MultiLineContent_PreservesNewlines() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\nline 1\nline 2\nline 3\n$$\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "line 1\nline 2\nline 3", "newlines inside the block must be preserved")
    }

    func testBlockBracketMath_MultiLineContent_PreservesNewlines() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[\nA + B\nC + D\n\\]\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "A + B\nC + D")
    }

    // MARK: - Block math: single-line edge cases

    func testBlockMath_SingleLineOpenAndCloseOnSameLine_NoExtraWhitespace() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$E=mc^2$$\n\n")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "E=mc^2")
    }

    func testBlockBracketMath_SingleLineOpenAndCloseOnSameLine() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[E=mc^2\\]\n\n")
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("must classify as .mathBlock")
        }
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertEqual(descriptor.content, "E=mc^2")
    }

    // MARK: - Mixed content: inline math in a paragraph alongside other text

    func testInlineMath_MixedWithPlainText() {
        let runs = inlineRuns("The formula $E=mc^2$ is famous.")
        let mathRuns = runs.filter { $0.mathSource != nil }
        XCTAssertEqual(mathRuns.count, 1, "must find exactly one math run in the mixed content")
        XCTAssertEqual(mathRuns[0].mathSource, "E=mc^2")
    }

    func testInlineMath_MultipleFormulasInOneString() {
        let runs = inlineRuns("Consider $a+b$ and $c*d$ together.")
        let mathRuns = runs.filter { $0.mathSource != nil }
        XCTAssertEqual(mathRuns.count, 2, "must parse both math spans independently")
        XCTAssertEqual(mathRuns[0].mathSource, "a+b")
        XCTAssertEqual(mathRuns[1].mathSource, "c*d")
    }

    // MARK: - Interaction with other markdown syntax

    func testInlineMath_MixedWithLink() {
        let runs = inlineRuns("See [$E=mc^2$](https://example.com) and $x^2$.")
        let mathRuns = runs.filter { $0.mathSource != nil }
        XCTAssertEqual(mathRuns.count, 2, "math inside a link and standalone math should both parse")
    }

    func testBlockMath_FollowedByNormalParagraph() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\nx^2\n$$\n\n")
        parser.append("This is a paragraph.\n\n")
        XCTAssertEqual(parser.sealedBlocks.count, 2)
        guard case .mathBlock = parser.sealedBlocks[0].kind else {
            return XCTFail("block 0 must be .mathBlock")
        }
        guard case .paragraph = parser.sealedBlocks[1].kind else {
            return XCTFail("block 1 must be .paragraph")
        }
    }

    func testBlockMath_DoesNotInterfereWithCodeFence() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\ncode$$not closed\n$$\n\n")
        XCTAssertEqual(parser.frontier, 1, "a math block with text after the first $$ on the same line must still close when it reaches the next $$")
    }

    // MARK: - Edge case: math block at the end of input

    func testBlockDollarMath_UnclosedAtEndOfStream() {
        var parser = IncrementalMarkdownParser()
        parser.append("$$\nx^2")
        XCTAssertEqual(parser.frontier, 0, "an unclosed math block at EOF must stay hot")
        guard case .mathBlock = parser.hotBlocksState.first?.kind else {
            return XCTFail("must still classify as .mathBlock while hot")
        }
    }

    func testBlockBracketMath_UnclosedAtEndOfStream() {
        var parser = IncrementalMarkdownParser()
        parser.append("\\[\nE=mc^2")
        XCTAssertEqual(parser.frontier, 0)
        guard case .mathBlock = parser.hotBlocksState.first?.kind else {
            return XCTFail("must still classify as .mathBlock while hot")
        }
    }
}

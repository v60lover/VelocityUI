// IncrementalMarkdownParserInlineWindowTests.swift

import XCTest
@testable import VelocityUI

final class IncrementalMarkdownParserInlineWindowTests: XCTestCase {

    func testEveryPrefixMatchesReferenceParserAndKeepsBlockIDsStable() {
        let cases = [
            "same-line **bold** and *italic* text\n\n",
            "The regex a*b matches strings, and *emphasis* works; see also the glob pattern *.swift for files.\n\n",
            "emphasis **starts here\nand ends here**\n\n",
            "intraword a*b*c and snake_case stay literal\n\n",
            "five times 5 * 3 remains literal\n\n",
            "an escaped \\* marker remains literal\n\n",
            "code `starts here\nand ends here`\n\n",
            "[text starts\nand link](https://example.com)\n\n",
            "bare https://example.com/path?x=1 and <https://example.com> text\n\n",
            "strike ~~crossed~~ and math $x + y$ then \\(z\\) text\n\n",
            "paragraph line\n| a | b |\n|---|---|\n| x | y |\n\n",
            "Setext title\n---\n\n",
            "- list item\n  continuation\n\n> quote\n> continuation\n\n",
        ]

        for source in cases {
            var parser = IncrementalMarkdownParser()
            var prefix = ""
            var previousSealedIDs: [BlockID] = []
            var previousHotIDs: [BlockID] = []

            for character in source {
                let chunk = String(character)
                prefix += chunk
                parser.append(chunk)

                let oracle = IncrementalMarkdownParser.referenceParseTail(prefix)
                XCTAssertEqual(
                    parser.sealedBlocks + parser.hotBlocksState,
                    oracle.sealed + oracle.hot,
                    "streamed prefix disagreed with reference parser: \(prefix.debugDescription)"
                )
                XCTAssertEqual(parser.sealedBlocks.count, oracle.sealed.count)
                XCTAssertEqual(parser.sealedBlockIDs.count, oracle.sealed.count)
                XCTAssertEqual(parser.hotBlockIDs.count, oracle.hot.count)
                XCTAssertTrue(parser.sealedBlockIDs.starts(with: previousSealedIDs))
                if parser.hotBlockIDs.count >= previousHotIDs.count {
                    XCTAssertEqual(
                        Array(parser.hotBlockIDs.prefix(previousHotIDs.count)), previousHotIDs,
                        "an open block changed identity while it grew: \(prefix.debugDescription)"
                    )
                }
                previousSealedIDs = parser.sealedBlockIDs
                previousHotIDs = parser.hotBlockIDs
            }
        }
    }

    func testDirtyAsteriskTextKeepsReferenceStyleAfterPerCharacterStreamIsSealed() {
        let source = "The regex a*b matches strings, and *emphasis* works; see also the glob pattern *.swift for files.\n\n"
        var parser = IncrementalMarkdownParser()
        var prefix = ""

        for character in source {
            let chunk = String(character)
            prefix += chunk
            parser.append(chunk)
            let oracle = IncrementalMarkdownParser.referenceParseTail(prefix)
            XCTAssertEqual(
                parser.sealedBlocks + parser.hotBlocksState,
                oracle.sealed + oracle.hot,
                "streamed prefix disagreed with reference parser: \(prefix.debugDescription)"
            )
        }

        let oracle = IncrementalMarkdownParser.referenceParseTail(source)
        XCTAssertEqual(parser.sealedBlocks, oracle.sealed)
        XCTAssertEqual(parser.hotBlocksState, oracle.hot)
        XCTAssertEqual(parser.sealedBlocks.count, 1)
        XCTAssertEqual(parser.sealedBlocks[0].runs, oracle.sealed[0].runs)
    }

    func testOrdinaryInlineMarkupKeepsTierTwoTokenizationBounded() {
        let markup = " **bold** *italic* `code` "
        let source = String(repeating: "a", count: 10_000 - markup.count) + markup
        var parser = IncrementalMarkdownParser()

        for character in source {
            parser.append(String(character))
        }
        print("Tier-2 one-line tokenized bytes: \(parser.scanCounters.tier2CharsTokenizedTotal)")

        XCTAssertLessThanOrEqual(
            parser.scanCounters.tier2CharsTokenizedTotal,
            source.utf8.count * 16,
            "settled inline text should be tokenized once, with only a small unsettled suffix revisited"
        )
    }

    func testClosedMarkupAcrossLinesKeepsTierTwoWorkBounded() {
        let source = String(repeating: "plain **bold** *italic* `code`\n", count: 150)
        var parser = IncrementalMarkdownParser()
        for character in source {
            parser.append(String(character))
        }
        print("Tier-2 multiline tokenized bytes: \(parser.scanCounters.tier2CharsTokenizedTotal)")
        XCTAssertLessThanOrEqual(parser.scanCounters.tier2CharsTokenizedTotal, source.utf8.count * 30)
    }

    func testUnmatchedBacktickKeepsGrowingSuffixVisibleInTokenizationCounter() {
        var parser = IncrementalMarkdownParser()
        parser.append("settled ordinary text before code `")
        let beforeCodeGrowth = parser.scanCounters.tier2CharsTokenizedTotal

        var deltas: [Int] = []
        for chunk in ["first ", "second ", "third ", "fourth"] {
            let beforeAppend = parser.scanCounters.tier2CharsTokenizedTotal
            parser.append(chunk)
            deltas.append(parser.scanCounters.tier2CharsTokenizedTotal - beforeAppend)
        }

        XCTAssertGreaterThan(deltas.last!, deltas.first!, "an unmatched opener should grow the retokenized suffix")
        print("Tier-2 unmatched backtick deltas: \(deltas)")
        XCTAssertGreaterThan(parser.scanCounters.tier2CharsTokenizedTotal, beforeCodeGrowth)
    }
}

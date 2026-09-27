// IncrementalMarkdownParserInlineRollbackTests.swift

import XCTest
@testable import VelocityUI

final class IncrementalMarkdownParserInlineRollbackTests: XCTestCase {

    func testDelayedInlineClosersMatchReferenceAtEveryCharacterPrefix() {
        let spacerLines = String(repeating: "plain line\n", count: 19)
        let longSpacerLines = String(repeating: "lorem ipsum dolor sit amet.\n", count: 30)
        let sources = [
            "`code begins\n" + spacerLines + "` and ends\n\n",
            "**bold begins\n" + spacerLines + "** and ends\n\n",
            "[text begins\n" + spacerLines + "](https://example.com) and ends\n\n",
            "a*b without late closer\n" + spacerLines + "still open\n\n",
            "a*b with a late closer\n" + spacerLines + "* then closed\n\n",
            "plain text " + String(repeating: "] ) } > * _ ` ~ $ ", count: 24) + "\n\n",
            // R1 regression: intraword single `*` closer arriving far after its opener. The
            // closer is ambiguous the instant it lands (could still widen to `**`), then the
            // very next byte pushes it into the lookbehind window -- it must not fall through
            // the gap between those two states.
            "see a*b then\n" + longSpacerLines + "c*d end",
            "see a_b then\n" + longSpacerLines + "c_d end",
            // R2(a) regression: an already-terminated URL elsewhere in the unsettled suffix must
            // not keep the forced-freeze cap disabled forever just because an unrelated opener
            // (the lone backtick) also sits in that suffix.
            "start `lone tick https://example.com/x then\n" + String(repeating: "plain filler line\n", count: 25),
            // R2(b) regression: a rollback that (mis)matches a dangling bracket against a later,
            // unrelated link must not hold the cap off forever -- the hold has to clear once new
            // content moves past the matched closer.
            "see arr[0] here\n" + String(repeating: "plain filler line\n", count: 12) +
                "a [b](c) end\n" + String(repeating: "plain filler line\n", count: 12),
            // R4 regression: plain lines before the opener freeze through the safe-prefix path
            // (not the forced-freeze cap), so the line count carried into the forced freeze and
            // then into the rollback must already reflect those safely-frozen lines.
            String(repeating: "plain safe line\n", count: 5) +
                "`code begins\n" + spacerLines + "` and ends\n\n",
            // R4 regression: two distinct dangling emphasis openers (`*` and `_`) recorded by the
            // same forced freeze, on different lines -- the closer must resolve to its own
            // opener's line, not the other opener's.
            "before *star begins\n" + "before _underscore begins\n" + spacerLines +
                "now closed_ ends\n\n",
        ]

        for source in sources {
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
        }
    }

    func testIntrawordClosersMatchReferenceWhenSplitAcrossChunkBoundary() {
        // Same repro as above, but delivered in multi-character chunks so the closer `*`
        // lands as the last byte of one chunk and the following character starts a new one --
        // exercising the same lookbehind boundary with coarser chunking than one-char-at-a-time.
        let longSpacerLines = String(repeating: "lorem ipsum dolor sit amet.\n", count: 30)
        let source = "see a*b then\n" + longSpacerLines + "c*d end"
        guard let closerRange = source.range(of: "c*") else { XCTFail("fixture missing closer"); return }
        let splitIndex = closerRange.upperBound
        let chunks = [String(source[..<splitIndex]), String(source[splitIndex...])]

        var parser = IncrementalMarkdownParser()
        var prefix = ""
        for chunk in chunks {
            prefix += chunk
            parser.append(chunk)
        }
        let oracle = IncrementalMarkdownParser.referenceParseTail(prefix)
        XCTAssertEqual(
            parser.sealedBlocks + parser.hotBlocksState,
            oracle.sealed + oracle.hot,
            "chunked prefix disagreed with reference parser: \(prefix.debugDescription)"
        )
    }

    func testUnmatchedBacktickTokenizationRemainsBoundedAfterForcedFreeze() {
        let source = "`" + String(repeating: "x", count: 10_000)
        var parser = IncrementalMarkdownParser()
        var maxLateTokenizedBytes = 0
        for (index, character) in source.enumerated() {
            let before = parser.scanCounters.tier2CharsTokenizedTotal
            parser.append(String(character))
            if index >= 1_000 {
                maxLateTokenizedBytes = max(
                    maxLateTokenizedBytes,
                    parser.scanCounters.tier2CharsTokenizedTotal - before
                )
            }
        }

        XCTAssertLessThanOrEqual(maxLateTokenizedBytes, 32)
        XCTAssertLessThanOrEqual(
            parser.scanCounters.tier2CharsTokenizedTotal,
            source.utf8.count * 20,
            "forced checkpoints should prevent an unmatched opener from repeatedly tokenizing the full prefix"
        )
    }

    func testTerminatedURLDoesNotDisableForcedFreezeCapForever() {
        // R2(a): a lone unclosed backtick keeps `unsettled` growing, but the bare URL that
        // follows it is already terminated by whitespace. `hasGrowingURL` must stop treating it
        // as still-growing so the forced-freeze cap can keep firing.
        let filler = String(repeating: "plain filler line without markers here\n", count: 200)
        let source = "start `lone tick https://example.com/x then\n" + filler
        var parser = IncrementalMarkdownParser()
        var deltas: [Int] = []
        let characters = Array(source)
        for (index, character) in characters.enumerated() {
            let before = parser.scanCounters.tier2CharsTokenizedTotal
            parser.append(String(character))
            if index >= characters.count / 2 {
                deltas.append(parser.scanCounters.tier2CharsTokenizedTotal - before)
            }
        }

        let maxLateDelta = deltas.max() ?? 0
        print("Tier-2 terminated-URL max late delta: \(maxLateDelta)")
        XCTAssertLessThanOrEqual(maxLateDelta, 64, "a settled URL elsewhere must not keep the cap disabled")
    }

    func testUnresolvedBracketRollbackHoldClearsAfterOneAppend() {
        // R2(b): once a rollback fires against a dangling `[` opener, the hold that keeps the
        // forced-freeze cap off must not stay set forever just because `protectedEnd` is
        // permanently `.blocked` at that same bracket -- it has to clear within a bounded number
        // of bytes. A small amount of filler before the rollback event and a long tail after it
        // isolates the one-time catch-up re-freeze (legitimate, happens once) from steady state
        // (must stay bounded) -- mirrors how testUnmatchedBacktickTokenizationRemainsBounded...
        // skips the initial catch-up window with `index >= 1_000`.
        let preFiller = String(repeating: "plain filler line without markers here\n", count: 5)
        let postFiller = String(repeating: "plain filler line without markers here\n", count: 300)
        let source = "see arr[0] here\n" + preFiller + "a [b](c) end\n" + postFiller
        var parser = IncrementalMarkdownParser()
        var deltas: [Int] = []
        let characters = Array(source)
        let steadyStateStart = characters.count - (postFiller.count / 2)
        for (index, character) in characters.enumerated() {
            let before = parser.scanCounters.tier2CharsTokenizedTotal
            parser.append(String(character))
            if index >= steadyStateStart {
                deltas.append(parser.scanCounters.tier2CharsTokenizedTotal - before)
            }
        }

        let maxSteadyStateDelta = deltas.max() ?? 0
        print("Tier-2 bracket-rollback-hold max steady-state delta: \(maxSteadyStateDelta)")
        print("Inline rollback count: \(parser.inlineRollbackCount)")
        XCTAssertLessThanOrEqual(
            maxSteadyStateDelta, 64, "the rollback hold must not disable the cap forever"
        )
        XCTAssertEqual(
            parser.inlineRollbackCount, 1,
            "the bounded fallback clear must not itself trigger a second rollback loop"
        )
    }

    func testLateBacktickClosureReportsRollbackAndExactInvalidatedLines() {
        let source = "`code begins\n" + String(repeating: "plain line\n", count: 19) + "` closes here"
        var parser = IncrementalMarkdownParser()

        for character in source {
            parser.append(String(character))
        }

        XCTAssertEqual(parser.inlineRollbackCount, 1)
        XCTAssertEqual(parser.lastInvalidatedInlineLineRange, 0..<21)
    }

    func testRollbackRangeStartsAtActualOpenerLine() {
        let source = "first line\n`code begins\n" +
            String(repeating: "plain line\n", count: 19) + "` closes here"
        var parser = IncrementalMarkdownParser()
        for character in source { parser.append(String(character)) }

        XCTAssertEqual(parser.inlineRollbackCount, 1)
        XCTAssertEqual(parser.lastInvalidatedInlineLineRange, 1..<22)
    }

    func testRollbackLineRangeStaysCorrectAfterSafePrefixFreezesPrecedeForcedFreeze() {
        // R4 regression: five plain lines settle through the safe-prefix path (not the cap)
        // before the unclosed backtick starts. The forced freeze and the eventual rollback must
        // both use a line count that already accounts for those safely-frozen lines.
        let plainPrefix = String(repeating: "plain safe line\n", count: 5)
        let source = plainPrefix + "`code begins\n" +
            String(repeating: "plain line\n", count: 19) + "` closes here"
        var parser = IncrementalMarkdownParser()
        for character in source { parser.append(String(character)) }

        XCTAssertEqual(parser.inlineRollbackCount, 1)
        XCTAssertEqual(parser.lastInvalidatedInlineLineRange, 5..<26)
    }

    func testDanglingEmphasisOpenersOnDifferentLinesResolveToTheirOwnLine() {
        // R4 regression: `*` (line 0) and `_` (line 1) both dangle from the same forced freeze.
        // A closer that only matches `_` must report line 1, not line 0 or some other line
        // produced by mis-attributing an opener's position during the single-pass line scan.
        let source = "before *star begins\n" + "before _underscore begins\n" +
            String(repeating: "plain line\n", count: 19) + "now closed_ ends"
        var parser = IncrementalMarkdownParser()
        for character in source { parser.append(String(character)) }

        XCTAssertEqual(parser.inlineRollbackCount, 1)
        XCTAssertEqual(parser.lastInvalidatedInlineLineRange?.lowerBound, 1)
    }

    func testNonmatchingClosersDoNotCauseRepeatedRollback() {
        let source = "``open " + String(repeating: "x` ", count: 3_000)
        var parser = IncrementalMarkdownParser()
        for character in source { parser.append(String(character)) }

        XCTAssertEqual(parser.inlineRollbackCount, 0)
        XCTAssertLessThanOrEqual(parser.scanCounters.tier2CharsTokenizedTotal, source.utf8.count * 20)
    }

    func testLongProtectedConstructsStayEqualToFullParse() {
        let sources = [
            "visit https://example.com/" + String(repeating: "a", count: 180) + " done",
            "<https://example.com/" + String(repeating: "a", count: 180) + "> done",
            "$" + String(repeating: "x", count: 180) + "$ done",
            "~~" + String(repeating: "x", count: 180) + "~~ done",
        ]
        for source in sources {
            var parser = IncrementalMarkdownParser()
            var prefix = ""
            for character in source {
                prefix.append(character)
                parser.append(String(character))
                let oracle = IncrementalMarkdownParser.referenceParseTail(prefix)
                if parser.sealedBlocks + parser.hotBlocksState != oracle.sealed + oracle.hot {
                    XCTFail("streamed prefix disagreed: \(prefix.debugDescription)")
                    break
                }
            }
        }
    }
}

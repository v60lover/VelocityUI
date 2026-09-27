// StreamingMarkdownTextHandoffTests.swift

import XCTest
@testable import VelocityUI

final class StreamingMarkdownTextHandoffTests: XCTestCase {

    /// R3 finding #1: `OpenTextHandoff.bytesCopied` used to be a hardcoded `{ 0 }`, so it could
    /// never catch a regression. It must verify the three slices are truly contiguous (one
    /// buffer, no gaps) and only then report zero -- otherwise it reports the real byte count.
    func testBytesCopied_ReportsZeroOnlyWhenSlicesAreTrulyContiguous() {
        let base = "hello world this is one buffer long enough to avoid small-string storage"
        let cut1 = base.index(base.startIndex, offsetBy: 5)
        let cut2 = base.index(base.startIndex, offsetBy: 11)
        let frozen = base[base.startIndex..<cut1]
        let unsettled = base[cut1..<cut2]
        let tail = base[cut2...]

        let contiguous = IncrementalMarkdownParser.OpenTextHandoff(
            frozen: frozen, unsettled: unsettled, tail: tail, invalidatedLines: nil
        )
        XCTAssertEqual(contiguous.bytesCopied, 0, "genuinely adjacent slices of one buffer copy nothing")

        let otherBuffer = "a completely different buffer that is unrelated to the first one entirely"
        let disjoint = IncrementalMarkdownParser.OpenTextHandoff(
            frozen: frozen, unsettled: Substring(otherBuffer), tail: tail, invalidatedLines: nil
        )
        XCTAssertGreaterThan(
            disjoint.bytesCopied, 0,
            "non-contiguous slices must be reported as copied bytes, not silently zeroed out"
        )
    }

    /// R3 finding #2 regression: `parsedAtRenderBoundary()` used to call `flattenAtRenderBoundary()`,
    /// rejoining frozen+unsettled+tail into a brand-new String even though `parsed.text` already IS
    /// that exact content -- an O(open-block-size) copy per render read that didn't exist before
    /// `OpenTextHandoff` was introduced. Confirms the fix over a >10k-char open paragraph.
    func testParsedAtRenderBoundary_NeverCopiesAlreadyFlatBlockText() {
        var parser = IncrementalMarkdownParser()
        let longLine = String(repeating: "word ", count: 2_500) // > 10k chars, one open paragraph
        var sampleIndex = 0
        for character in longLine {
            parser.append(String(character))
            sampleIndex += 1
            guard sampleIndex % 200 == 0 else { continue }
            guard let openBlock = parser.renderableBlocks.last, !openBlock.isSealed else { continue }
            let (_, bytesCopied) = openBlock.parsedAtRenderBoundary()
            XCTAssertEqual(bytesCopied, 0, "parsedAtRenderBoundary must not re-copy already-flat block text")
        }
    }

    /// The handoff's construction (slicing frozen/unsettled/tail out of the joined block text)
    /// must stay a genuine zero-copy operation no matter how large the open block grows -- this is
    /// what makes `_handoffBytesCopiedTotal` a meaningful signal instead of a tautology.
    @MainActor
    func testStreamingController_HandoffBytesCopiedStaysZeroOverLongParagraph() {
        let controller = StreamingMarkdownController()
        let longLine = String(repeating: "lorem ipsum dolor sit amet ", count: 450) // > 10k chars
        for character in longLine {
            controller.append(String(character))
            _ = controller.renderNodes
        }
        XCTAssertEqual(
            controller._handoffBytesCopiedTotal, 0,
            "OpenTextHandoff construction must never copy -- it only slices the already-joined block text"
        )
    }

    /// Output correctness sanity check alongside the fix: a long, still-open multi-line paragraph
    /// must keep agreeing with the from-scratch reference parser at sampled prefixes.
    func testLongMultilineParagraph_MatchesReferenceParseTailAtSampledPrefixes() {
        var parser = IncrementalMarkdownParser()
        var prefix = ""
        let source = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 300) // > 10k chars
        var index = 0
        for character in source {
            let chunk = String(character)
            prefix += chunk
            parser.append(chunk)
            index += 1
            guard index % 500 == 0 else { continue }
            let oracle = IncrementalMarkdownParser.referenceParseTail(prefix)
            XCTAssertEqual(
                parser.sealedBlocks + parser.hotBlocksState,
                oracle.sealed + oracle.hot,
                "streamed prefix disagreed with reference parser at \(index) characters"
            )
        }
    }
}

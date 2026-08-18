// StreamDatasetTests.swift

import XCTest
import VelocityUI
@testable import BenchmarkHost

final class StreamDatasetTests: XCTestCase {

    // MARK: - tokens(seed:codeLineCount:)

    func testTokensAreDeterministicForSameSeed() {
        XCTAssertEqual(StreamDataset.tokens(seed: 42), StreamDataset.tokens(seed: 42))
    }

    func testDifferentSeedsProduceDifferentStreams() {
        XCTAssertNotEqual(StreamDataset.tokens(seed: 1), StreamDataset.tokens(seed: 2))
    }

    func testConcatenatedStreamContainsOpenAndCloseFenceMarkers() {
        let joined = StreamDataset.tokens(seed: 0, codeLineCount: 10).joined()
        XCTAssertTrue(joined.contains("```swift\n"), "must contain an opening fence")
        XCTAssertTrue(joined.hasSuffix("```\n\n") || joined.contains("```\n\n"), "must contain a closing fence")
    }

    func testCodeLineCountControlsHowLongTheFenceStaysOpen() {
        var parser = IncrementalMarkdownParser()
        for token in StreamDataset.tokens(seed: 0, codeLineCount: 5) {
            parser.append(token)
        }
        // Everything must have sealed by the end (the stream ends on a blank line).
        XCTAssertEqual(parser.frontier, parser.blockList(itemID: 0, width: 300).count,
            "the full canned stream must end with everything sealed, nothing left hot")
    }

    func testStreamProducesAtLeastFiveSealedBlocks() {
        // heading, paragraph, paragraph, code fence, closing paragraph.
        var parser = IncrementalMarkdownParser()
        for token in StreamDataset.tokens(seed: 0, codeLineCount: 5) {
            parser.append(token)
        }
        XCTAssertGreaterThanOrEqual(parser.frontier, 5)
    }

    // MARK: - interleavedRenderNodes(for:)

    func testNoInterleavedNodesBeforeAnchorBlocksSeal() {
        var parser = IncrementalMarkdownParser()
        parser.append("Hello")
        let nodes = StreamDataset.interleavedRenderNodes(for: parser)
        XCTAssertEqual(nodes.count, parser.renderNodes.count,
            "no image/rule should be inserted before their anchor blocks have sealed")
    }

    func testImageInsertedExactlyOnceOnceAnchorBlockSeals() {
        var parser = IncrementalMarkdownParser()
        // Seal three blocks (heading + 2 paragraphs) so frontier > imageAfterBlockIndex (2).
        parser.append("Title\n===\n\n")
        parser.append("First paragraph.\n\n")
        parser.append("Second paragraph.\n\n")
        XCTAssertGreaterThan(parser.frontier, StreamDataset.imageAfterBlockIndex,
            "precondition: three blocks must have sealed")

        let nodes = StreamDataset.interleavedRenderNodes(for: parser)
        let imageCount = nodes.filter { $0 is AsyncImageNode }.count
        XCTAssertEqual(imageCount, 1, "exactly one interleaved AsyncImageNode once its anchor block sealed")

        // Growing further must not insert a second one.
        parser.append("more text")
        let nodesAfter = StreamDataset.interleavedRenderNodes(for: parser)
        XCTAssertEqual(nodesAfter.filter { $0 is AsyncImageNode }.count, 1,
            "the interleaved image must not be re-inserted on later renders")
    }

    // MARK: - includeInterleavedBlocks: false (--stream-text-only)

    func testTextOnlyModeNeverInsertsImageOrRuleRegardlessOfFrontier() {
        var parser = IncrementalMarkdownParser()
        for token in StreamDataset.tokens(seed: 0, codeLineCount: 5) {
            parser.append(token)
        }
        let nodes = StreamDataset.interleavedRenderNodes(for: parser, includeInterleavedBlocks: false)
        XCTAssertEqual(nodes.count, parser.renderNodes.count)
        XCTAssertFalse(nodes.contains { $0 is AsyncImageNode })
        XCTAssertFalse(nodes.contains { $0 is SpacerNode })
    }
}

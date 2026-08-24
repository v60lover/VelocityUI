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

    func testCodeLineCountProducesOneDeterministicChunkPerHotLine() {
        let lineCount = 17
        let stream = StreamDataset.tokens(seed: 42, codeLineCount: lineCount)
        let codeLines = stream.filter { $0.hasPrefix("let value") }

        XCTAssertEqual(codeLines.count, lineCount,
            "the benchmark must keep the code fence hot for every requested line")
        XCTAssertTrue(stream.contains("```swift\n"), "the stream must open the code fence")
        XCTAssertTrue(stream.contains("```\n"), "the stream must close the code fence")
    }

    func testStreamProducesAtLeastFiveSealedBlocks() {
        // heading, paragraph, paragraph, code fence, closing paragraph.
        var parser = IncrementalMarkdownParser()
        for token in StreamDataset.tokens(seed: 0, codeLineCount: 5) {
            parser.append(token)
        }
        XCTAssertGreaterThanOrEqual(parser.frontier, 5)
    }

    // MARK: - interleavedRenderNodes(textNodes:frontier:)

    func testNoInterleavedNodesBeforeAnchorBlocksSeal() {
        var parser = IncrementalMarkdownParser()
        parser.append("Hello")
        let nodes = StreamDataset.interleavedRenderNodes(textNodes: parser.renderNodes, frontier: parser.frontier)
        XCTAssertEqual(nodes.count, parser.renderNodes.count,
            "no image/rule should be inserted before their anchor blocks have sealed")
    }

    func testOddAnchorImagesAppearOnlyAfterTheirBlocksSealAndKeepStableUniqueIDs() {
        var parser = IncrementalMarkdownParser()
        parser.append("Block 0\n\nBlock 1")
        XCTAssertEqual(parser.frontier, 1, "precondition: odd block 1 must still be hot")
        XCTAssertFalse(
            StreamDataset.interleavedRenderNodes(textNodes: parser.renderNodes, frontier: parser.frontier)
                .contains { $0 is RenderIDModifierNode },
            "an image may not appear before its odd anchor seals")

        parser.append("\n\nBlock 2\n\nBlock 3\n\nHot")
        XCTAssertEqual(parser.frontier, 4, "precondition: blocks 0...3 must be sealed and block 4 hot")

        let nodes = StreamDataset.interleavedRenderNodes(textNodes: parser.renderNodes, frontier: parser.frontier)
        let imageIDs = nodes.compactMap { ($0 as? RenderIDModifierNode)?.blockID.rawValue as? String }
            .filter { $0.hasPrefix("stream-image-after-") }
        XCTAssertEqual(imageIDs.count, 2, "only odd sealed anchors 1 and 3 may emit images")
        XCTAssertEqual(Set(imageIDs).count, imageIDs.count, "each generated image must have a unique stable render identity")

        parser.append("more text")
        let nodesAfter = StreamDataset.interleavedRenderNodes(textNodes: parser.renderNodes, frontier: parser.frontier)
        let imageIDsAfter = nodesAfter.compactMap { ($0 as? RenderIDModifierNode)?.blockID.rawValue as? String }
            .filter { $0.hasPrefix("stream-image-after-") }
        XCTAssertEqual(imageIDsAfter, imageIDs, "hot-text growth must not replace or duplicate interleaved images")
    }

    /// VelocityUI-8g6l: the signature takes `textNodes`/`frontier` directly, not a parser or
    /// controller — pin that it works from hand-built nodes with no live parser behind them, so
    /// a caller deriving `textNodes` from a cached `StreamingMarkdownController` still gets
    /// correct interleaving.
    func testInterleavedRenderNodesWorksFromHandBuiltNodesWithNoParserInvolved() {
        // Indices 0...3 are excluded from image insertion by design (see the `![0, 1, 2, 3]`
        // guard in interleavedRenderNodes), so this fixture goes to index 5 to land on an
        // eligible odd sealed anchor.
        let handBuiltNodes: [any RenderNode] = (0...5).map { i in
            TextNode("block \(i)", blockID: BlockID(i), blockLifecycle: .sealed)
        }
        let nodes = StreamDataset.interleavedRenderNodes(textNodes: handBuiltNodes, frontier: 6)
        let imageIDs = nodes.compactMap { ($0 as? RenderIDModifierNode)?.blockID.rawValue as? String }
            .filter { $0.hasPrefix("stream-image-after-") }
        XCTAssertEqual(imageIDs.count, 1, "odd sealed anchor 5 (with frontier 6) must emit exactly one image")
    }

    // MARK: - includeInterleavedBlocks: false (--stream-text-only)

    func testTextOnlyModeNeverInsertsImageOrRuleRegardlessOfFrontier() {
        var parser = IncrementalMarkdownParser()
        for token in StreamDataset.tokens(seed: 0, codeLineCount: 5) {
            parser.append(token)
        }
        let nodes = StreamDataset.interleavedRenderNodes(textNodes: parser.renderNodes, frontier: parser.frontier, includeInterleavedBlocks: false)
        XCTAssertEqual(nodes.count, parser.renderNodes.count)
        XCTAssertFalse(nodes.contains { $0 is AsyncImageNode })
        XCTAssertFalse(nodes.contains { $0 is SpacerNode })
    }
}

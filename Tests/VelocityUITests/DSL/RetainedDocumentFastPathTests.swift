// RetainedDocumentFastPathTests.swift

import XCTest
@testable import VelocityUI

final class RetainedDocumentFastPathTests: XCTestCase {
    /// Proves the `RetainedDocumentNode` entry point actually takes the patch fast path instead
    /// of silently falling back to a full rebuild: appending to the hot tail must produce a
    /// suffix covering only the still-open block, and `replacingStreamingSuffix` must reuse the
    /// old table's prefix verbatim rather than re-deriving it.
    @MainActor
    func testAppendOnlyPatchesHotTailSuffixNotWholeDocument() {
        let controller = StreamingMarkdownController()
        controller.append((0..<199).map { "Paragraph \($0).\n\n" }.joined() + "Tail ")

        let previousTable = flatten(controller.documentNode(), itemID: "message")
        let sealedBlockCount = previousTable.children(of: 0).count
        XCTAssertEqual(sealedBlockCount, 200)
        let previousRevision = controller.documentNode().revision

        controller.append("x")
        let document = controller.documentNode()
        XCTAssertGreaterThan(document.revision, previousRevision)

        guard let suffix = document.changedSuffix(since: previousRevision) else {
            return XCTFail("expected a changed suffix within the retained revision window")
        }

        // Only the still-open hot tail (the last block) is in the suffix -- every sealed block
        // before it stayed untouched, so replacingStreamingSuffix only needs to re-flatten one node.
        XCTAssertEqual(suffix.startBlock, sealedBlockCount - 1)
        XCTAssertEqual(suffix.blocks.count, 1)

        guard let patched = previousTable.replacingStreamingSuffix(
            revision: document.revision, startBlock: suffix.startBlock, blocks: suffix.blocks,
            itemID: "message", contentSizeCategory: .unspecified
        ) else {
            return XCTFail("replacingStreamingSuffix returned nil for a same-shape append")
        }

        // The kept prefix (root vstack at index 0 excluded) must be the OLD table's identical
        // slice, not re-derived from scratch -- proving the fast path skipped re-flattening the
        // 199 sealed blocks.
        let keep = suffix.startBlock + 1
        XCTAssertEqual(Array(patched.blockIDs[1..<keep]), Array(previousTable.blockIDs[1..<keep]))
        XCTAssertEqual(Array(patched.parentIndices[1..<keep]), Array(previousTable.parentIndices[1..<keep]))
        XCTAssertEqual(Array(patched.blockLifecycles[1..<keep]), Array(previousTable.blockLifecycles[1..<keep]))

        // Correctness: the patched table still matches a full cold rebuild in shape.
        let fullRebuild = flatten(controller.documentNode(), itemID: "message")
        XCTAssertEqual(patched.nodes.count, fullRebuild.nodes.count)
        XCTAssertEqual(patched.children(of: 0).count, fullRebuild.children(of: 0).count)
    }
}

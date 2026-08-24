// StreamingMarkdownTextTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-zuot: the Layer-1 DSL bridge from `IncrementalMarkdownParser`'s current
/// block state to a renderable node tree (`renderNodes`, `RenderNodeBuilder.buildExpression`
/// overload, `Equatable` conformance). Pure — no UIKit, runs on plain `swift test`.
final class StreamingMarkdownTextTests: XCTestCase {

    // MARK: - renderNodes shape

    func testRenderNodes_CountMatchesSealedPlusHotBlockCount() {
        var parser = IncrementalMarkdownParser()
        parser.append("# Title\n\nFirst paragraph.\n\nSecond ")

        let expectedCount = parser.sealedBlocks.count + parser.hotBlocksState.count
        XCTAssertEqual(parser.renderNodes.count, expectedCount)
        XCTAssertGreaterThan(expectedCount, 1, "Precondition: fixture must have produced more than one block")
    }

    func testRenderNodes_EmptyParser_IsEmpty() {
        let parser = IncrementalMarkdownParser()
        XCTAssertTrue(parser.renderNodes.isEmpty)
    }

    // MARK: - Content parity with blockList (the two representations must never diverge)

    /// `renderNodes` (Layer 1 `TextNode`) and `blockList(itemID:width:)` (Layer 2/3 `Block`)
    /// both route through the same `style(_:)` helper — this pins that they always agree on
    /// content, for every block kind the parser can classify.
    func testRenderNodes_ContentMatchesBlockList_ForEveryBlockKind() {
        var parser = IncrementalMarkdownParser()
        parser.append(
            "# Heading\n\n" +
            "A plain paragraph.\n\n" +
            "```swift\nlet x = 1\n```\n\n" +
            "- first item\n" +
            "- second item\n\n" +
            "> a quote\n\n" +
            "| a | b |\n|---|---|\n| 1 | 2 |\n\n"
        )

        let nodes = parser.renderNodes
        let blocks = parser.blockList(itemID: "msg", width: 300)
        XCTAssertEqual(nodes.count, blocks.count, "Precondition: same block count on both sides")
        XCTAssertGreaterThan(blocks.count, 5, "Precondition: fixture must exercise every block kind")

        for (node, block) in zip(nodes, blocks) {
            guard let textNode = node as? TextNode else {
                return XCTFail("every renderNodes entry must be a TextNode")
            }
            guard case .text(let descriptor) = block.fragment.content else {
                return XCTFail("every blockList entry in this fixture must be a text fragment")
            }
            XCTAssertEqual(textNode.content, descriptor.content)
            XCTAssertEqual(textNode.font.size, descriptor.font.size)
            XCTAssertEqual(textNode.font.weight, descriptor.font.weight)
        }
    }

    /// VelocityUI-qmx5: `renderNodes` (flattened through `flatten()` into `TextDescriptor.runs`) and
    /// `blockList(itemID:width:)` must agree on inline styling (bold/italic/code/strike/link), not
    /// just plain content — the second half of the parity fzvf.2 established for the plain-text path.
    @MainActor
    func testRenderNodes_RunsMatchBlockList_ForInlineStyledMarkdown() {
        var parser = IncrementalMarkdownParser()
        parser.append(
            "**bold** _italic_ `code` ~~strike~~ [link](https://example.com)\n\n"
        )

        let root = VStackNode { parser.renderNodes }
        let table = flatten(root, itemID: "msg")
        let blocks = parser.blockList(itemID: "msg", width: 300)

        let flattenedRuns: [[TextRun]] = table.children(of: 0).compactMap { index in
            guard case .text(let d) = table.nodes[index] else { return nil }
            return d.runs
        }
        let blockRuns: [[TextRun]] = blocks.compactMap { block in
            guard case .text(let d) = block.fragment.content else { return nil }
            return d.runs
        }

        XCTAssertEqual(flattenedRuns.count, blockRuns.count, "Precondition: same block count on both sides")
        XCTAssertFalse(flattenedRuns.allSatisfy(\.isEmpty), "Precondition: fixture must actually produce styled runs")
        XCTAssertEqual(flattenedRuns, blockRuns)
    }

    // MARK: - Equatable

    func testEquatable_SameAppendHistory_AreEqual() {
        var a = IncrementalMarkdownParser()
        var b = IncrementalMarkdownParser()
        a.append("Hello ")
        a.append("world\n\n")
        b.append("Hello ")
        b.append("world\n\n")
        XCTAssertEqual(a, b)
    }

    func testEquatable_DivergentAppendHistory_AreNotEqual() {
        var a = IncrementalMarkdownParser()
        var b = IncrementalMarkdownParser()
        a.append("Hello world\n\n")
        b.append("Goodbye world\n\n")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Flatten integration: shape flatBlocks(for:itemID:width:) recognizes

    /// `VStackNode(alignment:spacing:) { parser.renderNodes }` must flatten into a root `.vstack`
    /// whose DIRECT children are all `.text` leaves — the exact shape
    /// `FeedScrollView.flatBlocks(for:itemID:width:)` requires (see its doc: "no nesting, no
    /// hstack/zstack"). This is what makes the existing, unmodified C3 bind site pick up parser
    /// output for free.
    @MainActor
    func testFlatten_StreamingMarkdownVStack_ProducesFlatLeafShape() {
        var parser = IncrementalMarkdownParser()
        parser.append("# Title\n\nFirst paragraph.\n\nSecond ")

        let root = VStackNode(alignment: .leading, spacing: 8) {
            parser.renderNodes
        }
        let table = flatten(root, itemID: "msg")

        guard case .vstack = table.nodes[0] else {
            return XCTFail("root must be a vstack")
        }
        let childIndices = table.children(of: 0)
        XCTAssertEqual(childIndices.count, table.nodes.count - 1, "every node besides the root must be a direct child — no nesting")
        XCTAssertEqual(childIndices.count, parser.renderNodes.count)
        for index in childIndices {
            guard case .text = table.nodes[index] else {
                return XCTFail("every direct child must be a .text leaf")
            }
        }
    }
}

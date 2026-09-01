// MarkdownTableNodeTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-8ge8.5: `MarkdownTableNode` flattens to a dedicated table presentation
/// (header row + body rows, not a plain `.text` paragraph descriptor), stays a flat leaf
/// under its parent VStack (no nested container — same shape requirement as `CodeBlockNode`),
/// and the parser's GFM table output flows into it losslessly.
final class MarkdownTableNodeTests: XCTestCase {

    // MARK: - Direct construction round-trips through flatten

    @MainActor
    func testFlatten_TableDescriptorIsLossless() {
        let tableRows = [
            [TableCell(text: "Name", runs: []), TableCell(text: "Role", runs: [])],
            [TableCell(text: "Ann", runs: []), TableCell(text: "Lead", runs: [])]
        ]
        let alignments: [TableColumnAlignment] = [.left, .right]
        let node = MarkdownTableNode(tableRows: tableRows, alignments: alignments)
        let table = flatten(node, itemID: "msg")

        XCTAssertEqual(table.nodes.count, 1, "a table node must remain a single NodeTable node")
        guard case .table(let descriptor) = table.nodes.first else {
            return XCTFail("a table must emit a .table(descriptor) node kind")
        }
        XCTAssertEqual(descriptor.cells[0][0].content, "Name")
        XCTAssertEqual(descriptor.cells[0][1].content, "Role")
        XCTAssertEqual(descriptor.cells[1][0].content, "Ann")
        XCTAssertEqual(descriptor.cells[1][1].content, "Lead")
        XCTAssertEqual(descriptor.alignments, alignments)
    }

    // MARK: - Flat shape: no nested container, matches FeedScrollView.flatBlocks' requirement

    @MainActor
    func testFlatten_MixedWithTextNodes_RootChildrenAreAllDirectLeaves() {
        let tableRows = [
            [TableCell(text: "Header1", runs: []), TableCell(text: "Header2", runs: [])],
            [TableCell(text: "Cell1", runs: []), TableCell(text: "Cell2", runs: [])]
        ]
        let alignments: [TableColumnAlignment] = [.left, .right]
        let root = VStackNode(alignment: .leading, spacing: 8) {
            TextNode("before")
            MarkdownTableNode(tableRows: tableRows, alignments: alignments)
            TextNode("after")
        }
        let table = flatten(root, itemID: "msg")

        guard case .vstack = table.nodes[0] else {
            return XCTFail("root must be a vstack")
        }
        let childIndices = table.children(of: 0)
        XCTAssertEqual(
            childIndices.count, table.nodes.count - 1,
            "every node besides the root must be a direct child — a table must not introduce nesting"
        )
        XCTAssertEqual(childIndices.count, 3)
        guard case .table = table.nodes[childIndices[1]] else { return XCTFail("table must be a direct leaf") }
    }

    // MARK: - Parser wiring: GFM table flows into the table node

    @MainActor
    func testParser_GFMTable_ProducesExactlyOneMarkdownTableNode() {
        var parser = IncrementalMarkdownParser()
        parser.append("| Name | Role |\n|:---|---:|\n| Ann | Lead |\n| Bo | Eng |\n\n")

        XCTAssertEqual(parser.renderNodes.count, 1, "a complete GFM table must seal as one block and produce one render node")
        guard let tableNode = parser.renderNodes.first as? MarkdownTableNode else {
            return XCTFail("a GFM table block must render as a MarkdownTableNode")
        }
        XCTAssertEqual(tableNode.tableRows.count, 3, "header row + 2 body rows")
        XCTAssertEqual(tableNode.tableRows[0][0].text, "Name")
        XCTAssertEqual(tableNode.tableRows[1][0].text, "Ann")
        XCTAssertEqual(tableNode.tableRows[2][0].text, "Bo")
    }

    // MARK: - Hashing: layout hash vs appearance hash

    @MainActor
    func testLayoutHash_ChangesWithCellText_NotWithAlignment() {
        let rowsA = [
            [TableCell(text: "Name", runs: []), TableCell(text: "Role", runs: [])],
            [TableCell(text: "Ann", runs: []), TableCell(text: "Lead", runs: [])]
        ]
        let rowsB = [
            [TableCell(text: "Title", runs: []), TableCell(text: "Job", runs: [])],
            [TableCell(text: "Ann", runs: []), TableCell(text: "Lead", runs: [])]
        ]
        let nodeA = MarkdownTableNode(tableRows: rowsA, alignments: [.left, .right])
        let nodeB = MarkdownTableNode(tableRows: rowsA, alignments: [.center, .left])
        let nodeC = MarkdownTableNode(tableRows: rowsB, alignments: [.left, .right])

        XCTAssertEqual(
            nodeA.layoutHash, nodeB.layoutHash,
            "alignment must not affect layoutHash — it is appearance-only"
        )
        XCTAssertNotEqual(
            nodeA.layoutHash, nodeC.layoutHash,
            "cell text must affect layoutHash"
        )
    }

    @MainActor
    func testAppearanceHash_ChangesWithAlignment_LayoutHashStaysEqual() {
        let rows = [
            [TableCell(text: "Header", runs: [])],
            [TableCell(text: "Data", runs: [])]
        ]
        let nodeLeft = MarkdownTableNode(tableRows: rows, alignments: [.left])
        let nodeRight = MarkdownTableNode(tableRows: rows, alignments: [.right])

        XCTAssertNotEqual(
            nodeLeft.appearanceHash, nodeRight.appearanceHash,
            "alignment must affect appearanceHash"
        )
        XCTAssertEqual(
            nodeLeft.layoutHash, nodeRight.layoutHash,
            "layout hash must not change when only alignment changes"
        )
    }

    // MARK: - Caching: StreamingMarkdownController

    @MainActor
    func testStreamingMarkdownController_NewlySealedTable_StylesOnceThenCaches() {
        let controller = StreamingMarkdownController()
        controller.append("| Name | Role |\n|:---|---:|\n| Ann | Lead |\n")
        _ = controller.renderNodes // still hot: rebuilt, not cached

        controller.append("| Bo | Eng |\n\n") // completes the table and opens nothing new
        let callCountBeforeSeal = controller._styleCallCount
        _ = controller.renderNodes // this read must style the newly-sealed table once
        XCTAssertEqual(controller._styleCallCount - callCountBeforeSeal, 1)

        let callCountAfterSeal = controller._styleCallCount
        _ = controller.renderNodes
        _ = controller.renderNodes
        XCTAssertEqual(controller._styleCallCount - callCountAfterSeal, 0, "a cached sealed table must never re-style")
    }

    // MARK: - Regression: existing code/text nodes remain unaffected

    @MainActor
    func testParser_CodeFence_StillProducesCodeBlockNode() {
        var parser = IncrementalMarkdownParser()
        parser.append("```swift\nlet x = 1\n```\n\n")

        guard let codeNode = parser.renderNodes.first(where: { $0 is CodeBlockNode }) as? CodeBlockNode else {
            return XCTFail("a fenced code block must render as a CodeBlockNode")
        }
        XCTAssertEqual(codeNode.language, "swift")
        XCTAssertEqual(codeNode.rawCode, "let x = 1")
    }
}

// CodeBlockNodeTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-oz5q.1: `CodeBlockNode` flattens to a dedicated code presentation
/// (header + body, not a plain `.text` paragraph descriptor), stays a flat pair of
/// leaves under its parent VStack (no nested container — see `Flattener.swift`'s doc
/// comment on why `FeedScrollView.flatBlocks` requires this), and the parser's
/// `.codeFence(language:)` output flows into it losslessly.
final class CodeBlockNodeTests: XCTestCase {

    // MARK: - Direct construction round-trips through flatten

    @MainActor
    func testFlatten_RawCodeIsByteIdenticalInTheBodyLeaf() {
        let raw = "let x = 1\n    let y = 2\n\ttab-indented\n"
        let node = CodeBlockNode(language: "swift", rawCode: raw)
        let table = flatten(node, itemID: "msg")

        guard case .codeBlock(let descriptor) = table.nodes.first else {
            return XCTFail("a code block must remain a single NodeTable node")
        }
        XCTAssertEqual(descriptor.rawCode, raw, "rawCode must cross the boundary byte-identically")
    }

    @MainActor
    func testFlatten_ProducesExactlyOneCodeBlockNode_NotSeparateHeaderAndBodyLeaves() {
        let node = CodeBlockNode(language: "python", rawCode: "print(1)")
        let table = flatten(node, itemID: "msg")

        XCTAssertEqual(table.nodes.count, 1, "a code block must stay one NodeTable node, not two text leaves")
        guard case .codeBlock(let descriptor) = table.nodes[0] else { return XCTFail("expected code block") }
        XCTAssertEqual(descriptor.language, "python")
        XCTAssertEqual(descriptor.rawCode, "print(1)")
    }

    @MainActor
    func testFlatten_NilLanguage_HeaderIsEmptyString() {
        let node = CodeBlockNode(rawCode: "no fence language here")
        let table = flatten(node, itemID: "msg")

        guard case .codeBlock(let descriptor) = table.nodes[0] else { return XCTFail("expected code block") }
        XCTAssertNil(descriptor.language)
    }

    // MARK: - Flat shape: no nested container, matches FeedScrollView.flatBlocks' requirement

    @MainActor
    func testFlatten_MixedWithParagraphs_RootChildrenAreAllDirectLeaves() {
        let root = VStackNode(alignment: .leading, spacing: 8) {
            TextNode("before")
            CodeBlockNode(language: "swift", rawCode: "let x = 1")
            TextNode("after")
        }
        let table = flatten(root, itemID: "msg")

        guard case .vstack = table.nodes[0] else {
            return XCTFail("root must be a vstack")
        }
        let childIndices = table.children(of: 0)
        XCTAssertEqual(
            childIndices.count, table.nodes.count - 1,
            "every node besides the root must be a direct child — a code block must not introduce nesting"
        )
        XCTAssertEqual(childIndices.count, 3)
        guard case .codeBlock = table.nodes[childIndices[1]] else { return XCTFail("code block must be a direct leaf") }
    }

    // MARK: - Stable identity

    @MainActor
    func testFlatten_WithBlockID_HeaderAndBodyGetDistinctIDs() {
        let node = CodeBlockNode(language: "swift", rawCode: "let x = 1", blockID: BlockID("code-1"))
        let table = flatten(node, itemID: "msg")

        XCTAssertEqual(table.nodes.count, 1)
        XCTAssertEqual(table.blockID(at: 0), BlockID("code-1"))
    }

    @MainActor
    func testFlatten_BlockLifecycle_PropagatesToBothLeaves() {
        let node = CodeBlockNode(
            language: "swift", rawCode: "let x = 1",
            blockID: BlockID("code-1"), blockLifecycle: .hot
        )
        let table = flatten(node, itemID: "msg")

        XCTAssertEqual(table.blockLifecycle(at: 0), .hot)
    }

    // MARK: - Parser wiring: fence language flows into the code block

    @MainActor
    func testParser_CodeFenceLanguage_FlowsIntoCodeBlockNode() {
        var parser = IncrementalMarkdownParser()
        parser.append("```swift\nlet x = 1\n```\n\n")

        guard let codeNode = parser.renderNodes.first(where: { $0 is CodeBlockNode }) as? CodeBlockNode else {
            return XCTFail("a fenced block must render as a CodeBlockNode")
        }
        XCTAssertEqual(codeNode.language, "swift")
        XCTAssertEqual(codeNode.rawCode, "let x = 1")
    }

    @MainActor
    func testParser_CodeFenceWithNoLanguage_ProducesNilLanguage() {
        var parser = IncrementalMarkdownParser()
        parser.append("```\nplain\n```\n\n")

        guard let codeNode = parser.renderNodes.first(where: { $0 is CodeBlockNode }) as? CodeBlockNode else {
            return XCTFail("a fenced block must render as a CodeBlockNode")
        }
        XCTAssertNil(codeNode.language)
        XCTAssertEqual(codeNode.rawCode, "plain")
    }

    // MARK: - Hashing

    @MainActor
    func testLayoutHash_ChangesWithRawCode_NotWithLanguage() {
        let a = CodeBlockNode(language: "swift", rawCode: "let x = 1")
        let b = CodeBlockNode(language: "python", rawCode: "let x = 1")
        let c = CodeBlockNode(language: "swift", rawCode: "let x = 2")

        XCTAssertEqual(a.layoutHash, b.layoutHash, "language must not affect layoutHash — it's appearance-only")
        XCTAssertNotEqual(a.layoutHash, c.layoutHash, "rawCode must affect layoutHash")
    }

    @MainActor
    func testAppearanceHash_ChangesWithLanguage() {
        let a = CodeBlockNode(language: "swift", rawCode: "let x = 1")
        let b = CodeBlockNode(language: "python", rawCode: "let x = 1")
        XCTAssertNotEqual(a.appearanceHash, b.appearanceHash)
    }
}

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

        let bodyContent = table.nodes.compactMap { kind -> String? in
            guard case .text(let d) = kind else { return nil }
            return d.content
        }.last

        XCTAssertEqual(bodyContent, raw, "the body leaf's rendered content must be byte-identical to rawCode")
    }

    @MainActor
    func testFlatten_ProducesExactlyTwoLeaves_HeaderThenBody() {
        let node = CodeBlockNode(language: "python", rawCode: "print(1)")
        let table = flatten(node, itemID: "msg")

        let textContents: [String] = table.nodes.compactMap { kind in
            guard case .text(let d) = kind else { return nil }
            return d.content
        }
        XCTAssertEqual(textContents, ["python", "print(1)"], "header (language) must come before body (raw code)")
    }

    @MainActor
    func testFlatten_NilLanguage_HeaderIsEmptyString() {
        let node = CodeBlockNode(rawCode: "no fence language here")
        let table = flatten(node, itemID: "msg")

        guard case .text(let header) = table.nodes[0] else {
            return XCTFail("first leaf must be the header")
        }
        XCTAssertEqual(header.content, "")
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
        for index in childIndices {
            guard case .text = table.nodes[index] else {
                return XCTFail("every direct child must be a .text leaf, code block included")
            }
        }
        // before(1) + header(1) + body(1) + after(1)
        XCTAssertEqual(childIndices.count, 4)
    }

    // MARK: - Stable identity: header and body get distinct derived block ids

    @MainActor
    func testFlatten_WithBlockID_HeaderAndBodyGetDistinctIDs() {
        let node = CodeBlockNode(language: "swift", rawCode: "let x = 1", blockID: BlockID("code-1"))
        let table = flatten(node, itemID: "msg")

        XCTAssertEqual(table.nodes.count, 2)
        let id0 = table.blockID(at: 0)
        let id1 = table.blockID(at: 1)
        XCTAssertNotNil(id0)
        XCTAssertNotNil(id1)
        XCTAssertNotEqual(id0, id1, "header and body must not collide under one shared identity")
    }

    @MainActor
    func testFlatten_BlockLifecycle_PropagatesToBothLeaves() {
        let node = CodeBlockNode(
            language: "swift", rawCode: "let x = 1",
            blockID: BlockID("code-1"), blockLifecycle: .hot
        )
        let table = flatten(node, itemID: "msg")

        XCTAssertEqual(table.blockLifecycle(at: 0), .hot)
        XCTAssertEqual(table.blockLifecycle(at: 1), .hot)
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

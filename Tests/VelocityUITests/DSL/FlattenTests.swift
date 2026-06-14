// FlattenTests.swift

import XCTest
@testable import VelocityUI

final class FlattenTests: XCTestCase {

    // MARK: - Structural round-trip

    @MainActor func testFlatten_singleLeafNode() {
        let root = TextNode("hello")
        let table = flatten(root, itemID: "i")
        XCTAssertEqual(table.nodes.count, 1)
        XCTAssertEqual(table.parentIndices, [-1])
        XCTAssertEqual(table.children(of: 0), [])
        guard case .text(let d) = table.nodes[0] else { XCTFail("expected .text"); return }
        XCTAssertEqual(d.content, "hello")
    }

    @MainActor func testFlatten_vstackWithTwoChildren() {
        // VStack(0) → Image(1), Text(2)
        let root = VStackNode(spacing: 8) {
            AsyncImageNode(url: nil, aspectRatio: 1.5)
            TextNode("caption")
        }
        let table = flatten(root, itemID: "i")

        XCTAssertEqual(table.nodes.count, 3)
        XCTAssertEqual(table.parentIndices, [-1, 0, 0])
        XCTAssertEqual(table.children(of: 0), [1, 2])
        XCTAssertEqual(table.children(of: 1), [])
        XCTAssertEqual(table.children(of: 2), [])

        guard case .vstack(let vd) = table.nodes[0] else { XCTFail(); return }
        XCTAssertEqual(vd.spacing, 8)

        guard case .image(let id) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(id.aspectRatio ?? 0, 1.5, accuracy: 0.001)

        guard case .text(let td) = table.nodes[2] else { XCTFail(); return }
        XCTAssertEqual(td.content, "caption")
    }

    @MainActor func testFlatten_threeLevel_insertionOrder() {
        // VStack(0)
        //   VStack(1)  ← first child of 0
        //     Image(2)
        //     Text(3)
        //   Text(4)    ← second child of 0
        let root = VStackNode(spacing: 4) {
            VStackNode(spacing: 0) {
                AsyncImageNode(url: nil)
                TextNode("inner")
            }
            TextNode("outer")
        }
        let table = flatten(root, itemID: "x")

        XCTAssertEqual(table.nodes.count, 5)
        XCTAssertEqual(table.parentIndices, [-1, 0, 1, 1, 0])
        XCTAssertEqual(table.children(of: 0), [1, 4])
        XCTAssertEqual(table.children(of: 1), [2, 3])
        XCTAssertEqual(table.children(of: 2), [])
        XCTAssertEqual(table.children(of: 3), [])
        XCTAssertEqual(table.children(of: 4), [])
    }

    @MainActor func testFlatten_hstack_and_zstack() {
        // ZStack(0) → HStack(1) → Text(2), Text(3)
        let root = ZStackNode {
            HStackNode(spacing: 4) {
                TextNode("left")
                TextNode("right")
            }
        }
        let table = flatten(root, itemID: "z")

        XCTAssertEqual(table.nodes.count, 4)
        XCTAssertEqual(table.parentIndices, [-1, 0, 1, 1])
        XCTAssertEqual(table.children(of: 0), [1])
        XCTAssertEqual(table.children(of: 1), [2, 3])
    }

    @MainActor func testFlatten_emptyContainer() {
        // VStack with no children — tests buildChildIndex with leaf-only result
        let root = VStackNode {}
        let table = flatten(root, itemID: "e")
        XCTAssertEqual(table.nodes.count, 1)
        XCTAssertEqual(table.parentIndices, [-1])
        XCTAssertEqual(table.children(of: 0), [])
    }

    @MainActor func testFlatten_spacer_mapsMinLength() {
        let root = VStackNode {
            SpacerNode(minLength: 16)
            SpacerNode()            // nil → 0
        }
        let table = flatten(root, itemID: "s")
        guard case .spacer(let h1) = table.nodes[1] else { XCTFail(); return }
        guard case .spacer(let h2) = table.nodes[2] else { XCTFail(); return }
        XCTAssertEqual(h1, 16)
        XCTAssertEqual(h2, 0)
    }

    @MainActor func testFlatten_childOrderMatchesDSLOrder() {
        let root = VStackNode {
            for i in 0..<5 {
                TextNode("item \(i)")
            }
        }
        let table = flatten(root, itemID: "o")
        XCTAssertEqual(table.children(of: 0), [1, 2, 3, 4, 5])
        for (offset, nodeIndex) in table.children(of: 0).enumerated() {
            guard case .text(let d) = table.nodes[nodeIndex] else { XCTFail(); return }
            XCTAssertEqual(d.content, "item \(offset)")
        }
    }

    // MARK: - Descriptor mapping

    @MainActor func testFlatten_asyncImageNode_mapsAllFields() {
        let url = URL(string: "https://example.com/img.jpg")!
        let node = AsyncImageNode(url: url, aspectRatio: 1.77, contentMode: .fill).cornerRadius(8)
        let table = flatten(VStackNode { node }, itemID: "i")
        guard case .image(let d) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(d.url, url)
        XCTAssertEqual(d.aspectRatio ?? 0, 1.77, accuracy: 0.001)
        XCTAssertEqual(d.contentMode, VContentMode.fill.rawValue)
        XCTAssertEqual(d.cornerRadius, 8)
    }

    @MainActor func testFlatten_textNode_mapsAllFields() {
        let node = TextNode("abc", font: VFontDescriptor(size: 20, weight: 700),
                            color: .white, lineLimit: 3, lineBreakMode: .byTruncatingTail)
        let table = flatten(VStackNode { node }, itemID: "i")
        guard case .text(let d) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(d.content, "abc")
        XCTAssertEqual(d.font.size, 20)
        XCTAssertEqual(d.font.weight, 700)
        XCTAssertEqual(d.lineLimit, 3)
        XCTAssertEqual(d.lineBreakMode, VLineBreakMode.byTruncatingTail.rawValue)
    }

    @MainActor func testFlatten_vstackDescriptor_mapsAlignmentSpacingAndHashes() {
        let node = VStackNode(alignment: .trailing, spacing: 12) { TextNode("x") }
        let table = flatten(node, itemID: "i")
        guard case .vstack(let d) = table.nodes[0] else { XCTFail(); return }
        XCTAssertEqual(d.alignment, VHorizontalAlignment.trailing.rawValue)
        XCTAssertEqual(d.spacing, 12)
        XCTAssertEqual(d.layoutHash, node.layoutHash)
        XCTAssertEqual(d.appearanceHash, node.appearanceHash)
    }

    // MARK: - Hash propagation

    @MainActor func testFlatten_tableHashes_matchRootNode() {
        let root = VStackNode(spacing: 8) {
            AsyncImageNode(url: nil, aspectRatio: 1.0)
            TextNode("hello")
        }
        let table = flatten(root, itemID: "h")
        XCTAssertEqual(table.layoutHash, root.layoutHash)
        XCTAssertEqual(table.appearanceHash, root.appearanceHash)
    }

    @MainActor func testFlatten_textDescriptor_carriesNodeHashes() {
        let node = TextNode("abc", lineLimit: 3)
        let table = flatten(VStackNode { node }, itemID: "h")
        guard case .text(let d) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(d.layoutHash, node.layoutHash)
        XCTAssertEqual(d.appearanceHash, node.appearanceHash)
    }

    @MainActor func testFlatten_imageDescriptor_carriesNodeHashes() {
        let node = AsyncImageNode(url: nil, aspectRatio: 1.77).cornerRadius(8)
        let table = flatten(VStackNode { node }, itemID: "h")
        guard case .image(let d) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(d.layoutHash, node.layoutHash)
        XCTAssertEqual(d.appearanceHash, node.appearanceHash)
    }

    // MARK: - LayoutCache-key invariants

    @MainActor func testCacheKey_identicalTrees_equalLayoutHash() {
        // Two separately built trees with identical structure and content must hash equally.
        let makeTree = {
            VStackNode(spacing: 8) {
                AsyncImageNode(url: URL(string: "https://example.com/img.jpg"), aspectRatio: 1.5)
                TextNode("caption")
            }
        }
        let t1 = flatten(makeTree(), itemID: "a")
        let t2 = flatten(makeTree(), itemID: "b")
        XCTAssertEqual(t1.layoutHash, t2.layoutHash,
            "Same tree structure must yield equal layoutHash for LayoutCache correctness")
        XCTAssertEqual(t1.appearanceHash, t2.appearanceHash)
    }

    @MainActor func testCacheKey_colorChangeAffectsAppearanceOnly() {
        let url = URL(string: "https://example.com/img.jpg")!
        let t1 = flatten(VStackNode {
            AsyncImageNode(url: url, aspectRatio: 1.0)
            TextNode("x", color: VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1))
        }, itemID: "a")
        let t2 = flatten(VStackNode {
            AsyncImageNode(url: url, aspectRatio: 1.0)
            TextNode("x", color: VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1))
        }, itemID: "b")
        XCTAssertEqual(t1.layoutHash, t2.layoutHash,
            "Color-only change must not perturb layoutHash")
        XCTAssertNotEqual(t1.appearanceHash, t2.appearanceHash)
    }

    @MainActor func testCacheKey_differentChildOrder_differentLayoutHash() {
        let url = URL(string: "https://example.com/img.jpg")!
        let t1 = flatten(VStackNode {
            AsyncImageNode(url: url, aspectRatio: 1.0)
            TextNode("caption")
        }, itemID: "a")
        let t2 = flatten(VStackNode {
            TextNode("caption")
            AsyncImageNode(url: url, aspectRatio: 1.0)
        }, itemID: "b")
        XCTAssertNotEqual(t1.layoutHash, t2.layoutHash,
            "Different child order must yield different layoutHash")
    }

    // MARK: - Determinism

    @MainActor func testFlatten_sameTree_isDeterministic() {
        let root = VStackNode(spacing: 4) {
            AsyncImageNode(url: nil, aspectRatio: 2.0)
            TextNode("caption")
            SpacerNode(minLength: 8)
        }
        let t1 = flatten(root, itemID: "x")
        let t2 = flatten(root, itemID: "x")
        XCTAssertEqual(t1.nodes.count, t2.nodes.count)
        XCTAssertEqual(t1.parentIndices, t2.parentIndices)
        XCTAssertEqual(t1.children(of: 0), t2.children(of: 0))
        XCTAssertEqual(t1.layoutHash, t2.layoutHash)
        XCTAssertEqual(t1.appearanceHash, t2.appearanceHash)
    }

    @MainActor func testFlatten_reInstantiation_isDeterministic() {
        // Two separately-instantiated identical trees must produce equal hashes.
        // This is the real LayoutCache-key contract: two callers building the same cell
        // type independently must get a cache hit, not a miss.
        func makeTable() -> NodeTable {
            flatten(VStackNode(spacing: 8) {
                AsyncImageNode(url: URL(string: "https://example.com/img.jpg"), aspectRatio: 1.77)
                TextNode("caption", lineLimit: 2)
            }, itemID: "item-1")
        }
        let t1 = makeTable()
        let t2 = makeTable()
        XCTAssertEqual(t1.layoutHash, t2.layoutHash)
        XCTAssertEqual(t1.appearanceHash, t2.appearanceHash)
        XCTAssertEqual(t1.parentIndices, t2.parentIndices)
    }

    // MARK: - itemID / AnyHashable

    @MainActor func testFlatten_itemID_isBoxedAndEquatable() {
        let t1 = flatten(TextNode("x"), itemID: 42)
        let t2 = flatten(TextNode("x"), itemID: 42)
        XCTAssertEqual(t1.itemID, AnyHashable(42))
        XCTAssertEqual(t1.itemID, t2.itemID, "Same itemID value must be equal after boxing")
        XCTAssertNotEqual(flatten(TextNode("x"), itemID: 1).itemID,
                          flatten(TextNode("x"), itemID: 2).itemID)
    }

    @MainActor func testFlatten_itemID_participatesInSetMembership() {
        let t1 = flatten(TextNode("x"), itemID: "abc")
        let t2 = flatten(TextNode("x"), itemID: "abc")
        let t3 = flatten(TextNode("x"), itemID: "xyz")
        let ids: Set<AnyHashable> = [t1.itemID, t2.itemID, t3.itemID]
        XCTAssertEqual(ids.count, 2, "Equal itemIDs must deduplicate in a Set")
    }

    // MARK: - children(of:) bounds safety

    @MainActor func testChildren_outOfBounds_returnsEmpty() {
        let table = NodeTable(
            itemID: "t",
            nodes: [.spacer(0)],
            parentIndices: [-1],
            layoutHash: 0, appearanceHash: 0
        )
        XCTAssertEqual(table.children(of: 5), [])
        XCTAssertEqual(table.children(of: -1), [])
    }
}

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

    @MainActor func testRenderID_PropagatesThroughNestedModifiers() {
        let root = VStackNode {
            TextNode("text").renderID("text").frame(width: 100)
            AsyncImageNode(url: nil).frame(height: 30).renderID("image")
            SpacerNode().renderID("geometry")
        }
        let table = flatten(root, itemID: "item")

        XCTAssertEqual(table.blockID(at: 1), BlockID("text"))
        XCTAssertEqual(table.blockID(at: 2), BlockID("image"))
        XCTAssertEqual(table.blockID(at: 3), BlockID("geometry"))
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

    // MARK: - Placeholder (VelocityUI-1su.3)

    @MainActor func testFlatten_asyncImageNode_mapsPlaceholderFields() {
        let thumb = Data([0xFF, 0xD8, 0xFF])
        let node = AsyncImageNode(url: nil, aspectRatio: 1.0)
            .placeholder(thumbnail: thumb)
            .placeholder(blurHash: "L6PZfSi_.AyE_3t7t7R**0o#DgR4")
        let table = flatten(VStackNode { node }, itemID: "i")
        guard case .image(let d) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(d.thumbnailData, thumb)
        XCTAssertEqual(d.blurHash, "L6PZfSi_.AyE_3t7t7R**0o#DgR4")
    }

    @MainActor func testPlaceholder_doesNotAffectLayoutHash() {
        let base = AsyncImageNode(url: nil, aspectRatio: 1.0)
        let withPlaceholder = base.placeholder(blurHash: "L6PZfSi_.AyE_3t7t7R**0o#DgR4")
        XCTAssertEqual(base.layoutHash, withPlaceholder.layoutHash,
            "placeholder data is appearance-only — must not affect layoutHash")
    }

    @MainActor func testPlaceholder_changesAppearanceHash() {
        let base = AsyncImageNode(url: nil, aspectRatio: 1.0)
        let withPlaceholder = base.placeholder(blurHash: "L6PZfSi_.AyE_3t7t7R**0o#DgR4")
        XCTAssertNotEqual(base.appearanceHash, withPlaceholder.appearanceHash,
            "setting a placeholder must change appearanceHash so classify() re-commits it")
    }

    @MainActor func testPlaceholder_thumbnailTakesPrecedenceOverBlurHashInDescriptor() {
        let thumb = Data([0xFF, 0xD8, 0xFF])
        let node = AsyncImageNode(url: nil, aspectRatio: 1.0)
            .placeholder(blurHash: "L6PZfSi_.AyE_3t7t7R**0o#DgR4")
            .placeholder(thumbnail: thumb)
        let table = flatten(VStackNode { node }, itemID: "i")
        guard case .image(let d) = table.nodes[1] else { XCTFail(); return }
        // Both are carried through — precedence is applied at decode time (RenderCell), not here.
        XCTAssertEqual(d.thumbnailData, thumb)
        XCTAssertEqual(d.blurHash, "L6PZfSi_.AyE_3t7t7R**0o#DgR4")
    }

    @MainActor func testFlatten_asyncImageNode_mapsCustomPlaceholderPayload() {
        let node = AsyncImageNode(url: nil, aspectRatio: 1.0).placeholder(custom: "dominant-color:#ff0000")
        let table = flatten(VStackNode { node }, itemID: "i")
        guard case .image(let d) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(d.customPlaceholderPayload, AnyPlaceholderPayload("dominant-color:#ff0000"))
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

    /// ezo.2.3: the attribute catalog (family, traits, underline, strikethrough, kerning,
    /// lineSpacing) must round-trip from TextNode through flatten() into TextDescriptor.
    @MainActor func testFlatten_textNode_mapsAttributeCatalog() {
        let node = TextNode(
            "abc",
            font: VFontDescriptor(size: 20, weight: 0).family("Georgia").italic,
            underlineStyle: .single,
            strikethroughStyle: .double,
            kerning: 2.5,
            lineSpacing: 4
        )
        let table = flatten(VStackNode { node }, itemID: "i")
        guard case .text(let d) = table.nodes[1] else { XCTFail(); return }
        XCTAssertEqual(d.font.family, "Georgia")
        XCTAssertEqual(d.font.traits, .italic)
        XCTAssertEqual(d.underlineStyle, VUnderlineStyle.single.rawValue)
        XCTAssertEqual(d.strikethroughStyle, VUnderlineStyle.double.rawValue)
        XCTAssertEqual(d.kerning, 2.5)
        XCTAssertEqual(d.lineSpacing, 4)
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

    // MARK: - ezo.2.3: attribute-catalog hash classification

    /// family, traits, kerning, and lineSpacing all affect glyph metrics or line wrapping —
    /// they must perturb layoutHash and must NOT perturb appearanceHash.
    @MainActor func testCacheKey_geometryAffectingAttributes_perturbLayoutHashOnly() {
        let base = TextNode("caption")
        let variants: [(String, TextNode)] = [
            ("family", TextNode("caption", font: VFontDescriptor(size: 17, weight: 0).family("Georgia"))),
            ("italic", TextNode("caption", font: VFontDescriptor(size: 17, weight: 0).italic)),
            ("kerning", TextNode("caption", kerning: 2)),
            ("lineSpacing", TextNode("caption", lineSpacing: 4))
        ]
        for (name, variant) in variants {
            XCTAssertNotEqual(base.layoutHash, variant.layoutHash,
                "\(name): must perturb layoutHash — it affects glyph metrics or line wrapping")
            XCTAssertEqual(base.appearanceHash, variant.appearanceHash,
                "\(name): must not perturb appearanceHash — it never changes rendered pixels' position")
        }
    }

    /// underline/strikethrough are decoration ink drawn alongside glyphs — they must perturb
    /// appearanceHash and must NOT perturb layoutHash.
    @MainActor func testCacheKey_underlineStrikethrough_perturbAppearanceHashOnly() {
        let base = TextNode("caption")
        let variants: [(String, TextNode)] = [
            ("underline", TextNode("caption", underlineStyle: .single)),
            ("strikethrough", TextNode("caption", strikethroughStyle: .single))
        ]
        for (name, variant) in variants {
            XCTAssertEqual(base.layoutHash, variant.layoutHash,
                "\(name): must not perturb layoutHash — decoration ink doesn't move glyph advances")
            XCTAssertNotEqual(base.appearanceHash, variant.appearanceHash,
                "\(name): must perturb appearanceHash — it changes rendered pixels")
        }
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

    // MARK: - .frame() folding (VelocityUI-dv7)

    @MainActor func testFlatten_plainRow_framesIsNil() {
        // No .frame() anywhere in the tree — frames must stay nil, not an all-.unspecified array.
        let root = VStackNode {
            AsyncImageNode(url: nil, aspectRatio: 1.0)
            TextNode("caption")
        }
        let table = flatten(root, itemID: "plain")
        XCTAssertNil(table.frames, "unframed tree must not allocate a [FrameSpec] array")
        // frame(at:) must still be safe and return .unspecified for every index.
        for i in 0..<table.nodes.count {
            XCTAssertEqual(table.frame(at: i), .unspecified)
        }
    }

    @MainActor func testFlatten_framedImageLeaf_recordsSpecAtWrappedIndex() {
        // VStack(0) → Image(1, framed 100x200)
        let root = VStackNode {
            AsyncImageNode(url: nil, aspectRatio: 1.0).frame(width: 100, height: 200)
        }
        let table = flatten(root, itemID: "framed-leaf")

        XCTAssertNotNil(table.frames)
        // FrameModifierNode must be fully transparent: still exactly 2 nodes (vstack + image),
        // no extra NodeKind and no extra parentIndices entry for the wrapper.
        XCTAssertEqual(table.nodes.count, 2)
        XCTAssertEqual(table.parentIndices, [-1, 0])
        guard case .image = table.nodes[1] else { XCTFail("expected .image at wrapped index"); return }

        let spec = table.frame(at: 1)
        XCTAssertEqual(spec.width, 100)
        XCTAssertEqual(spec.height, 200)
        // The vstack (unframed) index reports .unspecified.
        XCTAssertEqual(table.frame(at: 0), .unspecified)
    }

    @MainActor func testFlatten_framedContainer_recordsSpecAtContainerIndex() {
        // VStack(0, framed height:200) → Text(1)
        let root = VStackNode {
            TextNode("x")
        }.frame(height: 200)
        let table = flatten(root, itemID: "framed-container")

        XCTAssertEqual(table.nodes.count, 2)
        XCTAssertEqual(table.parentIndices, [-1, 0])
        guard case .vstack = table.nodes[0] else { XCTFail("expected .vstack at wrapped index"); return }

        let spec = table.frame(at: 0)
        XCTAssertNil(spec.width)
        XCTAssertEqual(spec.height, 200)
        XCTAssertEqual(table.frame(at: 1), .unspecified)
    }

    @MainActor func testFlatten_nestedFrameFrame_mergesToOneEntry_innerDimensionWins() {
        // .frame(width:100).frame(width:200) — inner (closer to content) frame wins per dimension.
        let root = VStackNode {
            TextNode("x").frame(width: 100).frame(width: 200)
        }
        let table = flatten(root, itemID: "nested-frame")

        // Still exactly 2 nodes: neither FrameModifierNode contributes a NodeKind entry.
        XCTAssertEqual(table.nodes.count, 2)
        XCTAssertEqual(table.parentIndices, [-1, 0])

        let spec = table.frame(at: 1)
        XCTAssertEqual(spec.width, 100, "inner (closer-to-content) frame's width must win over the outer frame")
    }

    @MainActor func testFlatten_nestedFrameFrame_unspecifiedInnerDimFallsThroughToOuter() {
        // Inner frame only constrains width; outer only constrains height. Both should apply.
        let root = VStackNode {
            TextNode("x").frame(width: 100).frame(height: 50)
        }
        let table = flatten(root, itemID: "nested-frame-2")
        let spec = table.frame(at: 1)
        XCTAssertEqual(spec.width, 100)
        XCTAssertEqual(spec.height, 50)
    }

    @MainActor func testFlatten_framing_foldsIntoLayoutHash() {
        // A .frame() change must change NodeTable.layoutHash so LayoutCache's CacheKey misses.
        let unframed = flatten(TextNode("x"), itemID: "a")
        let framed = flatten(TextNode("x").frame(width: 100), itemID: "a")
        XCTAssertNotEqual(unframed.layoutHash, framed.layoutHash,
            "framing is geometry — it must fold into layoutHash")
    }

    @MainActor func testFlatten_framing_doesNotAffectAppearanceHash() {
        let unframed = flatten(TextNode("x"), itemID: "a")
        let framed = flatten(TextNode("x").frame(width: 100), itemID: "a")
        XCTAssertEqual(unframed.appearanceHash, framed.appearanceHash,
            "framing must never trigger the repaint-only appearance path")
    }

    @MainActor func testNodeTable_frameAt_outOfBounds_returnsUnspecified() {
        let table = flatten(TextNode("x").frame(width: 100), itemID: "oob")
        XCTAssertEqual(table.frame(at: -1), .unspecified)
        XCTAssertEqual(table.frame(at: 99), .unspecified)
    }

    // MARK: - VelocityUI-ezo.2.5: Dynamic Type content-size-category threading

    @MainActor func testFlatten_textNode_carriesContentSizeCategoryOntoDescriptor() {
        let table = flatten(TextNode("x"), itemID: "i", contentSizeCategory: .accessibilityLarge)
        guard case .text(let d) = table.nodes[0] else { XCTFail(); return }
        XCTAssertEqual(d.contentSizeCategory, .accessibilityLarge)
    }

    @MainActor func testFlatten_defaultContentSizeCategory_isUnspecified() {
        let table = flatten(TextNode("x"), itemID: "i")
        guard case .text(let d) = table.nodes[0] else { XCTFail(); return }
        XCTAssertEqual(d.contentSizeCategory, .unspecified)
    }

    /// A category change must perturb the per-node TextDescriptor.layoutHash — this is what
    /// makes Block.contentHash (Pipeline/Block.swift) differ and drives the FrozenBitmapStore
    /// re-freeze on a Dynamic Type change (see FrozenBitmapStoreTests for the full mechanism).
    @MainActor func testFlatten_contentSizeCategory_perturbsTextDescriptorLayoutHash() {
        let large = flatten(TextNode("caption"), itemID: "i", contentSizeCategory: .large)
        let accessibility = flatten(TextNode("caption"), itemID: "i", contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        guard case .text(let d1) = large.nodes[0], case .text(let d2) = accessibility.nodes[0] else { XCTFail(); return }
        XCTAssertNotEqual(d1.layoutHash, d2.layoutHash,
            "a content-size-category change must perturb the text node's layoutHash")
        XCTAssertEqual(d1.appearanceHash, d2.appearanceHash,
            "content-size-category is geometry, not appearance")
    }

    /// A category change must perturb NodeTable.layoutHash (the CacheKey/classify() tier-1
    /// value) for a tree that contains text — otherwise LayoutCache would silently serve a
    /// stale, wrong-scale entry and classify() would never reclassify the item as `.layout`.
    @MainActor func testFlatten_contentSizeCategory_perturbsTableLayoutHashWhenTextPresent() {
        let root = { VStackNode { TextNode("caption") } }
        let large = flatten(root(), itemID: "i", contentSizeCategory: .large)
        let accessibility = flatten(root(), itemID: "i", contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        XCTAssertNotEqual(large.layoutHash, accessibility.layoutHash,
            "a text-bearing tree's NodeTable.layoutHash must change with content size category")
    }

    /// A category-blind tree (no text anywhere) must NOT have its NodeTable.layoutHash perturbed
    /// by a category change — otherwise classify()'s tier-1 fast path would miss on every
    /// Dynamic Type change even for pure-image items, and its tier-3 walk (finding no node
    /// actually differing) would misclassify the item as `.media` instead of `.none`.
    @MainActor func testFlatten_contentSizeCategory_doesNotPerturbTableLayoutHashForTextFreeTree() {
        let url = URL(string: "https://example.com/img.jpg")!
        let root = { VStackNode { AsyncImageNode(url: url, aspectRatio: 1.0) } }
        let large = flatten(root(), itemID: "i", contentSizeCategory: .large)
        let accessibility = flatten(root(), itemID: "i", contentSizeCategory: .accessibilityExtraExtraExtraLarge)
        XCTAssertEqual(large.layoutHash, accessibility.layoutHash,
            "a category-blind (text-free) tree's NodeTable.layoutHash must stay stable across categories")
    }

    /// `.unspecified` must be a true identity transform — omitting the parameter and passing
    /// `.unspecified` explicitly must produce byte-identical layoutHash values (not merely
    /// equal-to-each-other values that both differ from the pre-ezo.2.5 baseline). Locks in
    /// `testFlatten_textDescriptor_carriesNodeHashes` / `testFlatten_tableHashes_matchRootNode`'s
    /// exact-equality contract against TextNode.layoutHash / root.layoutHash.
    @MainActor func testFlatten_unspecifiedCategory_isByteIdenticalToOmittingParameter() {
        let node = TextNode("caption")
        let omitted = flatten(node, itemID: "i")
        let explicit = flatten(node, itemID: "i", contentSizeCategory: .unspecified)
        guard case .text(let d1) = omitted.nodes[0], case .text(let d2) = explicit.nodes[0] else { XCTFail(); return }
        XCTAssertEqual(d1.layoutHash, d2.layoutHash)
        XCTAssertEqual(omitted.layoutHash, explicit.layoutHash)
        XCTAssertEqual(d1.layoutHash, node.layoutHash,
            "unspecified must not perturb the text node's layoutHash away from TextNode.layoutHash itself")
    }
}

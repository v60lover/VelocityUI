// FragmentTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

final class FragmentTests: XCTestCase {

    // MARK: - Helpers

    private func imageDesc(aspectRatio: CGFloat = 2.0, hash: Int = 1) -> ImageDescriptor {
        ImageDescriptor(url: nil, aspectRatio: aspectRatio, contentMode: 0,
                        cornerRadius: 0, layoutHash: hash, appearanceHash: hash)
    }

    private func textDesc(_ content: String, hash: Int = 2) -> TextDescriptor {
        TextDescriptor(content: content, font: VFontDescriptor(size: 14, weight: 0),
                       color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                       lineLimit: nil, lineBreakMode: 0,
                       layoutHash: hash, appearanceHash: hash)
    }

    // MARK: - Test 1: VStack[Image, Text] produces 2 fragments with correct absolute frames

    func testVStackImageTextProduces2Fragments() async throws {
        // Nodes: 0=VStack, 1=Image (aspectRatio 2.0), 2=Text
        // At width=320: image height = 320/2 = 160. Text is below at y=160.
        let table = NodeTable(
            itemID: "t1",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 0, spacing: 0)),
                .image(imageDesc(aspectRatio: 2.0, hash: 1)),
                .text(textDesc("Hello", hash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 10, appearanceHash: 10
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 2)

        let imgF = try XCTUnwrap(fragments.first { if case .image = $0.content { return true }; return false })
        let txtF = try XCTUnwrap(fragments.first { if case .text  = $0.content { return true }; return false })

        XCTAssertEqual(imgF.frame.origin.y, 0,   accuracy: 0.5)
        XCTAssertEqual(imgF.frame.height,   160, accuracy: 0.5)
        XCTAssertEqual(imgF.frame.width,    320, accuracy: 0.5)

        XCTAssertEqual(txtF.frame.origin.y, 160, accuracy: 1.0)
        XCTAssertGreaterThan(txtF.frame.width, 0)
        XCTAssertLessThanOrEqual(txtF.frame.width, 320 + 1)
    }

    // MARK: - Test 2: Nested stacks — absolute frames match hand-computed values

    func testNestedStacksAbsoluteFrames() async throws {
        // OuterVStack (0)
        //   Image (1)  aspectRatio=2.0 → height 160 at width 320
        //   InnerVStack (2)
        //     TextA (3)
        //     TextB (4)
        // Expected: image [y=0, h=160], textA [y=160], textB [y=160+h(textA)]
        let table = NodeTable(
            itemID: "t2",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 0, spacing: 0)),
                .image(imageDesc(aspectRatio: 2.0, hash: 10)),
                .vstack(VStackDescriptor.test(alignment: 0, spacing: 0)),
                .text(textDesc("TextA", hash: 20)),
                .text(textDesc("TextB", hash: 30)),
            ],
            parentIndices: [-1, 0, 0, 2, 2],
            layoutHash: 100, appearanceHash: 100
        )

        let pool = TextMeasurementPool(capacity: 2)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 3)  // image + textA + textB

        let imgF  = try XCTUnwrap(fragments.first { $0.id == 1 })
        let txtAF = try XCTUnwrap(fragments.first { $0.id == 3 })
        let txtBF = try XCTUnwrap(fragments.first { $0.id == 4 })

        // Image at y=0, h=160
        XCTAssertEqual(imgF.frame.origin.y, 0,   accuracy: 0.5)
        XCTAssertEqual(imgF.frame.height,   160, accuracy: 0.5)

        // TextA starts immediately below image
        XCTAssertGreaterThanOrEqual(txtAF.frame.origin.y, 159.5)

        // TextB starts exactly where TextA ends
        let textABottom = txtAF.frame.origin.y + txtAF.frame.height
        XCTAssertEqual(txtBF.frame.origin.y, textABottom, accuracy: 0.5)

        // Image spans full width; text fragments are constrained but positive
        XCTAssertEqual(imgF.frame.width, 320, accuracy: 0.5)
        XCTAssertGreaterThan(txtAF.frame.width, 0)
        XCTAssertGreaterThan(txtBF.frame.width, 0)
    }

    // MARK: - Test 3: ZStack — overlapping frames, z-order back-to-front

    func testZStackOverlappingFramesAndZOrder() async {
        // ZStack (0): Image (1) behind, Text (2) in front.
        // Both children start at (0,0) — they overlap.
        // Array order = z-order: index 0 = back, index 1 = front.
        let table = NodeTable(
            itemID: "t3",
            nodes: [
                .zstack(ZStackDescriptor.test(alignment: 4)),
                .image(imageDesc(aspectRatio: 1.0, hash: 1)),
                .text(textDesc("Overlay", hash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 5, appearanceHash: 5
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 200, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 2)

        // Both fragments originate at (0,0) — they overlap
        for f in fragments {
            XCTAssertEqual(f.frame.origin.x, 0, accuracy: 0.5)
            XCTAssertEqual(f.frame.origin.y, 0, accuracy: 0.5)
        }

        // Z-order preserved: image first (back), text second (front)
        if case .image = fragments[0].content {} else {
            XCTFail("fragments[0] should be image (back layer)")
        }
        if case .text = fragments[1].content {} else {
            XCTFail("fragments[1] should be text (front layer)")
        }
    }

    // MARK: - Test 4: Fragment ID stability across two independent measure passes

    func testFragmentIDStabilityAcrossRemeasure() async {
        let table = NodeTable(
            itemID: "t4",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 0, spacing: 0)),
                .image(imageDesc(aspectRatio: 1.5, hash: 1)),
                .text(textDesc("Stable", hash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 99, appearanceHash: 99
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout1 = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let layout2 = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        let frags1 = extractFragments(table: table, layout: layout1)
        let frags2 = extractFragments(table: table, layout: layout2)

        XCTAssertEqual(frags1.count, frags2.count)
        for (f1, f2) in zip(frags1, frags2) {
            XCTAssertEqual(f1.id, f2.id,
                "Fragment ID must be stable across re-measures (got \(f1.id) vs \(f2.id))")
            XCTAssertEqual(f1.frame, f2.frame,
                "Fragment frame must be identical across re-measures for the same table")
        }
    }

    // MARK: - Test 5: HStack spacing is correctly applied to absolute x-origins

    func testHStackSpacingAppliedToAbsoluteFrames() async throws {
        // HStack (0, spacing: 8)
        //   Hosting(100×100) (1)  — fixed size, predictable width
        //   Text (2)
        // Expected: Hosting at x=0, Text at x=100+8=108
        let table = NodeTable(
            itemID: "t6",
            nodes: [
                .hstack(HStackDescriptor.test(alignment: 1, spacing: 8)),
                .hosting(HostingDescriptor(size: CGSize(width: 100, height: 100), layoutHash: 1, appearanceHash: 1)),
                .text(textDesc("right", hash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 200, appearanceHash: 200
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 2)

        let hostF = try XCTUnwrap(fragments.first { $0.id == 1 })
        let txtF  = try XCTUnwrap(fragments.first { $0.id == 2 })

        XCTAssertEqual(hostF.frame.origin.x, 0,   accuracy: 0.5)
        XCTAssertEqual(hostF.frame.width,    100, accuracy: 0.5)

        // Text must start at 100 (hosting width) + 8 (spacing) = 108
        XCTAssertEqual(txtF.frame.origin.x, 108, accuracy: 0.5)
    }

    // MARK: - Test: HStack TextNode is measured at its proportional share, not the full width (VelocityUI-g5x)

    func testHStackTextChildMeasuredAtProportionalWidthNotFullWidth() async throws {
        // HStack (0, spacing: 8)
        //   Hosting(100×100) (1) — fixed claim
        //   Text (2)             — must resolve to width=320-100-8=212, not 320
        // Long enough that wrapping differs measurably between width 212 and width 320,
        // so the resulting height is an observable proxy for "which width was it measured at".
        let longText = "The quick brown fox jumps over the lazy dog while the sun sets slowly behind distant mountains."
        let table = NodeTable(
            itemID: "hstack-proportional",
            nodes: [
                .hstack(HStackDescriptor.test(alignment: 1, spacing: 8)),
                .hosting(HostingDescriptor(size: CGSize(width: 100, height: 100), layoutHash: 1, appearanceHash: 1)),
                .text(textDesc(longText, hash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 300, appearanceHash: 300
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)
        let txtF = try XCTUnwrap(fragments.first { $0.id == 2 })

        let referenceTable = NodeTable(
            itemID: "reference",
            nodes: [.text(textDesc(longText, hash: 2))],
            parentIndices: [-1],
            layoutHash: 301, appearanceHash: 301
        )
        let expectedAt212 = await measureNode(referenceTable, nodeIndex: 0, width: 212, textPool: pool)
        let wouldBeAt320 = await measureNode(referenceTable, nodeIndex: 0, width: 320, textPool: pool)

        XCTAssertEqual(txtF.frame.height, expectedAt212.totalFrame.height, accuracy: 1.0)
        XCTAssertGreaterThan(
            abs(expectedAt212.totalFrame.height - wouldBeAt320.totalFrame.height), 1.0,
            "test fixture must wrap differently at 212 vs 320 or this test can't distinguish the two widths"
        )
    }

    // MARK: - Test: HStack totalFrame.width never exceeds the container width (VelocityUI-g5x)

    func testHStackTotalFrameWidthDoesNotExceedContainerWidth() async {
        let table = NodeTable(
            itemID: "hstack-bounded",
            nodes: [
                .hstack(HStackDescriptor.test(alignment: 1, spacing: 8)),
                .hosting(HostingDescriptor(size: CGSize(width: 100, height: 100), layoutHash: 1, appearanceHash: 1)),
                .text(textDesc("short", hash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 302, appearanceHash: 302
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        XCTAssertLessThanOrEqual(layout.totalFrame.width, 320.5)
    }

    // MARK: - Test: HStack Spacer claims its own size, not the container width (VelocityUI-g5x)

    func testHStackSpacerClaimsOwnSizeNotContainerWidth() async throws {
        // HStack (0, spacing: 8)
        //   Spacer(20) (1)
        //   Hosting(50×50) (2)
        // Expected: Hosting starts at 20 (spacer width) + 8 (spacing) = 28.
        let table = NodeTable(
            itemID: "hstack-spacer",
            nodes: [
                .hstack(HStackDescriptor.test(alignment: 1, spacing: 8)),
                .spacer(20),
                .hosting(HostingDescriptor(size: CGSize(width: 50, height: 50), layoutHash: 1, appearanceHash: 1)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 303, appearanceHash: 303
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)

        let hostF = try XCTUnwrap(fragments.first { $0.id == 2 })
        XCTAssertEqual(hostF.frame.origin.x, 28, accuracy: 0.5)
        XCTAssertEqual(layout.totalFrame.width, 78, accuracy: 0.5)
    }

    // MARK: - Test 7: Spacer produces a geometry fragment at correct position

    func testSpacerProducesGeometryFragment() async throws {
        // VStack (0)
        //   Image (1)  aspectRatio=2.0 → height 160
        //   Spacer(40) (2)  → y=160, h=40
        //   Text (3)        → y=200
        let table = NodeTable(
            itemID: "t5",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 0, spacing: 0)),
                .image(imageDesc(aspectRatio: 2.0, hash: 1)),
                .spacer(40),
                .text(textDesc("Below spacer", hash: 3)),
            ],
            parentIndices: [-1, 0, 0, 0],
            layoutHash: 50, appearanceHash: 50
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 3)  // image + spacer + text

        let spacerF = try XCTUnwrap(fragments.first { $0.id == 2 })
        if case .geometry = spacerF.content {} else {
            XCTFail("Spacer should produce .geometry fragment, got \(spacerF.content)")
        }
        XCTAssertEqual(spacerF.frame.height,   40,  accuracy: 0.5)
        XCTAssertEqual(spacerF.frame.origin.y, 160, accuracy: 0.5)
    }

    // MARK: - Framing: applyFrame semantics (VelocityUI-rsg / VelocityUI-3a4)

    // MARK: Test 8: center alignment, slot LARGER than content

    func testApplyFrame_centerAlignment_slotLargerThanContent() async {
        // Hosting(100x50) framed to a 300x150 slot — center alignment (default) must center
        // the intrinsic content box within the larger slot: offset = (slot-content)/2 on each axis.
        let table = NodeTable(
            itemID: "frame-center-larger",
            nodes: [.hosting(HostingDescriptor(size: CGSize(width: 100, height: 50), layoutHash: 1, appearanceHash: 1))],
            parentIndices: [-1],
            layoutHash: 1, appearanceHash: 1,
            frames: [FrameSpec(width: 300, height: 150)]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        XCTAssertEqual(layout.totalFrame, CGRect(x: 0, y: 0, width: 300, height: 150),
            "totalFrame must equal the framed slot exactly")
        XCTAssertEqual(layout.contentFrame, CGRect(x: 100, y: 50, width: 100, height: 50),
            "contentFrame must be the intrinsic box centered: offset ((300-100)/2, (150-50)/2)")
    }

    // MARK: Test 9: clip-to-frame, slot SMALLER than content

    func testApplyFrame_clipToFrame_slotSmallerThanContent() async {
        // Hosting(200x200) framed DOWN to a smaller 50x50 slot — the slot wins: contentFrame
        // is clamped to the slot (never larger than it), with zero offset on both axes.
        let table = NodeTable(
            itemID: "frame-clip-smaller",
            nodes: [.hosting(HostingDescriptor(size: CGSize(width: 200, height: 200), layoutHash: 1, appearanceHash: 1))],
            parentIndices: [-1],
            layoutHash: 1, appearanceHash: 1,
            frames: [FrameSpec(width: 50, height: 50)]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        XCTAssertEqual(layout.totalFrame, CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 0, width: 50, height: 50),
            "content must clamp to the slot bounds with zero offset — no negative-padding shift beyond the slot")
    }

    // MARK: Test 10: image .fill fills the slot; .fit letterboxes

    func testApplyFrame_imageFill_fillsSlotExactly() async {
        // aspectRatio 3.0 at width 200 would normally give height 66.67 (letterboxed) — .fill
        // ignores aspect ratio entirely and fills the slot exactly.
        let d = ImageDescriptor(url: nil, aspectRatio: 3.0, contentMode: VContentMode.fill.rawValue,
                                 cornerRadius: 0, layoutHash: 1, appearanceHash: 1)
        let table = NodeTable(
            itemID: "frame-image-fill",
            nodes: [.image(d)],
            parentIndices: [-1],
            layoutHash: 1, appearanceHash: 1,
            frames: [FrameSpec(width: 200, height: 200)]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 0, width: 200, height: 200),
            ".fill must fill the framed slot exactly, not letterbox")
    }

    func testApplyFrame_imageFit_letterboxesWithinSlot() async {
        let table = NodeTable(
            itemID: "frame-image-fit",
            nodes: [.image(imageDesc(aspectRatio: 2.0, hash: 1))],  // contentMode defaults to .fit (0)
            parentIndices: [-1],
            layoutHash: 1, appearanceHash: 1,
            frames: [FrameSpec(width: 200, height: 200)]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        // Intrinsic at framed width 200, aspectRatio 2.0 => height 100 — smaller than the
        // 200-tall slot, so .fit letterboxes it and centers vertically: y = (200-100)/2 = 50.
        XCTAssertEqual(layout.contentFrame, CGRect(x: 0, y: 50, width: 200, height: 100),
            ".fit must letterbox (not stretch) and center within the slot")
    }

    // MARK: Test 11: container framing shifts children, contentFrame stays nil

    func testApplyFrame_container_shiftsChildrenByCenterOffset_contentFrameNil() async throws {
        // VStack(0, framed height:300) → Hosting(1, 100x50)
        // VStack's own intrinsic height (50, single child) is smaller than the framed slot
        // (300) — applyFrame's CONTAINER branch must shift children by the center offset
        // rather than reporting a separate contentFrame (which stays nil for containers).
        let table = NodeTable(
            itemID: "frame-container-vstack",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 1, spacing: 0)),
                .hosting(HostingDescriptor(size: CGSize(width: 100, height: 50), layoutHash: 1, appearanceHash: 1)),
            ],
            parentIndices: [-1, 0],
            layoutHash: 10, appearanceHash: 10,
            frames: [FrameSpec(height: 300)]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        XCTAssertEqual(layout.totalFrame, CGRect(x: 0, y: 0, width: 320, height: 300))
        XCTAssertNil(layout.contentFrame, "containers express framing via child offset, never contentFrame")
        let child = try XCTUnwrap(layout.children.first)
        // Single 50-tall child centered in a 300-tall slot => y = (300-50)/2 = 125.
        XCTAssertEqual(child.totalFrame.origin.y, 125, accuracy: 0.5)
    }

    // MARK: Test 12: extractFragments emits a framed leaf at its absolute contentFrame

    func testExtractFragments_framedLeaf_emitsAtAbsoluteContentFrame() async throws {
        // VStack(0) → Hosting(1, 60x40) then Hosting(2, framed to 200x200, centered) below it.
        // Fragment.frame for the framed leaf must equal its LOCAL contentFrame shifted by the
        // parent's absolute origin — not totalFrame (the full, unaligned slot).
        let table = NodeTable(
            itemID: "frame-extract-leaf",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 1, spacing: 0)),
                .hosting(HostingDescriptor(size: CGSize(width: 60, height: 40), layoutHash: 1, appearanceHash: 1)),
                .hosting(HostingDescriptor(size: CGSize(width: 100, height: 100), layoutHash: 2, appearanceHash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 11, appearanceHash: 11,
            frames: [FrameSpec.unspecified, FrameSpec.unspecified, FrameSpec(width: 200, height: 200)]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)
        let framedF = try XCTUnwrap(fragments.first { $0.id == 2 })

        // Second child sits below the first (y=40, VStack cursor). The framed hosting's own
        // contentFrame centers its 100x100 intrinsic content within its 200x200 slot: local
        // offset (50, 50). Absolute frame = parent origin (0,40) + local contentFrame (50,50).
        XCTAssertEqual(framedF.frame, CGRect(x: 50, y: 90, width: 100, height: 100))
    }

    // MARK: Test 13: intrinsicHeight <-> measureNode parity across frame combinations (LayoutEngine.swift:82 invariant)

    func testIntrinsicHeight_matchesMeasureNode_acrossFrameCombinations() async throws {
        let pool = TextMeasurementPool(capacity: 1)
        let width: CGFloat = 300

        func makeTable(frame: FrameSpec?) -> NodeTable {
            NodeTable(
                itemID: "parity",
                nodes: [.image(imageDesc(aspectRatio: 1.6, hash: 1))],
                parentIndices: [-1],
                layoutHash: 1, appearanceHash: 1,
                frames: frame.map { [$0] }
            )
        }

        let combos: [(name: String, spec: FrameSpec?)] = [
            ("neither", nil),
            ("height-only", FrameSpec(height: 220)),
            ("width-only", FrameSpec(width: 150)),
            ("both", FrameSpec(width: 150, height: 220)),
        ]

        for combo in combos {
            let table = makeTable(frame: combo.spec)
            let layout = await measureNode(table, nodeIndex: 0, width: width, textPool: pool)
            let intrinsic = try XCTUnwrap(intrinsicHeight(for: table, width: width),
                "single-image row must always produce a non-nil intrinsic height, combo: \(combo.name)")
            XCTAssertEqual(intrinsic, layout.totalFrame.height, accuracy: 0.01,
                "intrinsicHeight must mirror measureNode exactly for combo: \(combo.name)")
        }
    }

    // MARK: Test 14: measureHStack — fixed-width-framed text does not absorb flexible remainder

    func testMeasureHStack_fixedWidthFramedText_claimsExactWidth_flexibleGetsRemainder() async throws {
        // HStack(0, spacing: 0) → Text(1, framed width:80) , Text(2, flexible/unframed)
        // The framed text's own ResolvedLayout.totalFrame.width must be EXACTLY its framed
        // width (80) — not a proportional share — and the flexible sibling must start
        // immediately after it (x=80) and be measured at the full remainder (320-80=240),
        // not an even 160/160 split.
        let longText = "The quick brown fox jumps over the lazy dog while the sun sets slowly behind distant mountains."
        let table = NodeTable(
            itemID: "hstack-fixed-and-flexible-text",
            nodes: [
                .hstack(HStackDescriptor.test(alignment: 1, spacing: 0)),
                .text(textDesc("Fixed", hash: 1)),
                .text(textDesc(longText, hash: 2)),
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 20, appearanceHash: 20,
            frames: [FrameSpec.unspecified, FrameSpec(width: 80), FrameSpec.unspecified]
        )
        let pool = TextMeasurementPool(capacity: 2)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)

        XCTAssertEqual(layout.children.count, 2)
        let fixedChild = try XCTUnwrap(layout.children.first { $0.nodeIndex == 1 })
        let flexChild = try XCTUnwrap(layout.children.first { $0.nodeIndex == 2 })

        XCTAssertEqual(fixedChild.totalFrame.width, 80,
            "framed text must claim exactly its framed width, not a proportional share")
        XCTAssertEqual(flexChild.totalFrame.origin.x, 80, accuracy: 0.5)

        // Confirm the flexible sibling was actually measured at the full remainder (240), not
        // an even 320/2=160 split, using wrap-sensitive height as the observable proxy
        // (same pattern as testHStackTextChildMeasuredAtProportionalWidthNotFullWidth above).
        let referenceTable = NodeTable(
            itemID: "reference", nodes: [.text(textDesc(longText, hash: 2))],
            parentIndices: [-1], layoutHash: 21, appearanceHash: 21
        )
        let expectedAt240 = await measureNode(referenceTable, nodeIndex: 0, width: 240, textPool: pool)
        let wouldBeAt160 = await measureNode(referenceTable, nodeIndex: 0, width: 160, textPool: pool)

        XCTAssertEqual(flexChild.totalFrame.height, expectedAt240.totalFrame.height, accuracy: 1.0,
            "flexible sibling must be measured at the full remainder (320-80=240), not an even 160/160 split")
        XCTAssertGreaterThan(
            abs(expectedAt240.totalFrame.height - wouldBeAt160.totalFrame.height), 1.0,
            "test fixture must wrap differently at 240 vs 160 or this test can't distinguish the two widths"
        )
    }

    // MARK: - Framing: geometry-level clip-to-frame for overflowing descendants (VelocityUI-983)

    // MARK: Test 15: benchmark repro — framed container clips an overflowing unframed leaf

    func testFramedContainer_clipsOverflowingUnframedImageChild() async throws {
        // Reproduces the BenchmarkHost glitch: HStack { Image(aspectRatio: 0.5, .fit) }
        // .frame(width:400, height:200). The unframed child measures 400x800 (width /
        // aspectRatio) — `applyFrame`'s container branch only shifts children by an alignment
        // offset, it doesn't resize/clip, so without a geometry-level clip in extractFragments
        // this leaf overflows the cell by 600pt. RenderCell never sets masksToBounds, so the
        // overflow paints over neighboring cells on scroll-up. The clip must clamp the emitted
        // fragment to the framed slot.
        let table = NodeTable(
            itemID: "benchmark-repro",
            nodes: [
                .hstack(HStackDescriptor.test(alignment: 1, spacing: 0)),
                .image(imageDesc(aspectRatio: 0.5, hash: 1)),  // contentMode defaults to .fit (0)
            ],
            parentIndices: [-1, 0],
            layoutHash: 1, appearanceHash: 1,
            frames: [FrameSpec(width: 400, height: 200), FrameSpec.unspecified]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 400, textPool: pool)

        // Sanity: confirms the bug's own premise still holds pre-clip — the raw (unclipped)
        // child layout really does overflow, and the container's own totalFrame is correctly
        // the framed 400x200 slot. If either of these stops being true the repro is stale.
        XCTAssertEqual(layout.totalFrame, CGRect(x: 0, y: 0, width: 400, height: 200))
        let rawChild = try XCTUnwrap(layout.children.first)
        XCTAssertEqual(rawChild.totalFrame.height, 800,
            "sanity: the raw child ResolvedLayout must still overflow — this is what extractFragments clamps")

        let fragments = extractFragments(table: table, layout: layout)
        let imgF = try XCTUnwrap(fragments.first { $0.id == 1 })

        XCTAssertEqual(imgF.frame, CGRect(x: 0, y: 0, width: 400, height: 200),
            "image fragment must be clamped to the framed slot (400x200), not the raw 400x800")
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 200).contains(imgF.frame),
            "clamped fragment must lie entirely within the framed slot")
    }

    // MARK: Test 16: unframed control — no clip is ever introduced without an explicit .frame()

    func testUnframedContainer_doesNotClipChildren_byteIdenticalToPreClipBehavior() async throws {
        // Same HStack{Image} shape as the benchmark repro, but with NO `.frame()` anywhere —
        // `NodeTable.frames` stays nil, so `extractFragments`'s `clip` argument stays nil for
        // the entire recursion and the intersection never runs. The overflowing image must be
        // emitted at its full, unclamped size — clipping is only ever introduced by an
        // explicit `.frame()` on an ancestor, never inferred from an unrelated overflow.
        let table = NodeTable(
            itemID: "unframed-control",
            nodes: [
                .hstack(HStackDescriptor.test(alignment: 1, spacing: 0)),
                .image(imageDesc(aspectRatio: 0.5, hash: 1)),
            ],
            parentIndices: [-1, 0],
            layoutHash: 2, appearanceHash: 2
            // frames omitted -> nil, matching a genuinely unframed NodeTable (VelocityUI-dv7's
            // zero-cost invariant: no [FrameSpec] array at all, not merely all-.unspecified).
        )
        XCTAssertNil(table.frames)

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 400, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)
        let imgF = try XCTUnwrap(fragments.first { $0.id == 1 })

        XCTAssertEqual(imgF.frame, CGRect(x: 0, y: 0, width: 400, height: 800),
            "unframed rows must be unaffected by the clip fix — same output as before VelocityUI-983")
    }

    // MARK: Test 17: framed container whose child is SMALLER than the slot — clip never fires spuriously

    func testFramedContainer_childSmallerThanSlot_isNotClipped() async throws {
        // VStack(0, framed to 300x300) → Hosting(1, 60x40)
        // The child is well within the slot on both axes — the clip established by the framed
        // ancestor must intersect harmlessly (child ⊆ clip), producing the SAME fragment as if
        // no clip had ever been introduced. Guards against the fix being overly aggressive.
        let table = NodeTable(
            itemID: "framed-container-no-spurious-clip",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 1, spacing: 0)),
                .hosting(HostingDescriptor(size: CGSize(width: 60, height: 40), layoutHash: 1, appearanceHash: 1)),
            ],
            parentIndices: [-1, 0],
            layoutHash: 3, appearanceHash: 3,
            frames: [FrameSpec(width: 300, height: 300), FrameSpec.unspecified]
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 300, textPool: pool)
        let fragments = extractFragments(table: table, layout: layout)
        let hostF = try XCTUnwrap(fragments.first { $0.id == 1 })

        // 60x40 child centered vertically in a 300-tall slot (VStack always reports its own
        // intrinsic width as the full proposed width, so only vertical centering applies
        // here): offset = (0, (300-40)/2) = (0, 130).
        XCTAssertEqual(hostF.frame, CGRect(x: 0, y: 130, width: 60, height: 40),
            "a child well within the framed slot must be unaffected by the clip — no spurious clamping")
    }
}
#endif

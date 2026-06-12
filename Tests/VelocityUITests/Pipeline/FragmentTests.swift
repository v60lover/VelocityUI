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
                .vstack(VStackDescriptor(alignment: 0, spacing: 0)),
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
                .vstack(VStackDescriptor(alignment: 0, spacing: 0)),
                .image(imageDesc(aspectRatio: 2.0, hash: 10)),
                .vstack(VStackDescriptor(alignment: 0, spacing: 0)),
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
                .zstack(ZStackDescriptor(alignment: 4)),
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
                .vstack(VStackDescriptor(alignment: 0, spacing: 0)),
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
                .hstack(HStackDescriptor(alignment: 1, spacing: 8)),
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

    // MARK: - Test 7: Spacer produces a geometry fragment at correct position

    func testSpacerProducesGeometryFragment() async throws {
        // VStack (0)
        //   Image (1)  aspectRatio=2.0 → height 160
        //   Spacer(40) (2)  → y=160, h=40
        //   Text (3)        → y=200
        let table = NodeTable(
            itemID: "t5",
            nodes: [
                .vstack(VStackDescriptor(alignment: 0, spacing: 0)),
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
}
#endif

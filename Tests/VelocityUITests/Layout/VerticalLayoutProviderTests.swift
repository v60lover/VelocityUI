// VerticalLayoutProviderTests.swift

import XCTest
@testable import VelocityUI

final class VerticalLayoutProviderTests: XCTestCase {

    private let provider = VerticalLayoutProvider(spacing: 8)

    // MARK: - Helpers

    private func layout(height: CGFloat) -> ResolvedLayout {
        ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 320, height: height))
    }

    // MARK: - frames(for:availableWidth:)

    func testEmptyLayouts() {
        let result = provider.frames(for: [], availableWidth: 375)
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleItem() {
        let result = provider.frames(for: [layout(height: 200)], availableWidth: 375)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], CGRect(x: 0, y: 0, width: 375, height: 200))
    }

    func testMixedHeightItems_handComputedFrames() {
        // Heights: 100, 50, 200. spacing = 8.
        // frame[0]: y=0,   h=100
        // frame[1]: y=108, h=50   (100 + 8)
        // frame[2]: y=166, h=200  (108 + 50 + 8)
        let layouts = [layout(height: 100), layout(height: 50), layout(height: 200)]
        let frames = provider.frames(for: layouts, availableWidth: 320)

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 0,   width: 320, height: 100))
        XCTAssertEqual(frames[1], CGRect(x: 0, y: 108, width: 320, height: 50))
        XCTAssertEqual(frames[2], CGRect(x: 0, y: 166, width: 320, height: 200))
    }

    func testNoSpacingAfterLastItem() {
        let layouts = [layout(height: 100), layout(height: 50)]
        let frames = provider.frames(for: layouts, availableWidth: 320)
        // contentHeight = frame[1].maxY = 108 + 50 = 158 (no trailing spacing)
        XCTAssertEqual(frames[1].maxY, 158)
    }

    func testContentSizeEqualsFrameMaxY() {
        // 1000 items at height 100, spacing 8 → contentHeight = 1000×100 + 999×8 = 107992
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 1000)
        let frames = provider.frames(for: layouts, availableWidth: 320)
        let expectedContentHeight: CGFloat = 1000 * 100 + 999 * 8
        XCTAssertEqual(frames.last?.maxY ?? 0, expectedContentHeight, accuracy: 0.001)
    }

    func testFrameWidthMatchesAvailableWidth() {
        let frames = provider.frames(for: [layout(height: 100), layout(height: 200)], availableWidth: 414)
        XCTAssertTrue(frames.allSatisfy { $0.width == 414 })
    }

    func testAdjacentFrames_minYEqualsSuccessorMaxYPlusSpacing() {
        let layouts = (0..<5).map { _ in layout(height: CGFloat.random(in: 50...300)) }
        let frames = provider.frames(for: layouts, availableWidth: 320)
        for i in 0..<(frames.count - 1) {
            XCTAssertEqual(frames[i].maxY + 8, frames[i + 1].minY, accuracy: 0.001)
        }
    }

    // MARK: - refineFrames

    func testRefine_growsItem_shiftsSubsequentDown() {
        var frames = provider.frames(for: [layout(height: 100), layout(height: 50), layout(height: 200)], availableWidth: 320)
        // Refine index 0: estimated 100 → actual 150 (delta +50)
        let delta = VerticalLayoutProvider.refineFrames(&frames, at: 0, newHeight: 150)
        XCTAssertEqual(delta, 50, accuracy: 0.001)
        XCTAssertEqual(frames[0].height, 150)
        XCTAssertEqual(frames[1].minY, 158, accuracy: 0.001)   // was 108, now 108+50
        XCTAssertEqual(frames[2].minY, 216, accuracy: 0.001)   // was 166, now 166+50
    }

    func testRefine_shrinksItem_shiftsSubsequentUp() {
        var frames = provider.frames(for: [layout(height: 200), layout(height: 100)], availableWidth: 320)
        // Refine index 0: estimated 200 → actual 100 (delta -100)
        let delta = VerticalLayoutProvider.refineFrames(&frames, at: 0, newHeight: 100)
        XCTAssertEqual(delta, -100, accuracy: 0.001)
        XCTAssertEqual(frames[0].height, 100)
        XCTAssertEqual(frames[1].minY, 108, accuracy: 0.001)   // was 208, now 208-100
    }

    func testRefine_noChange_returnsZero() {
        var frames = provider.frames(for: [layout(height: 100), layout(height: 50)], availableWidth: 320)
        let delta = VerticalLayoutProvider.refineFrames(&frames, at: 0, newHeight: 100)
        XCTAssertEqual(delta, 0)
        XCTAssertEqual(frames[1].minY, 108, accuracy: 0.001)   // unchanged
    }

    func testRefine_lastItem_onlyUpdatesThatFrame() {
        var frames = provider.frames(for: [layout(height: 100), layout(height: 50)], availableWidth: 320)
        let originalY1 = frames[1].minY
        _ = VerticalLayoutProvider.refineFrames(&frames, at: 1, newHeight: 80)
        XCTAssertEqual(frames[0].height, 100)
        XCTAssertEqual(frames[1].minY, originalY1, accuracy: 0.001)
        XCTAssertEqual(frames[1].height, 80)
    }

    func testRefine_outOfBounds_returnsZero() {
        var frames = provider.frames(for: [layout(height: 100)], availableWidth: 320)
        let delta = VerticalLayoutProvider.refineFrames(&frames, at: 5, newHeight: 200)
        XCTAssertEqual(delta, 0)
    }

    func testRefine_negativeIndex_returnsZero() {
        var frames = provider.frames(for: [layout(height: 100), layout(height: 50)], availableWidth: 320)
        let delta = VerticalLayoutProvider.refineFrames(&frames, at: -1, newHeight: 200)
        XCTAssertEqual(delta, 0)
        XCTAssertEqual(frames[0].height, 100)  // unchanged
        XCTAssertEqual(frames[1].minY, 108, accuracy: 0.001)
    }

    // MARK: - firstIndex(maxYGreaterThan:) — top endpoint

    func testFirstIndex_maxYGreaterThan_emptyFrames() {
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: [], maxYGreaterThan: 0), 0)
    }

    func testFirstIndex_maxYGreaterThan_exactBoundary() {
        // frame[0] = [0..100]. At y=100, frame[0].maxY == y (not strictly greater) → skip to 1.
        let frames = provider.frames(for: [layout(height: 100), layout(height: 50)], availableWidth: 320)
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: 100), 1)
    }

    func testFirstIndex_maxYGreaterThan_insideFrame() {
        let frames = provider.frames(for: [layout(height: 100), layout(height: 50), layout(height: 200)], availableWidth: 320)
        // At y=50 (inside frame[0]): first visible = 0
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: 50), 0)
        // At y=108 (frame[1].minY): first visible = 1
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: 108), 1)
    }

    func testFirstIndex_maxYGreaterThan_beyondAll() {
        let frames = provider.frames(for: [layout(height: 100), layout(height: 50)], availableWidth: 320)
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: 10_000), frames.count)
    }

    // MARK: - firstIndex(minYNotLessThan:) — bottom endpoint

    func testFirstIndex_minYNotLessThan_emptyFrames() {
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: [], minYNotLessThan: 0), 0)
    }

    func testFirstIndex_minYNotLessThan_bottomStraddlingFrame_isIncluded() {
        // frame[0]=[0..100], frame[1]=[108..158], frame[2]=[166..366]
        let frames = provider.frames(for: [layout(height: 100), layout(height: 50), layout(height: 200)], availableWidth: 320)
        // viewportBottom = 200: frame[2].minY = 166 < 200 → it's partially on-screen → end = 3 (frame[2] included)
        let end = VerticalLayoutProvider.firstIndex(in: frames, minYNotLessThan: 200)
        XCTAssertEqual(end, 3)  // frame[2] (straddling the bottom edge) is included in [0, 3)
        // Verify frame[2] is indeed straddling: minY < 200 but maxY > 200
        XCTAssertLessThan(frames[2].minY, 200)
        XCTAssertGreaterThan(frames[2].maxY, 200)
    }

    func testFirstIndex_minYNotLessThan_frameExactlyAtBoundary() {
        // frame[2].minY = 166. At y=166: frame[2].minY == y → end = 2 (frame[2] not included).
        let frames = provider.frames(for: [layout(height: 100), layout(height: 50), layout(height: 200)], availableWidth: 320)
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: frames, minYNotLessThan: 166), 2)
    }

    func testFirstIndex_minYNotLessThan_beyondAll() {
        let frames = provider.frames(for: [layout(height: 100)], availableWidth: 320)
        XCTAssertEqual(VerticalLayoutProvider.firstIndex(in: frames, minYNotLessThan: 10_000), frames.count)
    }

    // MARK: - visibleIndexRange

    func testVisibleIndexRange_includesStradlingBottomEdge() {
        // 10 items × 100h, spacing 8. viewportTop=108, viewportBottom=408.
        // frame[3] = (minY: 324, maxY: 424) — straddles the bottom edge.
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 10)
        let frames = provider.frames(for: layouts, availableWidth: 320)
        let range = VerticalLayoutProvider.visibleIndexRange(in: frames, viewportTop: 108, viewportBottom: 408)
        XCTAssertEqual(range.lowerBound, 1)
        // frame[3].minY = 324 < 408 → included. frame[4].minY = 432 >= 408 → excluded.
        XCTAssertEqual(range.upperBound, 4)  // items {1, 2, 3} all visible
        // Every item in range overlaps the viewport.
        for i in range {
            XCTAssertGreaterThan(frames[i].maxY, 108,  "frame \(i) should extend below viewportTop")
            XCTAssertLessThan   (frames[i].minY, 408,  "frame \(i) should start above viewportBottom")
        }
    }

    func testVisibleIndexRange_emptyFrames() {
        let range = VerticalLayoutProvider.visibleIndexRange(in: [], viewportTop: 0, viewportBottom: 812)
        XCTAssertTrue(range.isEmpty)
    }

    // MARK: - Integrated: refinement + binary search compose correctly

    /// The key viewport-stability invariant:
    /// After refining an item above the viewport and adjusting contentOffset by delta,
    /// `firstIndex(maxYGreaterThan: adjustedViewportTop)` still returns the same item
    /// that was first visible before refinement.
    func testIntegrated_refinement_viewportStability_withBinarySearch() {
        // 5 items, item 0 has an estimated height of 100.
        let layouts = [layout(height: 100), layout(height: 200), layout(height: 150), layout(height: 120), layout(height: 90)]
        var frames = provider.frames(for: layouts, availableWidth: 320)

        // Viewport top is at item 1's minY.
        let originalViewportTop: CGFloat = frames[1].minY  // 108
        let firstVisible = VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: originalViewportTop)
        XCTAssertEqual(firstVisible, 1, "item 1 should be first visible before refinement")

        // Item 0 refines: estimate 100 → actual 160.
        let delta = VerticalLayoutProvider.refineFrames(&frames, at: 0, newHeight: 160)
        XCTAssertEqual(delta, 60, accuracy: 0.001)

        // Caller adjusts contentOffset by delta because item 0 is above the viewport.
        let adjustedViewportTop = originalViewportTop + delta  // 168

        // After adjustment, item 1 is still the first visible item.
        let newFirstVisible = VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: adjustedViewportTop)
        XCTAssertEqual(newFirstVisible, firstVisible, "first visible item must not change after refinement + contentOffset adjustment")
        XCTAssertEqual(adjustedViewportTop, frames[1].minY, accuracy: 0.001, "adjusted viewport top must equal item 1's new minY")
    }

    /// Viewport-stability also holds when an item above the viewport shrinks.
    func testIntegrated_refinement_shrink_viewportStability() {
        let layouts = [layout(height: 300), layout(height: 100), layout(height: 100)]
        var frames = provider.frames(for: layouts, availableWidth: 320)
        let originalViewportTop: CGFloat = frames[1].minY  // 308
        let delta = VerticalLayoutProvider.refineFrames(&frames, at: 0, newHeight: 100)  // shrinks by 200
        XCTAssertEqual(delta, -200, accuracy: 0.001)
        let adjustedViewportTop = originalViewportTop + delta  // 108
        let firstVisible = VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: adjustedViewportTop)
        XCTAssertEqual(firstVisible, 1)
        XCTAssertEqual(adjustedViewportTop, frames[1].minY, accuracy: 0.001)
    }

    // MARK: - Performance

    func testPerformance_10k_items_under1ms() {
        let layouts = [ResolvedLayout](repeating: layout(height: 100), count: 10_000)
        let start = CFAbsoluteTimeGetCurrent()
        _ = provider.frames(for: layouts, availableWidth: 375)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("VerticalLayoutProvider 10k items: \(String(format: "%.3f", ms)) ms")
        #if !DEBUG
        XCTAssertLessThan(ms, 1.0, "Frame pass for 10k items exceeded 1ms budget (\(String(format: "%.3f", ms)) ms)")
        #endif
    }
}

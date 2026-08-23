// WarmRangeTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Covers VelocityUI-jc9z's acceptance criteria for `FeedScrollView.warmRange(viewportTop:viewportBottom:)`:
/// screens mode must scale with real items-per-screen (the grid prefetch fix), and items mode
/// must stay byte-identical to the pre-fix `keepStart`/`keepEnd` formula (regression guard).
@MainActor
final class WarmRangeTests: XCTestCase {

    struct TestItem: Identifiable, Sendable {
        let id: Int
        let aspectRatio: CGFloat
        init(id: Int, aspectRatio: CGFloat = 1.0) {
            self.id = id
            self.aspectRatio = aspectRatio
        }
    }

    private func makeEnvironment() -> RenderEnvironment {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore()
        )
    }

    private func items(count: Int, aspectRatio: CGFloat = 1.0) -> [TestItem] {
        (0..<count).map { TestItem(id: $0, aspectRatio: aspectRatio) }
    }

    // MARK: - Screens mode / grid: the actual bug fix

    /// VelocityUI-jc9z's core regression guard: a 3-col grid packs many tiles per screen, so a
    /// fixed item-count warm window (the old default, ahead:10) is smaller than one screen.
    /// Screens mode must instead scale with the real items-per-screen density.
    func testWarmRangeScreensModeScalesWithItemsPerScreen_Grid() {
        let provider = GridLayoutProvider(columns: 3, spacing: 6)
        let feed = FeedScrollView<TestItem>(
            environment: makeEnvironment(),
            frame: CGRect(x: 0, y: 0, width: 375, height: 812),
            warmWindow: .screens(leading: 2, trailing: 1),
            layoutProvider: provider
        )
        feed.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }
        feed.items = items(count: 300, aspectRatio: 1.0)   // square tiles
        feed.layoutSubviews()

        let visRange = feed._lastVisibleRange
        XCTAssertGreaterThan(visRange.count, 0, "Sanity: some tiles must be visible at rest")

        let warmRange = feed._testWarmRange(viewportTop: 0, viewportBottom: 812)

        // The bug: items(ahead: 10) on a dense grid warms FEWER tiles than are already visible.
        // Screens mode must warm strictly more than that old default, for the same content.
        let oldItemModeCount = visRange.count + 10
        XCTAssertGreaterThan(
            warmRange.count, oldItemModeCount,
            "screens(leading: 2) must warm strictly more than the old items(ahead: 10) default " +
            "for a dense grid — got \(warmRange.count) tiles vs visible+10=\(oldItemModeCount)"
        )

        // leading: 2 screens should add roughly 2 screens' worth of tiles ahead of the visible
        // range (± one row for partial-row rounding at the boundary — GridLayoutProvider rounds
        // up to whole rows).
        let expectedAhead = 2 * visRange.count
        let actualAhead = warmRange.upperBound - visRange.upperBound
        let rowTolerance = 3 * 3   // up to 3 rows of slack (3 columns each)
        XCTAssertLessThanOrEqual(
            abs(actualAhead - expectedAhead), rowTolerance,
            "leading: 2 should warm ~2 screens' worth of tiles ahead (expected ~\(expectedAhead), got \(actualAhead))"
        )
    }

    // MARK: - Screens mode / vertical: degrades to a small item count

    /// Same knob (`.screens(leading: 2, trailing: 1)`) over a single-column feed where each item
    /// is sized to fill roughly one screen — proves screens mode degrades sensibly to a small
    /// item-ahead count when items-per-screen ~= 1, instead of over- or under-warming.
    func testWarmRangeScreensModeApproximatesItemsAhead_Vertical() {
        let viewportHeight: CGFloat = 812
        let width: CGFloat = 375
        let feed = FeedScrollView<TestItem>(
            environment: makeEnvironment(),
            frame: CGRect(x: 0, y: 0, width: width, height: viewportHeight),
            warmWindow: .screens(leading: 2, trailing: 1),
            layoutProvider: VerticalLayoutProvider(spacing: 0)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }
        // aspectRatio = width / height chosen so each item's measured height ~= one viewport.
        feed.items = items(count: 50, aspectRatio: width / viewportHeight)
        feed.layoutSubviews()

        let visRange = feed._lastVisibleRange
        XCTAssertEqual(visRange.count, 1, "Sanity: exactly one ~screen-tall item should be visible at rest")

        let warmRange = feed._testWarmRange(viewportTop: 0, viewportBottom: viewportHeight)
        let aheadCount = warmRange.upperBound - visRange.upperBound

        // ~1 item per screen, leading: 2 screens -> roughly 2 items ahead (allow ±1 for the
        // partial-item straddling the boundary).
        XCTAssertTrue(
            (1...3).contains(aheadCount),
            "leading: 2 screens over ~1-item-tall content should warm ~2 items ahead, got \(aheadCount)"
        )
    }

    // MARK: - Items mode: byte-identical regression guard

    /// Item-count mode must reproduce the exact pre-fix `keepStart`/`keepEnd` formula:
    /// `max(0, vis.lowerBound - behind) ..< min(count, vis.upperBound + ahead)` — existing
    /// callers who opted into `prefetchWindow(ahead:behind:)` must see zero behavior change.
    func testWarmRangeItemsModeMatchesOldKeepRangeFormula() {
        let totalCount = 100
        let ahead = 10, behind = 3
        let feed = FeedScrollView<TestItem>(
            environment: makeEnvironment(),
            frame: CGRect(x: 0, y: 0, width: 375, height: 812),
            warmWindow: .items(ahead: ahead, behind: behind)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }
        feed.items = items(count: totalCount)
        feed.layoutSubviews()

        let vis = feed._lastVisibleRange
        let expected = max(0, vis.lowerBound - behind) ..< min(totalCount, vis.upperBound + ahead)
        let actual = feed._testWarmRange(viewportTop: 0, viewportBottom: 812)

        XCTAssertEqual(actual, expected, "items(ahead:behind:) mode must match the old keepStart/keepEnd formula exactly")
    }
}
#endif

// GridScrollIntegrationTests.swift

#if canImport(UIKit)
import XCTest
import os
@testable import VelocityUI

/// Integration coverage for the classic grid on the real `FeedScrollView` stack — the bead's
/// "wired read path" tests, as opposed to `GridLayoutProviderTests`/`GridLayoutTests`
/// (VelocityUI-xhpu.3), which exercise `GridLayoutProvider`/`GridLayout` in isolation.
///
/// All items are nil-URL `AsyncImageNode`s with varied `aspectRatio` — heights come from the
/// synchronous `intrinsicHeight(for:width:)` fast path (real `colWidth / aspectRatio`, no decode),
/// so `resolvedFrames` are exact immediately after the first `layoutSubviews()` and stay stable
/// across pure scrolling — no async settle window needed to get correct frame geometry.
///
/// Logging: every scroll step emits viewport bounds, the actual visible range, mounted cell
/// count, and `WorkingRange`'s range start — per the bead's "detailed logging" requirement, so a
/// failure is diagnosable from the log alone.
@MainActor
final class GridScrollIntegrationTests: XCTestCase {

    /// Same rationale as `FeedScrollViewTests`/`PhaseOneIntegrationTests`: real `RenderEnvironment`
    /// instances spin up dedicated dispatch-queue executors; give the process-wide GCD pool a
    /// moment to settle before the next test class runs.
    nonisolated override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    private let log = Logger(subsystem: "com.velocityui.tests", category: "GridScrollIntegration")

    // MARK: - Deterministic randomness

    /// SplitMix64, seeded — mirrors `GridLayoutProviderTests.SeededGenerator` exactly, so a
    /// failing trial is reproducible. Duplicated rather than shared: it's a test-fixture helper,
    /// not production logic, and `GridLayoutProviderTests`'s copy is `private` to that file.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Fixtures

    struct GridItem: Identifiable, Sendable {
        let id: Int
        let aspectRatio: CGFloat
    }

    private func makeItems(count: Int, seed: UInt64) -> [GridItem] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { GridItem(id: $0, aspectRatio: CGFloat.random(in: 0.4...3.0, using: &rng)) }
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

    private func makeGridFeed(
        columns: Int,
        spacing: CGFloat = 8,
        width: CGFloat = 390,
        height: CGFloat = 844,
        env: RenderEnvironment? = nil
    ) -> FeedScrollView<GridItem> {
        let feed = FeedScrollView<GridItem>(
            environment: env ?? makeEnvironment(),
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            layoutProvider: GridLayoutProvider(columns: columns, spacing: spacing)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }
        return feed
    }

    private func makeVerticalFeed(
        spacing: CGFloat = 8,
        width: CGFloat = 390,
        height: CGFloat = 844,
        env: RenderEnvironment? = nil
    ) -> FeedScrollView<GridItem> {
        let feed = FeedScrollView<GridItem>(
            environment: env ?? makeEnvironment(),
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            layoutSpacing: spacing
        )
        feed.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }
        return feed
    }

    private func allFrames<I: Identifiable & Sendable>(
        _ feed: FeedScrollView<I>, count: Int
    ) -> [CGRect] where I.ID: Sendable {
        (0..<count).map { feed._debugResolvedFrame(at: $0) ?? .zero }
    }

    /// Ground-truth oracle for row-granular visibility — same algorithm as
    /// `GridLayoutProviderTests.naiveRowOverlapRange`, duplicated here (test-fixture helper, not
    /// production logic, private to that file). Used to cross-validate the actual value
    /// `FeedScrollView` computed and mounted cells from (`_lastVisibleRange`), not just the
    /// provider called in isolation — the bead's "through the wired read path" criterion.
    private func naiveRowOverlapRange(
        frames: [CGRect], columns: Int, viewportTop: CGFloat, viewportBottom: CGFloat
    ) -> Range<Int> {
        guard !frames.isEmpty else { return 0..<0 }
        let rowCount = (frames.count + columns - 1) / columns
        var firstRow: Int?
        var lastRow: Int?
        for row in 0..<rowCount {
            let start = row * columns
            let end = min(start + columns, frames.count)
            let rowTop = frames[start].minY
            var rowBottom = frames[start].maxY
            for i in (start + 1)..<end { rowBottom = max(rowBottom, frames[i].maxY) }
            if rowBottom > viewportTop && rowTop < viewportBottom {
                if firstRow == nil { firstRow = row }
                lastRow = row
            }
        }
        guard let f = firstRow, let l = lastRow else { return 0..<0 }
        return (f * columns)..<min(frames.count, (l + 1) * columns)
    }

    // MARK: - 1. Large grid scroll: correct columns/rows, no gaps/overlaps, exact contentSize

    func testLargeGridScrollTopToBottomAndBack_correctColumnsRowsNoGapsExactContentSize() async {
        let columns = 3
        let spacing: CGFloat = 8
        let itemCount = 5_000
        let width: CGFloat = 390
        let height: CGFloat = 844
        // Generous, item-count-independent ceiling: default prefetchAhead(10)+prefetchBehind(3)
        // plus the worst-case rows-per-viewport (shortest aspect ratio 0.4 → tallest cells are
        // shortest... inverse: aspectRatio 3.0 gives the SHORTEST cells → most rows fit) times
        // columns — see design notes for the arithmetic. 5,000 items would blow well past this
        // if the mounted set ever grew with the item total instead of the viewport.
        let mountCeiling = 200

        let items = makeItems(count: itemCount, seed: 0xC0FFEE)
        let feed = makeGridFeed(columns: columns, spacing: spacing, width: width, height: height)
        feed.items = items
        feed.layoutSubviews()

        let colWidth = GridLayoutProvider(columns: columns, spacing: spacing).measureWidth(availableWidth: width)
        var contentHeight = feed.contentSize.height
        XCTAssertGreaterThan(contentHeight, height, "5,000 mixed-height items must exceed one viewport")

        log.debug("[GridScroll] start items=\(itemCount) columns=\(columns) contentHeight=\(contentHeight)")

        func assertMountedIndicesWellFormed(step: String) {
            for i in feed._lastVisibleRange {
                guard let f = feed._debugResolvedFrame(at: i) else { continue }
                let expectedX = CGFloat(i % columns) * (colWidth + spacing)
                XCTAssertEqual(f.origin.x, expectedX, accuracy: 0.5, "[\(step)] index \(i) column x mismatch")
                let rowStart = (i / columns) * columns
                if let rowFirstFrame = feed._debugResolvedFrame(at: rowStart) {
                    XCTAssertEqual(f.origin.y, rowFirstFrame.origin.y, accuracy: 0.5,
                        "[\(step)] index \(i) not top-aligned with its row's first item")
                }
            }
        }

        let sweepSteps = 60
        for step in 0..<sweepSteps {
            let fraction = CGFloat(step) / CGFloat(sweepSteps - 1)
            let offsetY = max(0, (contentHeight - height) * fraction)
            feed.contentOffset = CGPoint(x: 0, y: offsetY)
            feed.layoutSubviews()
            let vr = feed._lastVisibleRange
            log.debug("[GridScroll] down step=\(step) viewport=[\(offsetY),\(offsetY + height)) visRange=\(vr.lowerBound)..<\(vr.upperBound) mounted=\(feed._visibleCellCount) wrStart=\(feed._debugWorkingRangeStart)")
            assertMountedIndicesWellFormed(step: "down:\(step)")
            XCTAssertLessThan(feed._visibleCellCount, mountCeiling,
                "mounted cell count must stay bounded to the working-range window, not grow with the item total")
        }

        for step in stride(from: sweepSteps - 1, through: 0, by: -1) {
            let fraction = CGFloat(step) / CGFloat(sweepSteps - 1)
            let offsetY = max(0, (contentHeight - height) * fraction)
            feed.contentOffset = CGPoint(x: 0, y: offsetY)
            feed.layoutSubviews()
            let vr = feed._lastVisibleRange
            log.debug("[GridScroll] up step=\(step) viewport=[\(offsetY),\(offsetY + height)) visRange=\(vr.lowerBound)..<\(vr.upperBound) mounted=\(feed._visibleCellCount) wrStart=\(feed._debugWorkingRangeStart)")
            assertMountedIndicesWellFormed(step: "up:\(step)")
            XCTAssertLessThan(feed._visibleCellCount, mountCeiling,
                "mounted cell count must stay bounded to the working-range window, not grow with the item total")
        }

        // Row-level no-gaps/no-overlaps + exact contentSize, checked once over the full frame set —
        // resolvedFrames are stable across pure scrolling (see file-level doc comment).
        contentHeight = feed.contentSize.height
        let allF = allFrames(feed, count: itemCount)
        let rowCount = (itemCount + columns - 1) / columns
        var previousRowBottom: CGFloat = -1
        for row in 0..<rowCount {
            let start = row * columns
            let end = min(start + columns, itemCount)
            let rowTop = allF[start].minY
            XCTAssertGreaterThanOrEqual(rowTop, previousRowBottom, "row \(row) overlaps the previous row")
            var rowBottom = allF[start].maxY
            for i in (start + 1)..<end {
                XCTAssertEqual(allF[i].origin.y, rowTop, accuracy: 0.5, "row \(row) item \(i) not top-aligned")
                rowBottom = max(rowBottom, allF[i].maxY)
            }
            previousRowBottom = rowBottom
        }

        let expectedContentHeight = GridLayoutProvider.contentHeight(for: allF, columns: columns)
        XCTAssertEqual(contentHeight, expectedContentHeight, accuracy: 0.5,
            "contentSize.height must exactly equal GridLayoutProvider.contentHeight for the full frame set")

        await drainFeedWork(feed)
    }

    // MARK: - 2. Column counts 1...4; column 1 matches the vertical feed exactly

    func testColumnCounts1Through4_column1MatchesVerticalFeedBehavior() async {
        let itemCount = 200
        let width: CGFloat = 390
        let height: CGFloat = 844
        let spacing: CGFloat = 8
        let items = makeItems(count: itemCount, seed: 0xABCDEF)
        let offsetFractions: [CGFloat] = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]

        for columns in 1...4 {
            let feed = makeGridFeed(columns: columns, spacing: spacing, width: width, height: height)
            feed.items = items
            feed.layoutSubviews()
            let contentHeight = feed.contentSize.height
            XCTAssertEqual(feed.contentSize.width, width, "columns=\(columns): contentSize.width must match bounds.width")

            for fraction in offsetFractions {
                let offsetY = max(0, (contentHeight - height) * fraction)
                feed.contentOffset = CGPoint(x: 0, y: offsetY)
                feed.layoutSubviews()
                let vr = feed._lastVisibleRange
                log.debug("[GridColumns] columns=\(columns) fraction=\(fraction) visRange=\(vr.lowerBound)..<\(vr.upperBound) mounted=\(feed._visibleCellCount)")
            }
            await drainFeedWork(feed)
        }

        // columns == 1 must match the vertical feed's resolved frames exactly — same identity
        // GridLayoutProviderTests.testColumns1_equalsVerticalLayoutProvider proves at the provider
        // level, verified here through the real FeedScrollView read path instead.
        let gridFeed = makeGridFeed(columns: 1, spacing: spacing, width: width, height: height)
        gridFeed.items = items
        gridFeed.layoutSubviews()

        let verticalFeed = makeVerticalFeed(spacing: spacing, width: width, height: height)
        verticalFeed.items = items
        verticalFeed.layoutSubviews()

        let gridContentHeight = gridFeed.contentSize.height
        XCTAssertEqual(gridContentHeight, verticalFeed.contentSize.height, accuracy: 0.5,
            "columns=1 contentSize.height must equal the vertical feed's")

        for fraction in offsetFractions {
            let offsetY = max(0, (gridContentHeight - height) * fraction)
            gridFeed.contentOffset = CGPoint(x: 0, y: offsetY)
            gridFeed.layoutSubviews()
            verticalFeed.contentOffset = CGPoint(x: 0, y: offsetY)
            verticalFeed.layoutSubviews()
            XCTAssertEqual(gridFeed._lastVisibleRange, verticalFeed._lastVisibleRange,
                "columns=1 visible range must equal the vertical feed's at fraction \(fraction)")
        }

        for i in 0..<itemCount {
            XCTAssertEqual(gridFeed._debugResolvedFrame(at: i), verticalFeed._debugResolvedFrame(at: i),
                "columns=1 resolved frame at index \(i) must equal the vertical feed's")
        }

        await drainFeedWork(gridFeed)
        await drainFeedWork(verticalFeed)
    }

    // MARK: - 3. Visibility matches the naive O(N) oracle across many viewports (wired read path)

    func testGridVisibilityMatchesNaiveOracleAcrossManyViewports_throughWiredReadPath() async {
        let columns = 3
        let spacing: CGFloat = 8
        let itemCount = 300
        let width: CGFloat = 390
        let height: CGFloat = 844

        let items = makeItems(count: itemCount, seed: 0x51DE51DE)
        let feed = makeGridFeed(columns: columns, spacing: spacing, width: width, height: height)
        feed.items = items
        feed.layoutSubviews()

        let contentHeight = feed.contentSize.height
        let allF = allFrames(feed, count: itemCount)

        var rng = SeededGenerator(seed: 0x0FF1CE)
        let trialCount = 50
        for trial in 0..<trialCount {
            let viewportHeight = CGFloat.random(in: 100...height, using: &rng)
            let viewportTop = CGFloat.random(in: -50...(contentHeight + 50), using: &rng)

            feed.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
            feed.contentOffset = CGPoint(x: 0, y: viewportTop)
            feed.layoutSubviews()

            let actual = feed._lastVisibleRange
            let oracle = naiveRowOverlapRange(
                frames: allF, columns: columns,
                viewportTop: viewportTop, viewportBottom: viewportTop + viewportHeight
            )
            log.debug("[GridOracle] trial=\(trial) viewport=[\(viewportTop),\(viewportTop + viewportHeight)) actual=\(actual.lowerBound)..<\(actual.upperBound) oracle=\(oracle.lowerBound)..<\(oracle.upperBound)")
            XCTAssertEqual(actual, oracle, "trial \(trial): wired visible range must match the naive O(N) oracle")
        }

        await drainFeedWork(feed)
    }

    // MARK: - Real-content fixtures (VelocityUI-jc9z)

    /// Serves a 2×2 JPEG synchronously — mirrors `RenderPipelineTests`/`ImagePrefetchIntegrationTests`'s
    /// per-file counting protocol (duplicated per file: test-fixture helper, not production logic).
    private final class GridScrollCountingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let data = UIGraphicsImageRenderer(
                size: CGSize(width: 2, height: 2), format: fmt
            ).jpegData(withCompressionQuality: 0.9) { ctx in
                UIColor.systemBlue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            let resp = URLResponse(
                url: request.url!, mimeType: "image/jpeg",
                expectedContentLength: data.count, textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    struct GridURLItem: Identifiable, Sendable {
        let id: Int
        let url: URL
    }

    private func makeURLItems(count: Int) -> [GridURLItem] {
        (0..<count).map { GridURLItem(id: $0, url: URL(string: "https://grid-scroll.example.com/\($0).jpg")!) }
    }

    private func makeEnvironmentWithMockedSession() -> RenderEnvironment {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GridScrollCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(session: session, dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore()
        )
    }

    // MARK: - 4. Screens-mode warms the whole first screen without any scroll (VelocityUI-jc9z)

    /// Regression test for the actual reported bug: a 3-col grid packs ~18 tiles on one screen,
    /// but the old items-mode default (ahead: 10) warmed FEWER items than fit on screen — the
    /// lower rows stayed gray placeholders forever, without any scroll. `.screens(leading: 2,
    /// trailing: 1)` — the new default — must warm the WHOLE first screen on mount, with zero
    /// scrolling.
    func testScreensModeRevealsFullFirstScreenWithoutScrolling() async throws {
        let columns = 3
        let spacing: CGFloat = 6
        let width: CGFloat = 375
        let height: CGFloat = 812
        let itemCount = 300

        let items = makeURLItems(count: itemCount)
        let env = makeEnvironmentWithMockedSession()
        let feed = FeedScrollView<GridURLItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            warmWindow: .screens(leading: 2, trailing: 1),
            layoutProvider: GridLayoutProvider(columns: columns, spacing: spacing)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: item.url, aspectRatio: 1.0) }
        feed.items = items
        feed.layoutSubviews()

        let visRange = feed._lastVisibleRange
        XCTAssertGreaterThan(visRange.count, 0, "Sanity: some tiles must be visible at rest")
        log.debug("[GridScreens] visRange=\(visRange.lowerBound)..<\(visRange.upperBound)")

        // Poll: every tile in the FIRST viewport must drain out of the placeholder branch and
        // reveal real content — with zero scrolling. Bounded at 200 x 10ms = 2s.
        var retries = 0
        while retries < 200 {
            feed.layoutSubviews()
            let allRevealed = visRange.allSatisfy { feed._debugIsContentRevealed(at: $0) }
            if allRevealed, feed._pendingFragmentIndicesCount == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            retries += 1
        }
        feed.layoutSubviews()

        for i in visRange {
            XCTAssertTrue(
                feed._debugIsContentRevealed(at: i),
                "Tile \(i) in the first viewport must reveal real content without any scroll — "
                + "screens(leading: 2) must warm the whole first screen"
            )
        }
        XCTAssertEqual(
            feed._pendingFragmentIndicesCount, 0,
            "No tile in the first viewport should remain on the placeholder branch"
        )

        await drainFeedWork(feed)
    }

    // MARK: - 5. Screens-mode warm window stays ahead of a fast downward fling (VelocityUI-jc9z)

    /// Flings down through many screens and asserts the warm window stays AHEAD of the
    /// viewport — tiles entering view must already have real content (no sustained gray band),
    /// because `screens(leading: 2, trailing: 1)` warms whole screens ahead, not a fixed item
    /// count a dense grid can outrun.
    func testScreensModeStaysAheadOfDownwardFling() async throws {
        let columns = 3
        let spacing: CGFloat = 6
        let width: CGFloat = 375
        let height: CGFloat = 812
        let itemCount = 600

        let items = makeURLItems(count: itemCount)
        let env = makeEnvironmentWithMockedSession()
        let feed = FeedScrollView<GridURLItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            warmWindow: .screens(leading: 2, trailing: 1),
            layoutProvider: GridLayoutProvider(columns: columns, spacing: spacing)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: item.url, aspectRatio: 1.0) }
        feed.items = items
        feed.layoutSubviews()

        // Let the first screen settle before flinging, matching the warm-up in the test above.
        // `_pendingFragmentIndicesCount == 0` alone is not sufficient: a cell can leave the
        // placeholder branch (fragments committed) while its image decode is still in flight —
        // `_debugIsContentRevealed` is the actual pixels-on-screen signal (see
        // `ImagePrefetchIntegrationTests.testPrefetchedIndexMountsWithContent`'s same polling shape).
        var retries = 0
        while retries < 200 {
            feed.layoutSubviews()
            let vr = feed._lastVisibleRange
            if feed._pendingFragmentIndicesCount == 0, vr.allSatisfy({ feed._debugIsContentRevealed(at: $0) }) {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            retries += 1
        }

        let contentHeight = feed.contentSize.height
        let flingSteps = 8
        for step in 1...flingSteps {
            let offsetY = min(max(0, contentHeight - height), CGFloat(step) * height)
            feed.contentOffset = CGPoint(x: 0, y: offsetY)
            feed.layoutSubviews()

            // Bounded settle window at each landing spot — mirrors real scroll cadence
            // (fling, pause, repeat) rather than a single instantaneous jump.
            var settleRetries = 0
            while settleRetries < 100 {
                feed.layoutSubviews()
                let vr = feed._lastVisibleRange
                if feed._pendingFragmentIndicesCount == 0, vr.allSatisfy({ feed._debugIsContentRevealed(at: $0) }) {
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
                settleRetries += 1
            }
            feed.layoutSubviews()

            let visRange = feed._lastVisibleRange
            log.debug("[GridFling] step=\(step) offsetY=\(offsetY) visRange=\(visRange.lowerBound)..<\(visRange.upperBound)")
            for i in visRange {
                XCTAssertTrue(
                    feed._debugIsContentRevealed(at: i),
                    "step \(step): tile \(i) entering the viewport must already have real content — no sustained gray band"
                )
            }
        }

        await drainFeedWork(feed)
    }
}
#endif

// PhaseOneIntegrationTests.swift

#if canImport(UIKit)
import XCTest
import Darwin
import os
@testable import VelocityUI

// MARK: - PhaseOneIntegrationTests

/// Cross-component integration suite proving the full Phase 1 data flow:
/// items → flatten → prefetch → ring buffer → cells → image decode → content delivery.
///
/// Policy: NO mocks. All tests use real RenderEnvironment, real RenderPipeline,
/// real ImageActor, real file:// JPEG fixtures generated in-test.
/// Logging: every phase emits os_log timings so CI failures are diagnosable from
/// logs alone (project requirement).
@MainActor
final class PhaseOneIntegrationTests: XCTestCase {

    /// One-time settle window after the whole class finishes. This suite deliberately does
    /// real (no-mock) ImageActor/RenderPipeline work, including a 50-fetch concurrent decode
    /// burst — heavy GCD queue churn that can throttle a freshly-created queue in whichever
    /// class runs next. See VelocityUI-1su.6 — confirmed via full-suite bisection that this
    /// class running immediately before PlaceholderDecodeTests/RenderDifferTests caused their
    /// perf-threshold assertions to intermittently miss.
    nonisolated override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    // MARK: - Item model

    struct FeedItem: Identifiable, Sendable {
        let id: Int
        let imageURL: URL?
        let caption: String
        let aspectRatio: CGFloat
        let cornerRadius: CGFloat

        init(id: Int, imageURL: URL? = nil, caption: String = "", aspectRatio: CGFloat = 1.0, cornerRadius: CGFloat = 0) {
            self.id = id
            self.imageURL = imageURL
            self.caption = caption
            self.aspectRatio = aspectRatio
            self.cornerRadius = cornerRadius
        }
    }

    // MARK: - Fixture factory

    private static let fixtureColors: [UIColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemYellow, .systemPink, .systemIndigo, .systemBrown,
    ]

    private func jpegData(width: Int, height: Int, index: Int) -> Data {
        let color = Self.fixtureColors[index % Self.fixtureColors.count]
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt)
            .jpegData(withCompressionQuality: 0.85) { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    private func writeTempJPEG(width: Int = 60, height: Int = 60, index: Int = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("velocityui_fixture_\(UUID().uuidString).jpg")
        try jpegData(width: width, height: height, index: index).write(to: url)
        return url
    }

    private func makeImageURLs(count: Int) throws -> [URL] {
        try (0..<count).map { try writeTempJPEG(index: $0) }
    }

    // MARK: - Environment + feed factories

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
            videoPreparation: videoPrep
        )
    }

    private func makeFeed(
        width: CGFloat = 375,
        height: CGFloat = 812,
        env: RenderEnvironment? = nil
    ) -> FeedScrollView<FeedItem> {
        let environment = env ?? makeEnvironment()
        return FeedScrollView<FeedItem>(
            environment: environment,
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    // MARK: - Timing helpers

    private var machToNs: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }

    // MARK: - Logger

    private let log = Logger(subsystem: "com.velocityui.tests", category: "Phase1Integration")

    // MARK: - Helpers

    /// Returns the contentLayer (non-gradient sublayer) of the first currently-mounted cell.
    /// "First mounted" means sublayers[0], which equals item 0 only when offset=0 and
    /// items are mounted in ascending-index order. Callers must scroll to top before using
    /// this helper if they need to assert about item 0 specifically.
    private func findFirstMountedContentLayer(in feed: FeedScrollView<FeedItem>) -> CALayer? {
        guard let subs = feed.layer.sublayers, !subs.isEmpty else { return nil }
        return subs[0].sublayers?.first { !($0 is CAGradientLayer) }
    }

    /// Returns the contentLayer of the cell mounted for item at `index` (by visibleCells lookup).
    private func findContentLayerForItem(at index: Int, in feed: FeedScrollView<FeedItem>) -> CALayer? {
        guard let cellLayer = feed._cellLayer(at: index) else { return nil }
        return cellLayer.sublayers?.first { !($0 is CAGradientLayer) }
    }

    // MARK: - Test 1: Phase 1 End-to-End Flow

    /// Validates the full Phase 1 pipeline on the real stack:
    ///   200 items → flatten → prefetch → ring buffer → cells → image decode → content delivery.
    ///
    /// Phases:
    ///   1. Fixture write: 200 solid-color 60×60 JPEGs to temp dir
    ///   2. Mount: assign items to FeedScrollView, trigger first layout
    ///   3. Warmup: 500ms minimum + drain until WR has entries for items 0-4
    ///   4. Scroll sweep: 100 offsets simulating 120Hz cadence; yield every 5 steps
    ///   5. Content arrival: wait up to 10s for first cell's contentLayer.opacity == 1
    func testPhaseOneFlowEndToEnd() async throws {
        let itemCount = 200
        let visibleWindow = 5

        let machToNs = self.machToNs
        let t_fixture = mach_absolute_time()
        let urls = try makeImageURLs(count: itemCount)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        log.debug("[E2E] fixture write: \(Int((Double(mach_absolute_time() - t_fixture) * machToNs / 1_000_000).rounded()))ms for \(itemCount) images")

        let items = (0..<itemCount).map { i in
            FeedItem(id: i, imageURL: urls[i], caption: "Item \(i)", aspectRatio: 1.0)
        }

        let feed = makeFeed(width: 375, height: 812)
        feed.cellBuilder = { item in
            AsyncImageNode(url: item.imageURL, aspectRatio: item.aspectRatio)
        }
        feed.items = items
        feed.layoutSubviews()

        // Phase 3: 0.5s warmup — let pipeline Tasks run
        let t_warmup = mach_absolute_time()
        let warmupDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < warmupDeadline {
            await Task.yield()
            feed.layoutSubviews()
        }

        // Drain until WR has entries for first visibleWindow items
        let drainDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < drainDeadline {
            await Task.yield()
            feed.layoutSubviews()
            if feed._workingRangeMissCount(from: 0, to: visibleWindow) == 0 { break }
        }
        let warmupMs = Int((Double(mach_absolute_time() - t_warmup) * machToNs / 1_000_000).rounded())
        let wrmisses = feed._workingRangeMissCount(from: 0, to: visibleWindow)
        log.debug("[E2E] warmup \(warmupMs)ms · WR misses[0..\(visibleWindow)]=\(wrmisses)")

        XCTAssertEqual(wrmisses, 0,
            "WR must have entries for visible items 0..<\(visibleWindow) after 0.5s warmup + drain")

        // Phase 4: scroll sweep simulating 120Hz offsets
        let contentHeight = feed.contentSize.height
        let viewportHeight: CGFloat = 812
        let sweepSteps = 100
        let t_sweep = mach_absolute_time()

        for step in 0..<sweepSteps {
            let fraction = CGFloat(step) / CGFloat(max(1, sweepSteps - 1))
            let offsetY = max(0, (contentHeight - viewportHeight) * fraction)
            feed.contentOffset = CGPoint(x: 0, y: offsetY)
            feed.layoutSubviews()
            // Yield every 5 steps so pipeline Tasks progress between frames
            if step % 5 == 0 { await Task.yield() }
        }
        let sweepMs = Int((Double(mach_absolute_time() - t_sweep) * machToNs / 1_000_000).rounded())
        log.debug("[E2E] scroll sweep: \(sweepSteps) steps in \(sweepMs)ms")

        XCTAssertGreaterThan(feed.layer.sublayers?.count ?? 0, 0,
            "Visible cells must be mounted at end of scroll sweep")

        // Phase 5: scroll back to top, wait for image content
        feed.contentOffset = .zero
        feed.layoutSubviews()

        var contentArrived = false
        let contentDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < contentDeadline {
            await Task.yield()
            feed.layoutSubviews()
            if let cl = findFirstMountedContentLayer(in: feed), cl.opacity == 1 {
                contentArrived = true
                break
            }
        }
        log.debug("[E2E] content arrived at cell 0: \(contentArrived)")
        XCTAssertTrue(contentArrived,
            "contentLayer opacity must reach 1 once the first item's image loads")
    }

    // MARK: - Test 2: Clause 1 — Zero Task spawns + scroll path performance

    /// Validates Contract Clause 1:
    ///   (a) Zero Task spawns during steady scroll (no leading-index boundary crossing).
    ///   (b) Scroll path p99 < 5ms on CI simulator (target: 1ms; 5ms gives 5× CI headroom).
    ///
    /// Uses 50 nil-URL items so no image fetch Tasks are spawned, isolating the scroll path
    /// timing to updateVisibleCells + refineKnownFrames + notifyPipelineIfNeeded (no-op).
    func testClause1ZeroSpawnsSteadyScroll() {
        let feed = makeFeed(width: 375, height: 812)
        feed.cellBuilder = { item in
            AsyncImageNode(url: item.imageURL, aspectRatio: item.aspectRatio)
        }
        feed.items = (0..<50).map { FeedItem(id: $0) }

        // Initial layout to set lastNotifiedLeadingIndex
        feed.layoutSubviews()

        #if canImport(XCTest)
        let spawnBaseline = feed._taskSpawnCount
        #endif

        // Measure: 1000 layoutSubviews at the SAME contentOffset
        let iterations = 1000
        var raw = [UInt64]()
        raw.reserveCapacity(iterations)
        let machToNs = self.machToNs

        for _ in 0..<iterations {
            let t0 = mach_absolute_time()
            feed.layoutSubviews()
            raw.append(mach_absolute_time() &- t0)
        }

        #if canImport(XCTest)
        XCTAssertEqual(feed._taskSpawnCount, spawnBaseline,
            "Zero Task spawns expected during \(iterations) frames at unchanged contentOffset")
        #endif

        let sorted = raw.sorted().map { Double($0) * machToNs }
        let median = sorted[sorted.count / 2]
        let p99 = sorted[max(0, Int(Double(sorted.count) * 0.99) - 1)]

        log.debug("[Clause1] layoutSubviews steady-state N=\(iterations): median=\(Int((median / 1000).rounded()))µs  p99=\(Int((p99 / 1000).rounded()))µs")

        XCTAssertLessThan(p99, 5_000_000,
            "Steady-state scroll path p99 must be < 5ms (target: 1ms); measured \(Int(p99.rounded()))ns. "
            + "No async, no allocation in steady state — algorithmic regression suspected.")
    }

    // MARK: - Test 3: Clauses 2/3 — Concurrent decode runs on decodeQueue, not cooperative pool

    /// Validates the structural contract for AsyncSemaphore(value: 3):
    /// "decode bursts cannot exhaust cooperative pool threads needed by measureNode."
    ///
    /// Method:
    ///   1. Run 50 concurrent image decodes (via withTaskGroup — all in-flight simultaneously).
    ///   2. Run RenderPipeline measuring 500 text tables concurrently as the measure storm.
    ///   3. Assert ALL 50 decode closures executed on velocityui.image.decode (decodeQueue),
    ///      not on the cooperative pool. Uses DispatchSpecificKey — immune to timer noise.
    ///   4. Assert pipeline populated WorkingRange for all 500 tables — no starvation.
    func testClause23ConcurrentDecodeDoesNotStarveLayout() async throws {
        let tableCount = 500
        let decodeCount = 50

        let urls = try makeImageURLs(count: decodeCount)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let env = makeEnvironment()
        let pipeline = RenderPipeline(
            textPool: env.textPool,
            layoutCache: env.layoutCache,
            imageActor: env.imageActor,
            prefetchAhead: tableCount,
            prefetchBehind: 3
        )
        let workingRange = await WorkingRange(capacity: tableCount)

        let tables: [NodeTable] = (0..<tableCount).map { i in
            NodeTable(
                itemID: i,
                nodes: [
                    .vstack(VStackDescriptor(alignment: 0, spacing: 4, layoutHash: i)),
                    .text(TextDescriptor(
                        content: "Integration item \(i): a medium-length caption for layout.",
                        font: VFontDescriptor(size: 14, weight: 0),
                        color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                        lineLimit: 3, lineBreakMode: 0,
                        layoutHash: i, appearanceHash: 0
                    ))
                ],
                parentIndices: [-1, 0],
                layoutHash: i,
                appearanceHash: 0
            )
        }

        // Reset queue-check counters before the burst.
        ImageActor._testDecodeResetCounts()

        let imageActor = env.imageActor
        let capturedURLs = urls

        // Submit all 50 decodes concurrently — they all contend on AsyncSemaphore(value:3)
        // simultaneously. This is the "50-image burst" the bead specifies.
        let decodeTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for url in capturedURLs {
                    group.addTask {
                        _ = await imageActor.image(
                            for: url,
                            targetSize: CGSize(width: 60, height: 60),
                            cornerRadius: 0,
                            scale: 1
                        )
                    }
                }
            }
        }

        // Run the measure storm concurrently with the decode burst.
        await pipeline.onIndexBoundary(0, workingRange: workingRange, tables: tables, availableWidth: 375, scale: 1)
        await pipeline.waitForCurrentPrefetch()

        // Wait for all decodes to finish.
        await decodeTask.value

        let totalDecodes = ImageActor._testDecodeTotalCount
        let onQueueDecodes = ImageActor._testDecodeOnQueueCount
        log.debug("[Clause23] decodes total=\(totalDecodes)  on-decodeQueue=\(onQueueDecodes)  expected=\(decodeCount)")

        // Structural assertion 1: all decode closures ran on velocityui.image.decode.
        // DispatchSpecificKey is the authoritative proof — it is set on decodeQueue in init
        // and checked inside the async closure via DispatchQueue.getSpecific(key:).
        // A failure here means the decode closure ran on the cooperative pool, violating
        // the AsyncSemaphore isolation contract (memory: asyncsemaphore-stays-on-the-default-actor-executor-not).
        XCTAssertEqual(totalDecodes, decodeCount,
            "All \(decodeCount) decode closures must have executed; got \(totalDecodes). "
            + "If < \(decodeCount): some images hit the NSCache (unexpected on first run with unique UUID URLs), "
            + "or were cancelled before reaching decodeQueue.async.")
        XCTAssertEqual(onQueueDecodes, totalDecodes,
            "\(totalDecodes - onQueueDecodes) of \(totalDecodes) decode closures ran OFF velocityui.image.decode — "
            + "they ran on the cooperative pool. AsyncSemaphore(value:3) must gate ALL decode work "
            + "onto decodeQueue so cooperative-pool threads remain available for measureNode.")

        // Structural assertion 2: pipeline produced WR entries for all tables — not starved.
        let pipelineMisses = (0..<tableCount).filter { workingRange.entry(at: $0) == nil }.count
        log.debug("[Clause23] pipeline WR misses=\(pipelineMisses)/\(tableCount)")
        XCTAssertEqual(pipelineMisses, 0,
            "Pipeline must populate WorkingRange for all \(tableCount) tables when run "
            + "concurrently with a 50-image decode burst. \(pipelineMisses) misses indicates "
            + "the pipeline was starved — decode work consumed cooperative pool threads.")
    }

    // MARK: - Test 4: Diff-driven update pipeline

    /// Validates the full itemsDidChange → RenderDiffer → cell lifecycle sequence:
    ///   (a) onReachEnd: item count grows from 10 to 20; new cells appear.
    ///   (b) Appearance change (cornerRadius): classified .appearance → cell identity preserved.
    ///   (c) URL swap with pre-populated DimensionCache: classified .media → cell identity preserved.
    func testDiffDrivenUpdatePipeline() async throws {
        let firstPage = 10
        let secondPage = 20

        // All image URLs have the same dimensions — pre-populate DimensionCache so
        // URL swaps on items with aspect-ratio-unchanged images classify as .media, not .layout.
        let urls = try makeImageURLs(count: secondPage + 1)  // +1 for the URL swap
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let env = makeEnvironment()

        // Pre-populate DimensionCache for the swap URL so classify() sees it immediately.
        env.dimensionCache.store(CGSize(width: 60, height: 60), for: urls[secondPage])

        let feed = makeFeed(width: 375, height: 812, env: env)
        feed.cellBuilder = { [urls] item in
            AsyncImageNode(url: item.imageURL, aspectRatio: item.aspectRatio)
                .cornerRadius(item.cornerRadius)
        }

        // Phase (a): load first page, trigger onReachEnd
        // assertForOverFulfill defaults to true — FeedScrollView.reachEndFired guards ensure
        // exactly one fire per page, so any duplicate is a real regression.
        let reachEndExp = expectation(description: "onReachEnd fires")
        feed.onReachEnd = { reachEndExp.fulfill() }

        feed.items = (0..<firstPage).map { FeedItem(id: $0, imageURL: urls[$0]) }
        feed.layoutSubviews()

        let bottom = max(0, feed.contentSize.height - feed.bounds.height)
        feed.contentOffset = CGPoint(x: 0, y: bottom)
        feed.layoutSubviews()

        await fulfillment(of: [reachEndExp], timeout: 3.0)
        log.debug("[DiffDriven] onReachEnd fired")

        feed.items = (0..<secondPage).map { FeedItem(id: $0, imageURL: urls[$0]) }
        feed.layoutSubviews()

        XCTAssertGreaterThan(feed.layer.sublayers?.count ?? 0, 0,
            "Cells must be mounted after second page load")

        // Scroll to top so items 0 and 1 are the visible cells at indices 0 and 1.
        // Required for phases (b) and (c): layer-identity assertions must target the cells
        // that actually back items 0 and 1, not mid-page cells left at the old bottom offset.
        feed.contentOffset = .zero
        feed.layoutSubviews()

        // Phase (b): appearance change on item 0 — cornerRadius 0 → 8 (same URL, same aspectRatio).
        // RenderDiffer classifies as .appearance (layoutHash unchanged, appearanceHash changed).
        // Contract: cell for item 0 is REUSED in-place — no recycle → same CALayer identity.
        let cellLayerBeforeAppearance = feed._cellLayer(at: 0)
        XCTAssertNotNil(cellLayerBeforeAppearance, "Item 0 must be visible at offset=0 before appearance change")

        feed.items = (0..<secondPage).map { i in
            FeedItem(id: i, imageURL: urls[i], cornerRadius: i == 0 ? 8 : 0)
        }
        feed.layoutSubviews()

        XCTAssertTrue(cellLayerBeforeAppearance === feed._cellLayer(at: 0),
            ".appearance change must preserve item 0 cell layer identity — classify() returned "
            + ".appearance so FeedScrollView must NOT recycle the cell to pool")
        log.debug("[DiffDriven] appearance change: cell identity preserved=\(cellLayerBeforeAppearance === feed._cellLayer(at: 0))")

        // Phase (c): URL swap on item 1 — pre-populated DimensionCache makes classify() return .media.
        // Contract: cell for item 1 is REUSED in-place — no recycle → same CALayer identity.
        let cellLayerBeforeMedia = feed._cellLayer(at: 1)
        XCTAssertNotNil(cellLayerBeforeMedia, "Item 1 must be visible at offset=0 before URL swap")

        var updatedItems = (0..<secondPage).map { i in
            FeedItem(id: i, imageURL: urls[i], cornerRadius: i == 0 ? 8 : 0)
        }
        updatedItems[1] = FeedItem(id: 1, imageURL: urls[secondPage], cornerRadius: 0)
        feed.items = updatedItems
        feed.layoutSubviews()

        XCTAssertTrue(cellLayerBeforeMedia === feed._cellLayer(at: 1),
            ".media URL swap must preserve item 1 cell layer identity — classify() returned "
            + ".media so FeedScrollView must NOT recycle the cell to pool")
        log.debug("[DiffDriven] media URL swap: cell identity preserved=\(cellLayerBeforeMedia === feed._cellLayer(at: 1))")
    }

    // MARK: - Test 5: Recycle invariant under fast scroll

    /// Verifies no stale image delivery under rapid scrolling:
    ///   - Privacy guard (_privacyGuardFiredCount) must be zero after 10 fast sweeps.
    ///     Zero means all in-flight Tasks were cancelled before reaching applyContent —
    ///     the guard is a safety net, not the primary defence.
    ///   - No crash / DEBUG assertion failure (existing RenderCell DEBUG invariant checks fire).
    ///   - After settling at offset 0, at least one cell eventually shows decoded content.
    func testRecycleInvariantFastScroll() async throws {
        let itemCount = 100

        let urls = try makeImageURLs(count: itemCount)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let items = (0..<itemCount).map { i in
            FeedItem(id: i, imageURL: urls[i], aspectRatio: 1.0)
        }

        let feed = makeFeed(width: 375, height: 812)
        feed.cellBuilder = { item in
            AsyncImageNode(url: item.imageURL, aspectRatio: item.aspectRatio)
        }
        feed.items = items
        feed.layoutSubviews()

        // Reset counter before the sweep so warmup Tasks don't pollute the count.
        RenderCell._privacyGuardFiredCount = 0

        // Fast scroll: 11 sweeps × 10 large steps each.
        // 11 sweeps (odd) → last sweep is forward (ends at max offset) so the explicit
        // settle-to-zero below is always a fresh leading-index change → fresh pipeline notification.
        let contentHeight = feed.contentSize.height
        let viewportHeight: CGFloat = 812
        let sweepCount = 11
        let stepsPerSweep = 10

        for sweep in 0..<sweepCount {
            let forward = sweep % 2 == 0
            for step in 0..<stepsPerSweep {
                let fraction: CGFloat = forward
                    ? CGFloat(step) / CGFloat(stepsPerSweep - 1)
                    : 1 - CGFloat(step) / CGFloat(stepsPerSweep - 1)
                feed.contentOffset = CGPoint(x: 0, y: max(0, (contentHeight - viewportHeight) * fraction))
                feed.layoutSubviews()
            }
            // Brief yield per sweep to let Tasks run and cancel
            await Task.yield()
        }

        let guardFiredDuringScroll = RenderCell._privacyGuardFiredCount
        log.debug("[Recycle] privacy guard fired during fast scroll: \(guardFiredDuringScroll)")

        XCTAssertEqual(guardFiredDuringScroll, 0,
            "Privacy guard must not fire during fast scroll — cancelled Tasks must return nil "
            + "before reaching applyContent. Count \(guardFiredDuringScroll) > 0 indicates a "
            + "cancellation propagation gap in the ImageActor → Task → applyContent chain.")

        // Settle at top — last sweep ended at max offset, so this is a fresh leading-index
        // change that triggers pipeline re-notification (lastNotifiedLeadingIndex != 0).
        feed.contentOffset = .zero
        feed.layoutSubviews()
        // Give the pipeline Task one additional yield to start measuring before the poll loop.
        await Task.yield()
        feed.layoutSubviews()

        var contentArrived = false
        let settleDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < settleDeadline {
            await Task.yield()
            feed.layoutSubviews()
            if let cl = findFirstMountedContentLayer(in: feed), cl.opacity == 1 {
                contentArrived = true
                break
            }
        }

        let finalGuardCount = RenderCell._privacyGuardFiredCount
        log.debug("[Recycle] final privacy guard count (includes settle phase): \(finalGuardCount)  content arrived: \(contentArrived)")

        XCTAssertTrue(contentArrived,
            "After fast scroll settles at top, cell 0 must eventually show decoded content")
    }
}
#endif

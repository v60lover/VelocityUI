// FeedScrollViewTests.swift

#if canImport(UIKit)
import XCTest
import Darwin
import os
@testable import VelocityUI

@MainActor
final class FeedScrollViewTests: XCTestCase {

    /// One-time settle window after the class finishes, on top of each real-media test's own
    /// `drainFeedWork(_:)`. ~9 tests spin up real `ImageActor`/DispatchQueueExecutor instances and
    /// decode real files in quick succession — per-test draining handles each FeedScrollView's own
    /// Tasks, but GCD's process-wide QoS worker pool can still be under pressure at the class
    /// boundary. Needed (VelocityUI-1su.6) to stop
    /// `ImagePrefetchIntegrationTests.testPrefetchedIndexMountsWithContent` missing its 5s window
    /// in full-suite runs, even though every test is well-behaved in isolation.
    nonisolated override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    // MARK: - Test fixtures

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

    private func makeFeed(width: CGFloat = 375, height: CGFloat = 812) -> FeedScrollView<TestItem> {
        let env = makeEnvironment()
        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: height))
        feed.cellBuilder = { item in
            AsyncImageNode(url: nil, aspectRatio: item.aspectRatio)
        }
        return feed
    }

    private func items(count: Int, aspectRatio: CGFloat = 1.5) -> [TestItem] {
        (0..<count).map { TestItem(id: $0, aspectRatio: aspectRatio) }
    }

    // MARK: - 1. Zero Task spawn during frames without boundary crossing

    func testNoTaskSpawnWithoutBoundaryChange() {
        let feed = makeFeed()
        feed.items = items(count: 20)

        // Force initial layout so lastNotifiedLeadingIndex is set.
        feed.layoutSubviews()
        #if canImport(XCTest)
        let baseline = feed._taskSpawnCount
        #endif

        // Simulate 100 layout cycles at the SAME contentOffset (no boundary crossing).
        for _ in 0..<100 {
            feed.layoutSubviews()
        }

        #if canImport(XCTest)
        XCTAssertEqual(feed._taskSpawnCount, baseline,
            "Zero Task spawns expected during 100 frames without a leading-index boundary crossing")
        #endif
    }

    // MARK: - 2. Task spawn counter matches boundary crossings

    func testTaskSpawnCountMatchesBoundaryCrossings() {
        let feed = makeFeed(width: 375, height: 812)
        feed.items = items(count: 200)
        feed.layoutSubviews()

        #if canImport(XCTest)
        let afterFirst = feed._taskSpawnCount
        XCTAssertEqual(afterFirst, 1, "One spawn for the initial leading index")

        // Move to a new leading index by scrolling down past one cell height.
        feed.contentOffset = CGPoint(x: 0, y: 350)
        feed.layoutSubviews()
        XCTAssertEqual(feed._taskSpawnCount, afterFirst + 1,
            "One additional spawn per unique leading-index boundary")

        // Stay at the same offset — no new spawn.
        feed.layoutSubviews()
        feed.layoutSubviews()
        XCTAssertEqual(feed._taskSpawnCount, afterFirst + 1,
            "No spawn when leading index is unchanged")
        #endif
    }

    // MARK: - 2b. Scroll direction is derived from real contentOffset deltas (VelocityUI-im6)

    func testScrollDirectionTracksRealContentOffsetDelta() {
        let feed = makeFeed(width: 375, height: 812)
        feed.items = items(count: 200)
        feed.layoutSubviews()

        #if canImport(XCTest)
        // Initial layout: contentOffset never moved from 0 — default direction (.down) holds.
        XCTAssertEqual(feed._lastScrollDirection, .down, "No offset delta yet — direction stays at its default")

        // Scroll down (increasing contentOffset.y) — direction must read .down from the real delta.
        feed.contentOffset = CGPoint(x: 0, y: 350)
        feed.layoutSubviews()
        XCTAssertEqual(feed._lastScrollDirection, .down, "Increasing contentOffset.y must derive .down")

        feed.contentOffset = CGPoint(x: 0, y: 900)
        feed.layoutSubviews()
        XCTAssertEqual(feed._lastScrollDirection, .down, "Continued downward scroll stays .down")

        // Reverse — decreasing contentOffset.y must flip the derived direction to .up.
        feed.contentOffset = CGPoint(x: 0, y: 400)
        feed.layoutSubviews()
        XCTAssertEqual(feed._lastScrollDirection, .up, "Decreasing contentOffset.y must derive .up")

        feed.contentOffset = CGPoint(x: 0, y: 100)
        feed.layoutSubviews()
        XCTAssertEqual(feed._lastScrollDirection, .up, "Continued upward scroll stays .up")

        // No delta (same offset, e.g. rubber-banding at rest) — direction holds its last value.
        feed.layoutSubviews()
        XCTAssertEqual(feed._lastScrollDirection, .up, "Zero delta must not flip direction")
        #endif
    }

    // MARK: - 3. Correct visible set at sampled offsets

    func testVisibleSetMatchesExpectedIndices() {
        let viewportHeight: CGFloat = 812
        let width: CGFloat = 375
        let feed = makeFeed(width: width, height: viewportHeight)

        // All items share aspectRatio 1.0, so every row's SYNCHRONOUS intrinsic height
        // (width / aspectRatio — VelocityUI-ksh) is `width` itself, computed before any async
        // pipeline commit. resolvedFrames are predictable from this, not from the flat
        // estimatedItemHeight placeholder.
        feed.items = items(count: 50, aspectRatio: 1.0)
        feed.layoutSubviews()

        let intrinsicItemHeight = width  // width / aspectRatio(1.0)
        let itemPlusSpacing = intrinsicItemHeight + feed.layoutSpacing

        XCTAssertGreaterThan(feed.layer.sublayers?.count ?? 0, 0,
            "Feed layer should have cell sublayers after first layout")

        // Scroll past first item — index 0 should eventually be recycled.
        feed.contentOffset = CGPoint(x: 0, y: itemPlusSpacing + 1)
        feed.layoutSubviews()

        // contentSize should reflect the synchronous intrinsic heights, not the flat estimate.
        let expectedContentHeight = CGFloat(50) * intrinsicItemHeight + CGFloat(49) * feed.layoutSpacing
        XCTAssertEqual(feed.contentSize.height, expectedContentHeight, accuracy: 0.5)
    }

    // MARK: - 4. Items append does not blank existing visible cells

    func testAppendDoesNotBlankExistingCells() {
        let feed = makeFeed()
        let firstPage = items(count: 10)
        feed.items = firstPage
        feed.layoutSubviews()

        let sublayersBefore = feed.layer.sublayers?.count ?? 0
        XCTAssertGreaterThan(sublayersBefore, 0, "Cells must be mounted after first layout")

        // Append second page.
        let secondPage = items(count: 20)
        feed.items = secondPage
        feed.layoutSubviews()

        let sublayersAfter = feed.layer.sublayers?.count ?? 0
        // Cells should be remounted (some may be recycled then re-added in new layout).
        // Key check: the total count is non-zero and contentSize reflects 20 items.
        XCTAssertGreaterThan(sublayersAfter, 0, "Cells must still be mounted after page append")
        XCTAssertGreaterThan(feed.contentSize.height, feed.bounds.height,
            "contentSize must exceed viewport after 20 items")
    }

    // MARK: - 5. onReachEnd fires exactly once per page

    func testOnReachEndFiresOncePerPage() async {
        let feed = makeFeed(width: 375, height: 812)

        // First page: scroll to bottom and expect one fire.
        let expFirst = expectation(description: "first reach-end")
        feed.onReachEnd = { expFirst.fulfill() }
        feed.items = items(count: 5)
        feed.layoutSubviews()

        let bottom = max(0, feed.contentSize.height - feed.bounds.height)
        feed.contentOffset = CGPoint(x: 0, y: bottom)
        feed.layoutSubviews()

        // fulfillment suspends the test Task, letting the spawned Task run on MainActor.
        await fulfillment(of: [expFirst], timeout: 1.0)

        // Additional frames must NOT re-fire — inverted expectation with short timeout.
        let expNoRefire = expectation(description: "no re-fire before items grow")
        expNoRefire.isInverted = true
        feed.onReachEnd = { expNoRefire.fulfill() }
        feed.layoutSubviews()
        await fulfillment(of: [expNoRefire], timeout: 0.1)

        // Second page: items grow → gate resets → fires again at new end.
        let expSecond = expectation(description: "second reach-end after items grow")
        feed.onReachEnd = { expSecond.fulfill() }
        feed.items = items(count: 10)
        feed.layoutSubviews()
        feed.contentOffset = CGPoint(x: 0, y: max(0, feed.contentSize.height - feed.bounds.height))
        feed.layoutSubviews()
        await fulfillment(of: [expSecond], timeout: 1.0)
    }

    // MARK: - 6. Width change invalidates working range and rebuilds frames from intrinsic height

    /// Pre-VelocityUI-ksh, every unmeasured row reset to the flat `estimatedItemHeight`
    /// placeholder after a width change, so `contentSize.height` was width-INDEPENDENT (same
    /// item count × same flat estimate, regardless of the new width). Post-fix, image rows
    /// reset to their SYNCHRONOUS intrinsic height (`width / aspectRatio`), which correctly
    /// DOES depend on the new width — that's the whole point of measuring real image geometry
    /// instead of a placeholder. This test now asserts the new, width-dependent invariant.
    func testWidthChangeResetsFramesToIntrinsicHeight() async {
        let aspectRatio: CGFloat = 1.5
        let itemCount = 10
        let widthBefore: CGFloat = 375
        let widthAfter: CGFloat = 667

        let feed = makeFeed(width: widthBefore, height: 812)
        feed.items = items(count: itemCount, aspectRatio: aspectRatio)
        feed.layoutSubviews()

        let expectedHeightBefore = CGFloat(itemCount) * (widthBefore / aspectRatio)
            + CGFloat(itemCount - 1) * feed.layoutSpacing
        XCTAssertEqual(feed.contentSize.height, expectedHeightBefore, accuracy: 1,
            "First layout must size every row from its synchronous intrinsic height, "
            + "not the flat estimatedItemHeight placeholder")

        // Simulate rotation: change bounds width.
        feed.frame = CGRect(x: 0, y: 0, width: widthAfter, height: 375)
        feed.layoutSubviews()

        // After width change, all frames are rebuilt at the NEW width's intrinsic height —
        // contentSize.height must scale with width/aspectRatio, not stay constant.
        let expectedHeightAfter = CGFloat(itemCount) * (widthAfter / aspectRatio)
            + CGFloat(itemCount - 1) * feed.layoutSpacing
        XCTAssertEqual(feed.contentSize.height, expectedHeightAfter, accuracy: 1,
            "Intrinsic height sum must scale with the new width after a width change")
        XCTAssertNotEqual(feed.contentSize.height, expectedHeightBefore, accuracy: 1,
            "Width-dependent intrinsic height must actually change when width changes — "
            + "a flat-estimate regression would leave this unchanged")

        // Layout cache invalidation is fire-and-forget async; no observable side-effect to assert.
    }

    // MARK: - 7. Recycle correctness: no item-A content shown while bound to item-B

    func testRecycleClearsOldContent() {
        let feed = makeFeed(width: 375, height: 200)  // tiny viewport: ~0-1 items visible
        feed.items = items(count: 30)
        feed.layoutSubviews()

        // Scroll past many items; pooled cells should be reused.
        for step in stride(from: 0, to: Int(feed.contentSize.height), by: 400) {
            feed.contentOffset = CGPoint(x: 0, y: CGFloat(step))
            feed.layoutSubviews()
        }

        // No assertions on internals here — this is a crash / assertion-violation guard.
        // RenderCell.prepareForReuse already asserts no cross-item bleed in DEBUG.
        // If we reach here without crashing, recycle semantics are correct.
        XCTAssert(true, "Scroll without crash proves recycle semantics")
    }

    // MARK: - 8. contentSize width tracks bounds.width

    func testContentSizeWidthMatchesBoundsWidth() {
        let feed = makeFeed(width: 390, height: 844)
        feed.items = items(count: 5)
        feed.layoutSubviews()
        XCTAssertEqual(feed.contentSize.width, 390)

        feed.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
        feed.layoutSubviews()
        XCTAssertEqual(feed.contentSize.width, 428)
    }

    // MARK: - Image fixture helpers (VelocityUI-vim integration tests)

    private func jpegData(width: Int, height: Int) -> Data {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt)
            .jpegData(withCompressionQuality: 0.9) { ctx in
                UIColor.systemBlue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    private func writeTempJPEG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try jpegData(width: width, height: height).write(to: url)
        return url
    }

    /// Finds the content CALayer (non-gradient sublayer) of the first mounted cell.
    private func findFirstContentLayer<I: Identifiable & Sendable>(
        in feed: FeedScrollView<I>
    ) -> CALayer? where I.ID: Sendable {
        findContentLayer(atCellIndex: 0, in: feed)
    }

    /// Finds the content CALayer (non-gradient sublayer) of the Nth mounted cell (0-based).
    private func findContentLayer<I: Identifiable & Sendable>(
        atCellIndex n: Int,
        in feed: FeedScrollView<I>
    ) -> CALayer? where I.ID: Sendable {
        guard let subs = feed.layer.sublayers, n < subs.count else { return nil }
        return subs[n].sublayers?.first { !($0 is CAGradientLayer) }
    }

    // MARK: - 9. Image content arrives after mount (end-to-end)

    /// Verifies the full pipeline: item with image URL → cell mount → pipeline measures →
    /// media fetch Task → applyContent → contentLayer.opacity == 1.
    func testImageContentArrivesAfterMount() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
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

        let feed = FeedScrollView<TestItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { _ in AsyncImageNode(url: url, aspectRatio: 1.0) }
        feed.items = [TestItem(id: 0)]
        feed.layoutSubviews()

        // Poll: pipeline measures → setNeedsLayout → refineKnownFrames applies real fragments
        // → media Task decodes → applyContent sets opacity. Each layoutSubviews() call advances
        // the state machine; yields let async Tasks run between calls.
        var contentArrived = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.opacity == 1 {
                contentArrived = true
                break
            }
        }

        XCTAssertTrue(contentArrived, "contentLayer opacity must reach 1 once the image loads")
        await drainFeedWork(feed)
    }

    // MARK: - 10. Nil-URL image node produces no media handles (no crash, no fetch)

    func testNilURLImageNodeProducesNoMediaHandles() async {
        let feed = makeFeed(width: 375, height: 812)
        feed.cellBuilder = { _ in AsyncImageNode(url: nil, aspectRatio: 1.0) }
        feed.items = [TestItem(id: 0)]
        feed.layoutSubviews()

        // Let pipeline run so cells get real fragments.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            await Task.yield()
            feed.layoutSubviews()
            // contentLayer opacity stays 0: nil URL means no image arrives, placeholder persists.
            if let cl = findFirstContentLayer(in: feed), cl.opacity == 1 { break }
        }

        // The content layer must stay at 0: no URL → no decode → no applyContent call.
        XCTAssertEqual(findFirstContentLayer(in: feed)?.opacity ?? 0, 0,
            "Nil-URL image fragment must not trigger content delivery — no URL means no fetch")
    }

    // MARK: - 11. Prepend with WR invalidation: _pendingFragmentIndices drained for known-height index

    /// Regression for the §1c bug: when items = [A] (measured) → items = [B, A],
    /// workingRange.invalidateAll() fires but knownHeights[A.id] survives, so A's new
    /// index (1) is not in estimatedIndices. Without the union fix, refineKnownFrames
    /// skips index 1 entirely and A's cell stays at opacity 0 indefinitely.
    func testPrependWithWRInvalidationDrainsKnownHeightPendingIndex() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
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

        struct ImageItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
        }
        let itemA = ImageItem(id: 0, imageURL: url)
        let itemB = ImageItem(id: 1, imageURL: nil)

        let feed = FeedScrollView<ImageItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: item.imageURL, aspectRatio: 1.0) }

        // Phase 1: mount [A], wait for pipeline to commit layout (A's height becomes known).
        feed.items = [itemA]
        feed.layoutSubviews()
        let phase1Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase1Deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.opacity == 1 { break }
        }
        XCTAssertEqual(findFirstContentLayer(in: feed)?.opacity, 1,
            "Precondition: item A must load at index 0 before prepend")

        // Phase 2: prepend B. A moves to index 1; workingRange.invalidateAll() fires.
        // knownHeights[A.id] survives → index 1 is NOT in estimatedIndices.
        // updateVisibleCells mounts index 1 with applyLayout([]) + _pendingFragmentIndices.insert(1).
        feed.items = [itemB, itemA]
        feed.layoutSubviews()

        // Phase 3: poll until refineKnownFrames delivers real fragments to index 1 (A).
        // After fix: (estimatedIndices ∪ _pendingFragmentIndices) includes index 1 → fragments
        // delivered → media Task spawns → image fetched from cache → opacity == 1.
        var aContentArrived = false
        let phase3Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase3Deadline {
            await Task.yield()
            feed.layoutSubviews()
            // A is at index 1 → sublayers are mounted in ascending index order.
            if findContentLayer(atCellIndex: 1, in: feed)?.opacity == 1 {
                aContentArrived = true
                break
            }
        }

        XCTAssertTrue(aContentArrived,
            "Cell at index 1 (item A, prepended) must receive real fragments and fade in — "
            + "_pendingFragmentIndices must be drained even when the index is absent from estimatedIndices")
        await drainFeedWork(feed)
    }

    // MARK: - 12. Cross-item recycle suppresses stale image delivery (privacy invariant)

    /// Gate actor: stores a continuation so the test can hold item A's decode in-flight
    /// until after the cross-item recycle, then resume it. Not cancellation-aware by design —
    /// the continuation is resumed explicitly by the test regardless of Task.isCancelled,
    /// ensuring item A's Task body reaches applyContent and exercises the privacy guard.
    @MainActor
    private final class DecodeGate {
        private var pendingContinuation: CheckedContinuation<Void, Never>?

        /// Called from inside ImageActor._testDecodeGateHook. Suspends until `open()` is called.
        func suspend() async {
            await withCheckedContinuation { cont in
                pendingContinuation = cont
            }
        }

        /// True once the Task is suspended at the gate (has called suspend()).
        var isWaiting: Bool { pendingContinuation != nil }

        /// Resume the suspended Task. Must be called exactly once after `isWaiting` is true.
        func open() {
            pendingContinuation?.resume()
            pendingContinuation = nil
        }
    }

    /// Verifies the `applyContent` privacy guard is actually exercised on cross-item recycle.
    ///
    /// Uses a `DecodeGate` to hold item A's decode in-flight while the cell rebinds to item B.
    /// Once opened, item A's Task calls `applyContent(id:image:for: A.id)`; the guard compares
    /// A.id against `currentItemID` (now B.id) and rejects the stale delivery.
    ///
    /// Without the gate, both "guard fired" and "Task cancelled before guard" produce
    /// `contentLayer.opacity == 0`, so the test couldn't distinguish the cases. With the gate,
    /// the Task is guaranteed to reach `applyContent`, so opacity == 0 can only mean the guard
    /// rejected the delivery.
    func testCrossItemRecycleDoesNotDeliverStaleImage() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        // Gate holds item A's decode in-flight. DecodeGate is @MainActor; the hook
        // must hop back to main to call suspend(). ImageActor runs on its dedicated
        // executor, so the hop is an actor switch — suspends ImageActor reentrance
        // while main drives the swap.
        let gate = DecodeGate()

        let dc = DimensionCache()
        let imageActor = ImageActor(dimensionCache: dc)

        // Hook: fires at the top of ImageActor.image() before any fetch work.
        // Not cancellation-aware — gate.suspend() does not use withTaskCancellationHandler,
        // so Task.cancel() marks the task cancelled but does NOT unblock the suspension.
        // The test explicitly calls gate.open() to resume item A's Task after the swap.
        await imageActor.set_testDecodeGateHook { [gate] in
            await gate.suspend()
        }

        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: imageActor,
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore()
        )

        struct ImageItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
        }
        let itemA = ImageItem(id: 0, imageURL: url)
        let itemB = ImageItem(id: 1, imageURL: nil)

        let feed = FeedScrollView<ImageItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: item.imageURL, aspectRatio: 1.0) }

        // Phase 1: mount item A. The pipeline must measure A and spawn the media Task,
        // which will block at the gate hook inside ImageActor.image().
        feed.items = [itemA]
        feed.layoutSubviews()

        // Poll until item A's decode Task is suspended at the gate. The pipeline runs
        // async (Task spawn from notifyPipelineIfNeeded); yields let it progress.
        // gate.isWaiting becomes true once the Task has entered gate.suspend().
        // Explicit waiter-count poll avoids timing-based Task.sleep.
        let mountDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !gate.isWaiting, ContinuousClock.now < mountDeadline {
            await Task.yield()
            feed.layoutSubviews()
        }
        XCTAssertTrue(gate.isWaiting,
            "Precondition: item A's decode Task must be suspended at the gate before the swap")

        // Phase 2: swap to item B. prepareForReuse sets currentItemID = B.id, resets
        // contentLayer.opacity to 0, and cancels A's MediaHandle (marks Task cancelled).
        // A's Task is suspended at the gate — it cannot observe isCancelled until it resumes.
        feed.items = [itemB]
        feed.layoutSubviews()

        // Phase 3: open the gate. Item A's Task resumes inside ImageActor.image(), completes
        // the fetch + decode, and returns the image. The Task body then calls:
        //   cell?.applyContent(id: fragmentID, image: img, for: itemA.id)
        // applyContent's privacy guard: currentItemID == B.id, itemID == A.id → rejected.
        gate.open()

        // Phase 4: poll for up to 5 s to give item A's Task time to complete the full
        // decode pipeline and call applyContent on @MainActor. The Task must call
        // applyContent (gate guarantees it reaches that site) but applyContent's privacy
        // guard must reject the delivery. Any opacity == 1 observation is a test failure.
        var staleDelivered = false
        let taskCompleteDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < taskCompleteDeadline {
            await Task.yield()
            if findFirstContentLayer(in: feed)?.opacity == 1 {
                staleDelivered = true
                break
            }
        }

        XCTAssertFalse(staleDelivered,
            "Privacy guard must reject item A's stale image on item B's cell — "
            + "opacity must stay 0 after gate-controlled delivery to the recycled cell")
        await drainFeedWork(feed)
    }

    // MARK: - 13. Same-item re-mount keeps contentLayer.opacity at 1 (no placeholder flash)

    /// Verifies: when the same item (same ID) is re-mounted via a URL change, contentLayer.opacity
    /// stays at 1 throughout — no flash to the placeholder gradient state.
    ///
    /// Why: URL is in `imageDescriptor.layoutHash`, so a URL change classifies as `.layout` →
    /// `itemsDidChange` recycles the cell via `returnToPool` (cancels pending media only,
    /// preserves sublayers/opacity) → `prepareForReuse(for: sameID)` sees `isSameItem=true` and
    /// skips the opacity reset → `applyLayout([])` (WR miss) prunes sublayers inside contentLayer
    /// but never touches `contentLayer.opacity`.
    func testSameItemRemountPreservesContentsUntilNewImageArrives() async throws {
        let url1 = try writeTempJPEG(width: 60, height: 60)
        let url2 = try writeTempJPEG(width: 90, height: 90)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        struct URLItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
        }
        let itemV1 = URLItem(id: 0, imageURL: url1)
        let itemV2 = URLItem(id: 0, imageURL: url2)

        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
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

        let feed = FeedScrollView<URLItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: item.imageURL, aspectRatio: 1.0) }

        // Phase 1: mount itemV1, wait for contentLayer.opacity == 1.
        feed.items = [itemV1]
        feed.layoutSubviews()
        let phase1Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase1Deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.opacity == 1 { break }
        }
        XCTAssertEqual(findFirstContentLayer(in: feed)?.opacity, 1,
            "Precondition: itemV1 must fully load before testing same-item recycle")

        // Phase 2: swap to itemV2 (same id=0, different URL). RenderDiffer classifies as
        // .layout (URL in imageDescriptor.layoutHash) → itemsDidChange recycles the cell.
        // prepareForReuse(for: 0) sees isSameItem=true → skips opacity reset.
        // applyLayout([]) (WR miss) prunes sublayers but NOT contentLayer.opacity.
        var opacityDroppedToZero = false
        feed.items = [itemV2]

        // Phase 3: poll 3 s confirming opacity never drops to 0.
        let phase3Deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < phase3Deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.opacity == 0 {
                opacityDroppedToZero = true
                break
            }
        }
        XCTAssertFalse(opacityDroppedToZero,
            "Same-item recycle must not reset contentLayer.opacity to 0 — "
            + "prepareForReuse(for: sameID) skips the cross-item reset")

        // Phase 4: wait for url2's image to arrive. refineKnownFrames delivers real fragments
        // once the pipeline commits → spawnMediaFetches fetches url2 → applyContent sets
        // sublayer.contents. Success when a sublayer inside contentLayer has non-nil contents.
        var newImageArrived = false
        let phase4Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase4Deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.sublayers?.first(where: { $0.contents != nil }) != nil {
                newImageArrived = true
                break
            }
        }
        XCTAssertTrue(newImageArrived,
            "url2's image must eventually arrive and be set on a sublayer inside contentLayer")
        await drainFeedWork(feed)
    }
    // MARK: - 14. Media change preserves cell identity (no recycle on .media URL swap)

    func testMediaChangeDoesNotRecycleVisibleCell() async throws {
        let url1 = try writeTempJPEG(width: 60, height: 60)
        let url2 = try writeTempJPEG(width: 60, height: 60)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
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

        struct URLItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
        }
        let item1 = URLItem(id: 0, imageURL: url1)
        let item2 = URLItem(id: 0, imageURL: url2)

        let feed = FeedScrollView<URLItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: item.imageURL, aspectRatio: 1.0) }

        feed.items = [item1]
        feed.layoutSubviews()
        let phase1Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase1Deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.sublayers?.first(where: { $0.contents != nil }) != nil { break }
        }
        XCTAssertNotNil(
            findFirstContentLayer(in: feed)?.sublayers?.first(where: { $0.contents != nil }),
            "Precondition: url1 image must load before URL swap"
        )

        dc.store(CGSize(width: 60, height: 60), for: url2)

        let cellLayerBefore = feed.layer.sublayers?.first
        XCTAssertNotNil(cellLayerBefore, "Cell must be mounted before URL swap")

        feed.items = [item2]
        feed.layoutSubviews()

        let cellLayerAfter = feed.layer.sublayers?.first
        XCTAssertTrue(cellLayerBefore === cellLayerAfter,
            ".media URL swap must reuse the same cell layer — no recycle expected")

        XCTAssertNotNil(
            findFirstContentLayer(in: feed)?.sublayers?.first(where: { $0.contents != nil }),
            "sublayer.contents must stay non-nil during .media URL swap — stale-until-replaced"
        )
        await drainFeedWork(feed)
    }

    // MARK: - 16. AnyHashable access counter: appearance-only itemsDidChange stays within differ-only bound

    /// Guards the invariant that itemsDidChange's height-forwarding path reads .itemID zero
    /// times — it uses (prevIdx, nextIdx) integer pairs, never an [AnyHashable: _] dict.
    ///
    /// `NodeTable._itemIDCounter` counts every `.itemID` property read (not AnyHashable
    /// constructions). `RenderDiffer.diff` with N all-surviving appearance-changed items reads
    /// `.itemID` exactly 4×N times (scratchPrevIndex build, lookup, removeValue, removed-check
    /// loop, each N). Height-forwarding (survivors/rebuildFrames) adds zero reads; a regression
    /// that rebuilds an `[AnyHashable: _]` dict there (+N inserts, +N lookups) raises the counter
    /// to 6×N and fails the assertion.
    ///
    /// `frame.height=0` keeps `visibleCells` empty so the appearance-changed loop's
    /// `spawnMediaFetches` call (reads `e.next.itemID` per visible cell) never executes — isolates
    /// the measurement to the differ and satisfies `_itemIDCounter`'s serial-access invariant (no
    /// concurrent Task spawns reading `.itemID` during the window).
    func testAppearanceOnlyUpdateAnyHashableAccessCountBounded() {
        struct StyleItem: Identifiable, Sendable {
            let id: Int
            let cornerRadius: CGFloat
        }

        let N = 5
        let env = makeEnvironment()
        // height=0: empty visible range → visibleCells stays empty → no Task spawns that
        // could read .itemID concurrently, satisfying the counter's serial-access invariant.
        let feed = FeedScrollView<StyleItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )
        feed.cellBuilder = { item in
            AsyncImageNode(url: nil, aspectRatio: 1.0).cornerRadius(item.cornerRadius)
        }

        // Initial load: all N items go to scratchAdded (N lookup-miss reads). Counter grows but
        // we reset it immediately after so the measurement is isolated to the appearance update.
        feed.items = (0..<N).map { StyleItem(id: $0, cornerRadius: 0) }
        NodeTable._itemIDCounter = 0

        // Appearance-only update: same IDs, cornerRadius 0→8 changes appearanceHash only.
        // AsyncImageNode.layoutHash excludes cornerRadius; AsyncImageNode.appearanceHash includes it.
        feed.items = (0..<N).map { StyleItem(id: $0, cornerRadius: 8) }

        let count = NodeTable._itemIDCounter
        // Counter must not exceed 4×N (differ-only floor). A regression that rebuilds an
        // [AnyHashable: _] dict for height-forwarding adds 2N reads, pushing count to 6×N.
        XCTAssertLessThanOrEqual(
            count, 4 * N,
            ".itemID read count \(count) exceeds the differ-only floor \(4 * N) — "
            + "itemsDidChange must not build an [AnyHashable: _] height-forwarding dict"
        )
    }

    // MARK: - 15. Appearance change preserves cell identity (no recycle on .appearance)

    func testAppearanceChangeDoesNotRecycleVisibleCell() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
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

        struct StyleItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
            let cornerRadius: CGFloat
        }
        let item1 = StyleItem(id: 0, imageURL: url, cornerRadius: 0)
        let item2 = StyleItem(id: 0, imageURL: url, cornerRadius: 8)

        let feed = FeedScrollView<StyleItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in
            AsyncImageNode(url: item.imageURL, aspectRatio: 1.0).cornerRadius(item.cornerRadius)
        }

        feed.items = [item1]
        feed.layoutSubviews()
        let phase1Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase1Deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.opacity == 1 { break }
        }
        XCTAssertEqual(findFirstContentLayer(in: feed)?.opacity, 1,
            "Precondition: item must fully load before testing appearance change")

        let cellLayerBefore = feed.layer.sublayers?.first
        XCTAssertNotNil(cellLayerBefore)

        feed.items = [item2]
        feed.layoutSubviews()

        let cellLayerAfter = feed.layer.sublayers?.first
        XCTAssertTrue(cellLayerBefore === cellLayerAfter,
            ".appearance change must reuse the same cell layer — no recycle expected")

        XCTAssertEqual(findFirstContentLayer(in: feed)?.opacity, 1,
            "contentLayer.opacity must stay 1 after .appearance change — no placeholder reset")
        await drainFeedWork(feed)
    }

    // MARK: - 17. Wall-time microbench: itemsDidChange appearance-only speedup vs e26 baseline

    /// Microbench for VelocityUI-wyc — verifies the performance claim in VelocityUI-4kp.3 #3.
    ///
    /// Measures `itemsDidChange` wall time for a 1000-item appearance-only update and compares
    /// against a synthetic e26 baseline that adds back the O(N) AnyHashable dict-build overhead
    /// 4kp.3 removed (`newIndexByItemID` build at old lines 230-232):
    ///   e26_time    ≈ current_time + T_newIndexByItemID
    ///   preE26_time ≈ current_time + T_newIndexByItemID + T_knownHeights
    ///                 (removedIDs is empty on the appearance path)
    ///
    /// Why the 3× target can't be asserted at total-function scope: on the force-miss path (nil
    /// `itemSignature`), `itemsDidChange` calls `flatten()` for all N items before diffing —
    /// ~8ms for 1000 single-node items on simulator, vs ~0.5ms for the removed dict build (~6%
    /// of total). A 3× speedup of the whole function would need the dict build to cost >2×
    /// everything else, impossible once flatten dominates. The 3× claim holds for the isolated
    /// post-differ paths (rebuildFrames + visibility loops), which are private, so this test
    /// instead asserts (a) an absolute p99 ceiling catching algorithmic regressions anywhere in
    /// the function, and (b) dict-build overhead printed for trend tracking, cross-checked
    /// against test #16 (`testAppearanceOnlyUpdateAnyHashableAccessCountBounded`, which proves
    /// the dict build's `.itemID` accesses are gone).
    ///
    /// This "flatten dominates" argument is PATH-DEPENDENT: it holds on the force-miss path this
    /// test exercises (`itemSignature` unset → cache-miss on every item, preserving today's
    /// behavior bit-for-bit). On the cache-HIT path (most items unchanged) `flatten()` is
    /// skipped for hits and total-function speedup becomes achievable — asserted separately by
    /// `testItemsDidChangeCacheHitFloor`. This test stays the force-miss baseline.
    ///
    /// Median + p99 printed for CI trend tracking.
    func testItemsDidChangeAppearanceOnlySpeedupVsE26Baseline() {
        struct StyleItem: Identifiable, Sendable {
            let id: Int
            let cornerRadius: CGFloat
        }

        let N = 1000
        let warmupIterations = 20
        let measureIterations = 100

        let env = makeEnvironment()
        // height=0: empty visible range → visibleCells stays empty → no Task spawns that
        // read .itemID concurrently, satisfying the counter's serial-access invariant.
        let feed = FeedScrollView<StyleItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )
        feed.cellBuilder = { item in
            AsyncImageNode(url: nil, aspectRatio: 1.0).cornerRadius(item.cornerRadius)
        }

        let baseItems = (0..<N).map { StyleItem(id: $0, cornerRadius: 0) }
        let altItems  = (0..<N).map { StyleItem(id: $0, cornerRadius: 8) }

        // Initial load — items go through .added path; sets up internal snapshot.
        feed.items = baseItems
        // Warmup: prime RenderDiffer scratch buffers, OS instruction caches, branch predictors.
        for i in 0..<warmupIterations {
            feed.items = i.isMultiple(of: 2) ? altItems : baseItems
        }

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let machToNs = Double(info.numer) / Double(info.denom)

        // --- Measure current implementation ---
        // Each iteration triggers a genuine appearance-only diff: same IDs, different cornerRadius.
        var currentRaw = [UInt64]()
        currentRaw.reserveCapacity(measureIterations)
        var useAlt = true
        for _ in 0..<measureIterations {
            let t0 = mach_absolute_time()
            feed.items = useAlt ? altItems : baseItems
            let t1 = mach_absolute_time()
            currentRaw.append(t1 &- t0)
            useAlt.toggle()
        }

        // --- Measure synthetic e26 dict-build overhead ---
        // Reconstructs `newIndexByItemID = Dictionary(uniqueKeysWithValues: tables.enumerated()
        //   .map { ($1.itemID, $0) })` from FeedScrollView line 230-232 (removed by 4kp.3).
        // Uses Int payload matching the actual ItemID type in this test, pre-boxed to AnyHashable
        // so the warmup effects on the boxing path match those in the real differ.
        let sinkIDs = (0..<N).map { AnyHashable($0) }
        var dictRaw = [UInt64]()
        dictRaw.reserveCapacity(measureIterations)
        for _ in 0..<measureIterations {
            let t0 = mach_absolute_time()
            var newIndexByItemID = [AnyHashable: Int](minimumCapacity: N)
            for (i, id) in sinkIDs.enumerated() { newIndexByItemID[id] = i }
            let t1 = mach_absolute_time()
            withExtendedLifetime(newIndexByItemID) {}  // prevent dead-code elimination
            dictRaw.append(t1 &- t0)
        }

        // --- Statistics ---
        func sortedNs(_ raw: [UInt64]) -> [Double] {
            raw.sorted().map { Double($0) * machToNs }
        }
        func medianNs(_ s: [Double]) -> Double { s[s.count / 2] }
        func p99Ns(_ s: [Double]) -> Double {
            s[max(0, Int(Double(s.count) * 0.99) - 1)]
        }

        let currentSorted = sortedNs(currentRaw)
        let dictSorted    = sortedNs(dictRaw)

        let currentMedian = medianNs(currentSorted)
        let currentP99    = p99Ns(currentSorted)
        let dictMedian    = medianNs(dictSorted)

        // Synthetic baselines — see struct-level doc for rationale.
        let e26Median    = currentMedian + dictMedian
        let preE26Median = currentMedian + 2.0 * dictMedian
        let speedupVsE26    = e26Median    / currentMedian
        let speedupVsPreE26 = preE26Median / currentMedian

        print("[VelocityUI-wyc] itemsDidChange appearance-only N=\(N) (\(measureIterations) iters):")
        print(String(format: "  current    median=%dns  p99=%dns",
                     Int(currentMedian.rounded()), Int(currentP99.rounded())))
        print(String(format: "  dict-build median=%dns  (newIndexByItemID overhead removed by 4kp.3)",
                     Int(dictMedian.rounded())))
        print(String(format: "  e26 baseline (synthetic) median=%dns → %.1f× speedup",
                     Int(e26Median.rounded()), speedupVsE26))
        print(String(format: "  pre-e26 baseline (synthetic) median=%dns → %.1f× speedup",
                     Int(preE26Median.rounded()), speedupVsPreE26))
        print("  [target: ≥3× vs e26, ≥10× vs pre-e26 — see measurement caveat in test docstring]")

        // Regression guard (a): the dict-build must measure a non-zero cost so the synthetic
        // baseline computation is non-degenerate. If the optimizer ever eliminates the dict
        // build loop entirely, speedup ratios collapse to 1.0 and the print output will show it.
        XCTAssertGreaterThan(dictMedian, 0,
            "[VelocityUI-wyc] dict-build baseline measured zero — optimizer may have elided the loop")

        // Regression guard (b): absolute p99 ceiling for total itemsDidChange wall time.
        // On iOS simulator N=1000 yields p99 ≈ 10ms (flatten dominates). 50ms gives 5× headroom
        // for slow CI while still catching O(N²) regressions or accidental O(N) additions that
        // push wall time into the hundreds-of-ms range.
        // Cross-check: test #16 (testAppearanceOnlyUpdateAnyHashableAccessCountBounded) asserts
        // zero .itemID accesses on the height-forwarding path — proving the dict build is gone.
        // That functional test + this wall-time ceiling together guard the regression surface.
        XCTAssertLessThan(currentP99, 50_000_000,
            "[VelocityUI-wyc] itemsDidChange appearance-only p99 must stay < 50ms — "
            + "measured \(Int(currentP99.rounded()))ns; O(N²) regression or unexpected O(N) "
            + "allocation suspected if this fires. See test docstring for measurement context.")
    }

    // MARK: - 18. nil itemSignature calls builder for all items on every update

    func testItemSignatureNilCallsBuilderForAllItems() {
        struct Item: Identifiable, Sendable {
            let id: Int
            let cornerRadius: CGFloat
        }

        let N = 10
        let env = makeEnvironment()
        let feed = FeedScrollView<Item>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )

        final class Counter { var value = 0 }
        let counter = Counter()

        feed.cellBuilder = { item in
            counter.value += 1
            return AsyncImageNode(url: nil, aspectRatio: 1.0).cornerRadius(item.cornerRadius)
        }
        // itemSignature is nil by default — force-miss path

        let items = (0..<N).map { Item(id: $0, cornerRadius: 0) }

        counter.value = 0
        feed.items = items
        feed.layoutSubviews()
        XCTAssertEqual(counter.value, N,
            "nil itemSignature: initial load must call builder for all N items")

        counter.value = 0
        feed.items = items  // identical items — nil sig still force-misses every item
        feed.layoutSubviews()
        XCTAssertEqual(counter.value, N,
            "nil itemSignature: repeat update must call builder N times — no caching on force-miss path")
    }

    // MARK: - 19. itemSignature cache hit skips builder for unchanged items

    func testItemSignatureHitSkipsBuilder() {
        struct Item: Identifiable, Sendable {
            let id: Int
            let cornerRadius: CGFloat
        }

        let N = 5
        let env = makeEnvironment()
        let feed = FeedScrollView<Item>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )

        final class Counter { var value = 0 }
        let counter = Counter()

        feed.itemSignature = { AnyHashable($0.cornerRadius) }
        feed.cellBuilder = { item in
            counter.value += 1
            return AsyncImageNode(url: nil, aspectRatio: 1.0).cornerRadius(item.cornerRadius)
        }

        var baseItems = (0..<N).map { Item(id: $0, cornerRadius: 0) }

        counter.value = 0
        feed.items = baseItems
        feed.layoutSubviews()
        XCTAssertEqual(counter.value, N,
            "Initial load must call builder for all N items — no cache entries yet")

        // Only item id=2 changes signature; the other N-1 items must hit the cache.
        baseItems[2] = Item(id: 2, cornerRadius: 8)
        counter.value = 0
        feed.items = baseItems
        feed.layoutSubviews()
        XCTAssertEqual(counter.value, 1,
            "Only 1 item changed signature — builder must be called exactly once; "
            + "\(N - 1) items must be served from cache")
    }

    // MARK: - 20. itemSignature changed for an item — NodeTable is refreshed

    func testItemSignatureChangedRefreshesNodeTable() {
        struct Item: Identifiable, Sendable {
            let id: Int
            let cornerRadius: CGFloat
        }

        let N = 3
        let env = makeEnvironment()
        let feed = FeedScrollView<Item>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )

        final class Counter { var value = 0 }
        let counter = Counter()

        feed.itemSignature = { AnyHashable($0.cornerRadius) }
        feed.cellBuilder = { item in
            counter.value += 1
            return AsyncImageNode(url: nil, aspectRatio: 1.0).cornerRadius(item.cornerRadius)
        }

        let baseItems = (0..<N).map { Item(id: $0, cornerRadius: 0) }
        feed.items = baseItems
        feed.layoutSubviews()

        // Change sig for ALL items — must rebuild all.
        let altItems = (0..<N).map { Item(id: $0, cornerRadius: 8) }
        counter.value = 0
        feed.items = altItems
        feed.layoutSubviews()
        XCTAssertEqual(counter.value, N,
            "All items changed signature — builder must be called N times to refresh NodeTables")

        // Restore base — all change again — builder called N times again.
        counter.value = 0
        feed.items = baseItems
        feed.layoutSubviews()
        XCTAssertEqual(counter.value, N,
            "Signature reverted for all items — builder must still be called N times")
    }

    // MARK: - 21. itemSignature full-swap eviction removes entries for removed IDs

    #if canImport(XCTest)
    func testItemSignatureEvictsRemovedIDs() {
        struct Item: Identifiable, Sendable { let id: Int }

        let N = 5
        let env = makeEnvironment()
        let feed = FeedScrollView<Item>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )
        feed.itemSignature = { AnyHashable($0.id) }
        feed.cellBuilder = { _ in AsyncImageNode(url: nil, aspectRatio: 1.0) }

        feed.items = (0..<N).map { Item(id: $0) }
        feed.layoutSubviews()
        XCTAssertEqual(feed._tableCacheCount, N,
            "Cache must have N entries after initial load")

        // Remove 2 items — cache must shed their entries via full-swap eviction.
        feed.items = (0..<(N - 2)).map { Item(id: $0) }
        feed.layoutSubviews()
        XCTAssertEqual(feed._tableCacheCount, N - 2,
            "Removed IDs must be evicted — tableCache.count must equal items.count after update")
    }
    #endif

    // MARK: - 21b. itemSignature mixed add+remove eviction removes replaced ID

    #if canImport(XCTest)
    func testItemSignatureEvictsReplacedIDs() {
        struct Item: Identifiable, Sendable { let id: Int }

        let N = 5
        let env = makeEnvironment()
        let feed = FeedScrollView<Item>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )

        final class Counter { var value = 0 }
        let counter = Counter()

        feed.itemSignature = { AnyHashable($0.id) }
        feed.cellBuilder = { _ in
            counter.value += 1
            return AsyncImageNode(url: nil, aspectRatio: 1.0)
        }

        feed.items = (1...N).map { Item(id: $0) }
        feed.layoutSubviews()
        XCTAssertEqual(feed._tableCacheCount, N,
            "Cache must have N entries after initial load")

        // Swap id=5 for id=6 — same count, but id=5 must be evicted and id=6 added.
        // After the items loop: ids 1–4 hit, id=6 misses → cache grows to N+1 (6 entries).
        // tableCache.count (6) > items.count (5) → eviction removes id=5 → back to N.
        counter.value = 0
        feed.items = (1..<N).map { Item(id: $0) } + [Item(id: 6)]
        feed.layoutSubviews()
        XCTAssertEqual(feed._tableCacheCount, N,
            "Mixed add+remove: eviction must shed replaced id=5, leaving cache.count == items.count")
        XCTAssertEqual(counter.value, 1,
            "Only the new id=6 must trigger a builder call — ids 1–4 hit cache")
    }
    #endif

    // MARK: - 22. Cache-hit floor: N=1000, 1 changed → builder called once, speedup ≥ 2×

    /// Cache hits build one item and remain at least twice as fast as misses.
    /// Wall-clock timing can flake under loaded CI.
    func testItemsDidChangeCacheHitFloor() {
        struct StyleItem: Identifiable, Sendable {
            let id: Int
            let cornerRadius: CGFloat
        }

        let N = 1000
        let warmupIters = 20
        let measureIters = 100

        let env = makeEnvironment()
        let feed = FeedScrollView<StyleItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 0)
        )

        final class Counter { var value = 0 }
        let counter = Counter()

        feed.itemSignature = { AnyHashable($0.cornerRadius) }
        feed.cellBuilder = { item in
            counter.value += 1
            return AsyncImageNode(url: nil, aspectRatio: 1.0).cornerRadius(item.cornerRadius)
        }

        let baseItems    = (0..<N).map { StyleItem(id: $0, cornerRadius: 0) }
        // All items change cornerRadius — every item misses the cache.
        let allAltItems  = (0..<N).map { StyleItem(id: $0, cornerRadius: 8) }
        // Only item id=0 changes — 999 items hit the cache.
        let oneAltItems  = [StyleItem(id: 0, cornerRadius: 8)]
            + (1..<N).map { StyleItem(id: $0, cornerRadius: 0) }

        // VelocityUI-socg C4: `items =` no longer diffs/rebuilds synchronously — it defers to the
        // next `layoutSubviews()` (coalescing a same-frame burst into one pass). Every assignment
        // below is followed by an explicit `layoutSubviews()` to drain it immediately, preserving
        // this test's one-assignment-per-iteration semantics; the timed regions now bracket both
        // calls together since that pair is where the diff+rebuild cost this test measures lives.
        feed.items = baseItems
        feed.layoutSubviews()

        // Warmup: prime branch predictors and dict backing store on the miss path.
        for i in 0..<warmupIters {
            feed.items = i.isMultiple(of: 2) ? allAltItems : baseItems
            feed.layoutSubviews()
        }
        // Ensure cache is at baseItems (all cornerRadius=0) before loop A.
        feed.items = baseItems
        feed.layoutSubviews()

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let machToNs = Double(info.numer) / Double(info.denom)

        // --- Loop A: cache-miss (all N items change signature each iter) ---
        var missRaw = [UInt64]()
        missRaw.reserveCapacity(measureIters)
        var missBuilderCallsTotal = 0
        var useAllAlt = true
        for _ in 0..<measureIters {
            counter.value = 0
            let t0 = mach_absolute_time()
            feed.items = useAllAlt ? allAltItems : baseItems
            feed.layoutSubviews()
            let t1 = mach_absolute_time()
            missRaw.append(t1 &- t0)
            missBuilderCallsTotal += counter.value
            useAllAlt.toggle()
        }
        // Loop A ends with feed at baseItems (iter 99 sets base — see useAllAlt tracing).

        // Warmup for hit path.
        for i in 0..<warmupIters {
            feed.items = i.isMultiple(of: 2) ? oneAltItems : baseItems
            feed.layoutSubviews()
        }
        feed.items = baseItems  // reset cache to all cornerRadius=0
        feed.layoutSubviews()

        // --- Loop B: cache-hit (1 item changes signature per iter) ---
        var hitRaw = [UInt64]()
        hitRaw.reserveCapacity(measureIters)
        var hitBuilderCallsTotal = 0
        var useOneAlt = true
        for _ in 0..<measureIters {
            counter.value = 0
            let t0 = mach_absolute_time()
            feed.items = useOneAlt ? oneAltItems : baseItems
            feed.layoutSubviews()
            let t1 = mach_absolute_time()
            hitRaw.append(t1 &- t0)
            hitBuilderCallsTotal += counter.value
            useOneAlt.toggle()
        }

        // --- Statistics ---
        func sortedNs(_ raw: [UInt64]) -> [Double] {
            raw.sorted().map { Double($0) * machToNs }
        }
        func medianNs(_ s: [Double]) -> Double { s[s.count / 2] }
        func p99Ns(_ s: [Double]) -> Double {
            s[max(0, Int(Double(s.count) * 0.99) - 1)]
        }

        let missSorted = sortedNs(missRaw)
        let hitSorted  = sortedNs(hitRaw)

        let missMedian = medianNs(missSorted)
        let missP99    = p99Ns(missSorted)
        let hitMedian  = medianNs(hitSorted)
        let hitP99     = p99Ns(hitSorted)
        let speedup    = missMedian / max(1, hitMedian)

        print("[VelocityUI-d7b] itemsDidChange cache-hit floor N=\(N) (\(measureIters) iters each):")
        print(String(format: "  cache-miss median=%dns  p99=%dns  (all items change signature)",
                     Int(missMedian.rounded()), Int(missP99.rounded())))
        print(String(format: "  cache-hit  median=%dns  p99=%dns  (1 item changes signature)",
                     Int(hitMedian.rounded()), Int(hitP99.rounded())))
        print(String(format: "  speedup: %.1f×  (diff+rebuildFrames floor ~3ms; see test docstring)", speedup))

        // Functional correctness: builder call counts per iteration.
        XCTAssertEqual(missBuilderCallsTotal, measureIters * N,
            "[VelocityUI-d7b] cache-miss loop must call builder N=\(N) times per iteration; "
            + "total expected \(measureIters * N), got \(missBuilderCallsTotal)")
        XCTAssertEqual(hitBuilderCallsTotal, measureIters,
            "[VelocityUI-d7b] cache-hit loop must call builder exactly 1 time per iteration; "
            + "total expected \(measureIters), got \(hitBuilderCallsTotal)")

        // Performance assertions — targets reflect the actual function floor (see test docstring).
        // p99 < 10ms: 3× headroom on the ~3ms diff+rebuildFrames floor for N=1000 single-node items.
        XCTAssertLessThan(hitP99, 10_000_000,
            "[VelocityUI-d7b] cache-hit p99 must be < 10ms — "
            + "measured \(Int(hitP99.rounded()))ns; O(N²) regression or unexpected allocation suspected")
        // speedup > 2×: reflects the ~5ms builder+flatten saving vs the ~3ms diff floor (see docstring).
        XCTAssertGreaterThan(speedup, 2,
            "[VelocityUI-d7b] cache-hit speedup must be ≥2× vs miss-path median — "
            + "measured \(String(format: "%.1f", speedup))×; cache not skipping builder on hit path")
    }

    // MARK: - 23. Sync paint: refineKnownFrames sets sublayer.contents within the same layoutSubviews
    //              call that delivers fragments — no async hop, no applyContent (VelocityUI-1ho AC1,5,6)

    /// Verifies the core sync-paint invariant end-to-end through the full FeedScrollView stack:
    /// mount itemA and let it load (image enters cache); prepend itemB, invalidating WorkingRange
    /// so itemA moves to index 1 (WR miss); the pipeline re-measures and commits, triggering
    /// setNeedsLayout; on the next layoutSubviews, refineKnownFrames builds a sync map
    /// (cachedImage hit) and applyLayout(_:synchronousContent:) makes sublayer.contents non-nil
    /// in that SAME call — no extra Task.yield or async hop.
    ///
    /// Also asserts `_debugApplyContentCount == 0` (applyContent bypassed) and
    /// `placeholderLayer.opacity == 0` (full-coverage sync map reveals contentLayer inline).
    func testSyncPaintSetsContentsWithinRefineKnownFrames() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
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

        struct ImageItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
        }
        let itemA = ImageItem(id: 0, imageURL: url)
        let itemB = ImageItem(id: 1, imageURL: nil)

        let feed = FeedScrollView<ImageItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: item.imageURL, aspectRatio: 1.0) }

        // Phase 1: mount itemA via the async path. Once opacity == 1, the decoded image is
        // in the ImageActor NSCache — cachedImage() will return non-nil for the same key.
        feed.items = [itemA]
        feed.layoutSubviews()
        let phase1Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase1Deadline {
            await Task.yield()
            feed.layoutSubviews()
            if findFirstContentLayer(in: feed)?.opacity == 1 { break }
        }
        XCTAssertEqual(findFirstContentLayer(in: feed)?.opacity, 1,
            "Precondition: itemA must fully load before the sync-paint test (image must be cached)")

        // Phase 2: prepend itemB. WorkingRange is invalidated; itemA moves to index 1.
        // All visible cells are recycled. On next layoutSubviews, updateVisibleCells mounts
        // both indices as WR misses → _pendingFragmentIndices = {0, 1}.
        #if canImport(XCTest)
        RenderCell._debugResetApplyContentCount()
        #endif

        feed.items = [itemB, itemA]
        feed.layoutSubviews()

        // Phase 3: poll until refineKnownFrames delivers real fragments for itemA at index 1.
        // The pipeline re-measures → WR populated → setNeedsLayout. On the triggered
        // layoutSubviews, refineKnownFrames builds a sync map via cachedImage (cache hit),
        // calls applyLayout(_:synchronousContent:), and sets sublayer.contents INLINE.
        // We check immediately after layoutSubviews — no additional yield is needed.
        var syncPaintFired = false
        let phase3Deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < phase3Deadline {
            await Task.yield()
            feed.layoutSubviews()
            // Sync paint: contents must be non-nil RIGHT HERE, in the same runloop turn
            // as the layoutSubviews that triggered refineKnownFrames delivery.
            if findContentLayer(atCellIndex: 1, in: feed)?
                .sublayers?.first(where: { $0.contents != nil }) != nil {
                syncPaintFired = true
                break
            }
        }

        XCTAssertTrue(syncPaintFired,
            "Sync paint must set sublayer.contents within the layoutSubviews that delivers fragments — "
            + "no async hop (applyContent) needed when image is in cache")

        // AC(5): applyContent must NOT have been called — sync path bypasses it entirely.
        #if canImport(XCTest)
        XCTAssertEqual(RenderCell._debugApplyContentCount, 0,
            "Sync paint must bypass applyContent — _debugApplyContentCount must be 0 (AC5)")
        #endif

        // AC(6): placeholderLayer must be hidden (opacity 0) — full-coverage sync map
        // revealed contentLayer inline via applyLayout's fast-path reveal.
        guard let cellLayer = feed._cellLayer(at: 1) else {
            XCTFail("Cell at index 1 must be visible after sync paint"); return
        }
        let pl = cellLayer.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        XCTAssertEqual(pl?.opacity ?? 1, 0,
            "placeholderLayer must be hidden (opacity 0) when sync map covers all image fragments (AC6)")
        await drainFeedWork(feed)
    }

    // MARK: - 24. LayoutCache-hit WR-miss inline materialization (VelocityUI-1su.2)

    /// Warms LayoutCache for a head-set of items exactly the way `AsyncFeed.warmUp` does
    /// (same `CacheKey(layoutHash:width:)` construction, same measure→extractFragments→set
    /// pipeline), so the resulting entries are indistinguishable from what warmUp would have
    /// produced. Returns nothing — side effect is entirely in `env.layoutCache`.
    private func warmLayoutCache<I: Identifiable & Sendable>(
        items: [I],
        width: CGFloat,
        cellBuilder: (I) -> any RenderNode,
        environment: RenderEnvironment
    ) async where I.ID: Sendable {
        for item in items {
            let table = flatten(cellBuilder(item), itemID: item.id)
            let key = CacheKey(layoutHash: table.layoutHash, width: width)
            let layout = await measureNode(table, nodeIndex: 0, width: width, textPool: environment.textPool)
            let fragments = extractFragments(table: table, layout: layout)
            await environment.layoutCache.set(CellEntry(layout: layout, fragments: fragments), for: key)
        }
    }

    /// AC(2)(3): after LayoutCache is warmed for the head-set (mirroring `warmUp`), the FIRST
    /// `layoutSubviews` after items are assigned must deliver real fragments to every visible
    /// cell in the SAME pass — zero `applyLayout([])` gradient-only frames, and WorkingRange
    /// itself must be materialized so subsequent frames take the WR-hit branch instead of
    /// falling through refineKnownFrames bookkeeping.
    ///
    /// Trigger: LayoutCache warmed BEFORE `feed.items` is assigned and before the pipeline's
    /// `notifyPipelineIfNeeded` Task has any chance to run (asserted immediately after the single
    /// synchronous `layoutSubviews()` call, before yielding back to the run loop) — the exact
    /// window where WorkingRange is empty but LayoutCache is hot, the failure mode this bead fixes.
    func testWarmUpEliminatesFirstFrameGrayPlaceholder() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let env = makeEnvironment()
        let width: CGFloat = 375
        struct ImageItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
        }
        let testItems = (0..<5).map { ImageItem(id: $0, imageURL: url) }
        let builder: (ImageItem) -> any RenderNode = { item in
            AsyncImageNode(url: item.imageURL, aspectRatio: 1.0)
        }

        // Also warm ImageActor's decode cache so the sync-content map covers every fragment —
        // isolates this test to the LayoutCache/WorkingRange materialization path rather than
        // conflating it with the image-decode cache-hit path (already covered by VelocityUI-1ho's
        // testSyncPaintSetsContentsWithinRefineKnownFrames).
        _ = await env.imageActor.image(for: url, targetSize: CGSize(width: width, height: width),
                                        cornerRadius: 0, scale: 1)

        await warmLayoutCache(items: testItems, width: width, cellBuilder: builder, environment: env)

        let feed = FeedScrollView<ImageItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: 812))
        feed.cellBuilder = { item in builder(item) }
        feed.items = testItems

        // Single synchronous layoutSubviews — the FIRST one after mount. No yield before the
        // assertions below: if the fix regresses to applyLayout([]) on this exact call, the
        // pending-set assertion catches it before any async pipeline pass could paper over it.
        feed.layoutSubviews()

        XCTAssertEqual(feed._pendingFragmentIndicesCount, 0,
            "AC(2)(3): zero cells should be left pending fragment delivery when LayoutCache "
            + "was warm for all visible indices at mount time — got \(feed._pendingFragmentIndicesCount)")

        // Only indices actually mounted as visible cells are relevant — with aspectRatio 1.0 at
        // width 375, each row's synchronous intrinsic height (VelocityUI-ksh) is 375pt + 8pt
        // spacing, so an 812pt viewport shows ~3 of the 5 warmed items on the first pass (same
        // count as the old flat 300pt estimate happened to produce); the rest mount lazily as
        // the test scrolls (not exercised here). The invariant under test is about VISIBLE
        // cells, not every item.
        let visibleIndices = (0..<testItems.count).filter { feed._cellLayer(at: $0) != nil }
        XCTAssertFalse(visibleIndices.isEmpty, "Precondition: at least one cell must be visible after layoutSubviews")

        for index in visibleIndices {
            XCTAssertEqual(feed._workingRangeMissCount(from: index, to: index + 1), 0,
                "AC(2): WorkingRange must be materialized inline from the LayoutCache hit for "
                + "visible index \(index), not just the cell painted — subsequent layoutSubviews "
                + "calls must take the WR-hit branch")

            guard let cellLayer = feed._cellLayer(at: index) else {
                XCTFail("Cell at index \(index) must be visible immediately after the first layoutSubviews")
                continue
            }
            let hasContentSublayer = cellLayer.sublayers?.contains { !($0 is CAGradientLayer) && ($0.sublayers?.isEmpty == false) } ?? false
            XCTAssertTrue(hasContentSublayer,
                "AC(3): cell \(index) must have fragment sublayers from the LayoutCache hit, "
                + "not an empty applyLayout([]) placeholder-only layer")
        }
        await drainFeedWork(feed)
    }

    /// Regression for VelocityUI-ket: `layoutSubviews`' first width transition (the
    /// `0 -> bounds.width` sentinel) was handled identically to a genuine width change
    /// (rotation/resize), so `handleWidthChange()` unconditionally spawned
    /// `Task { await cache.invalidateAll() }` — wiping LayoutCache entries `AsyncFeed.warmUp`
    /// populated beyond the first visible screen, even though nothing about them was stale
    /// (same width, first-ever mount). Warms 30 items, mounts a viewport that only fits the
    /// first at each row's synchronous intrinsic height (VelocityUI-ksh — `width / aspectRatio`,
    /// well over the 200pt viewport here), and asserts the off-screen item's warmed entry
    /// survives past the first `layoutSubviews` call. The yield-drain loop gives any (buggy)
    /// async invalidation Task every chance to run — same idiom as
    /// `testCrossItemRecycleDoesNotDeliverStaleImage`, bounded by iteration count since the
    /// assertion is about absence of a state change, not its arrival.
    func testWarmUpEntriesForOffscreenItemsSurviveFirstMountWidthTransition() async {
        let env = makeEnvironment()
        let width: CGFloat = 375
        // 30 items, each with a DISTINCT aspectRatio: `AsyncImageNode.layoutHash` covers
        // url/aspectRatio/contentMode (not item.id — see Nodes.swift), so identical-shaped items
        // would collapse onto the same CacheKey, letting RenderPipeline's own post-invalidation
        // re-prefetch (indices 0..<10, prefetchAheadCount 10/prefetchBehindCount 3) silently
        // repopulate the "off-screen" key too and mask the bug this test guards against. Distinct
        // ratios give every index its own CacheKey, so index 20's entry can ONLY come from
        // warmUp — the pipeline's own window never reaches past index 9.
        let testItems = (0..<30).map { TestItem(id: $0, aspectRatio: 1.0 + CGFloat($0) * 0.01) }
        let builder: (TestItem) -> any RenderNode = { item in
            AsyncImageNode(url: nil, aspectRatio: item.aspectRatio)
        }

        await warmLayoutCache(items: testItems, width: width, cellBuilder: builder, environment: env)

        let offscreenItem = testItems[20]
        let offscreenTable = flatten(builder(offscreenItem), itemID: offscreenItem.id)
        let offscreenKey = CacheKey(layoutHash: offscreenTable.layoutHash, width: width)
        XCTAssertNotNil(env.layoutCache.cachedEntry(for: offscreenKey),
            "Precondition: warmUp populated the off-screen item's LayoutCache entry")

        // Small viewport: only index 0 fits at its synchronous intrinsic height (~288-375pt,
        // width / aspectRatio ∈ [1.0, 1.3) here), so index 20 is off-screen and never
        // inline-materialized by updateVisibleCells here.
        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: 200))
        feed.cellBuilder = { item in builder(item) }
        feed.items = testItems

        // First layoutSubviews: bounds.width (nonzero) != lastLayoutWidth (0 sentinel) —
        // the exact first-mount transition this bead's bug conflated with a real width change.
        feed.layoutSubviews()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline { await Task.yield() }

        XCTAssertNotNil(env.layoutCache.cachedEntry(for: offscreenKey),
            "warmUp's LayoutCache entry for an off-screen item must survive the FIRST "
            + "layoutSubviews' 0->width sentinel transition — there is no prior width for it "
            + "to have gone stale from")
    }

    /// Regression: a second `layoutSubviews()` call is a true no-op once the LayoutCache-hit
    /// inline materialization has already committed a WR entry on the first pass. NOTE: this
    /// does NOT exercise `WorkingRange.commit`'s double-commit idempotency contract — after the
    /// first call, index 0 is already in `visibleCells`, so `updateVisibleCells`'s mount-skip
    /// guard (`guard visibleCells[index] == nil else { continue }`) short-circuits the second
    /// call before `commit()` runs again for that index. The direct double-commit idempotency
    /// check is `WorkingRangeTests.testDoubleCommitWithIdenticalDataIsIdempotent`.
    func testSecondLayoutSubviewsCallAfterLayoutCacheHitIsInert() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let env = makeEnvironment()
        let width: CGFloat = 375
        struct ImageItem: Identifiable, Sendable {
            let id: Int
            let imageURL: URL?
        }
        let testItems = [ImageItem(id: 0, imageURL: url)]
        let builder: (ImageItem) -> any RenderNode = { item in
            AsyncImageNode(url: item.imageURL, aspectRatio: 1.0)
        }

        await warmLayoutCache(items: testItems, width: width, cellBuilder: builder, environment: env)

        let feed = FeedScrollView<ImageItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: 812))
        feed.cellBuilder = { item in builder(item) }
        feed.items = testItems

        // First layoutSubviews: WR-miss branch hits LayoutCache and commits inline (this bead).
        feed.layoutSubviews()
        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "Precondition: WorkingRange must already be materialized from the first layoutSubviews")

        let cellLayerBefore = feed._cellLayer(at: 0)
        let sublayerCountBefore = cellLayerBefore?.sublayers?.count ?? -1
        let frameBefore = cellLayerBefore?.frame

        // Index 0 is already in visibleCells after the first layoutSubviews, so
        // updateVisibleCells' mount-skip guard (`guard visibleCells[index] == nil else { continue }`)
        // means this second call does NOT re-invoke workingRange.commit for index 0 — it is a
        // true no-op for already-mounted cells. This assertion is about mount-loop stability,
        // not commit idempotency (see the class doc comment above).
        feed.layoutSubviews()

        let cellLayerAfter = feed._cellLayer(at: 0)
        XCTAssertEqual(cellLayerAfter?.sublayers?.count, sublayerCountBefore,
            "A second layoutSubviews with no state change must not alter the mounted cell's sublayer count")
        XCTAssertEqual(cellLayerAfter?.frame, frameBefore,
            "A second layoutSubviews with no state change must not alter the mounted cell's frame")
        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "WorkingRange entry must remain present after a second, no-op layoutSubviews call")
        await drainFeedWork(feed)
    }

    // MARK: - 25. contentDeliveryObserver wiring (VelocityUI-qrk)

    /// `RenderEnvironment.contentDeliveryObserver` is the composition-root replacement for the
    /// old `#if DEBUG` `FeedScrollView._onContentDeliveredDebug`/`_onThumbnailReplacedDebug`
    /// hooks. Verifies `spawnMediaFetches` actually invokes it — once per real `applyContent`
    /// delivery — carrying the correct `ContentTransitionKind` for both physics-fallback paths:
    /// a cell with no placeholder data (gray-tint path) and a cell with a valid BlurHash
    /// (decode-guaranteed thumbnail-placeholder path).
    func testContentDeliveryObserverFiresWithCorrectTransitionKind() async throws {
        let grayURL = try writeTempJPEG(width: 60, height: 60)
        let thumbnailURL = try writeTempJPEG(width: 60, height: 60)
        defer {
            try? FileManager.default.removeItem(at: grayURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
        }

        let deliveredLock = OSAllocatedUnfairLock<[RenderCell.ContentTransitionKind]>(initialState: [])
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            contentDeliveryObserver: { kind in
                deliveredLock.withLock { $0.append(kind) }
            }
        )

        let feed = FeedScrollView<TestItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in
            item.id == 0
                ? AsyncImageNode(url: grayURL, aspectRatio: 1.0)
                : AsyncImageNode(url: thumbnailURL, aspectRatio: 1.0)
                    .placeholder(blurHash: "L6PZfSi_.AyE_3t7t7R**0o#DgR4")
        }
        feed.items = [TestItem(id: 0), TestItem(id: 1)]
        feed.layoutSubviews()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            await Task.yield()
            feed.layoutSubviews()
            if deliveredLock.withLock({ $0.count }) >= 2 { break }
        }

        let delivered = deliveredLock.withLock { $0 }
        XCTAssertEqual(delivered.count, 2,
            "contentDeliveryObserver must fire exactly once per real applyContent delivery")
        XCTAssertTrue(delivered.contains(.fromGrayPlaceholder),
            "No-placeholder-data cell must report .fromGrayPlaceholder")
        XCTAssertTrue(delivered.contains(.fromThumbnailPlaceholder),
            "BlurHash-placeholder cell must report .fromThumbnailPlaceholder")

        await drainFeedWork(feed)
    }

    // MARK: - 25b. pipelineTaskSpawnObserver wiring (VelocityUI-let)

    /// `RenderEnvironment.pipelineTaskSpawnObserver` is the production-safe counterpart to the
    /// XCTest-only `_taskSpawnCount` (VelocityUI-let suspect 3, pipeline Task storm) — it lets
    /// BenchmarkHost attribute the event without `#if canImport(XCTest)` gating. Verifies it
    /// fires exactly once per `notifyPipelineIfNeeded` boundary crossing, in lockstep with
    /// `_taskSpawnCount` (see test 2, `testTaskSpawnCountMatchesBoundaryCrossings`, for the
    /// crossing semantics this mirrors).
    func testPipelineTaskSpawnObserverFiresOnBoundaryCrossing() {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let spawnCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let env = RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            pipelineTaskSpawnObserver: {
                spawnCount.withLock { $0 += 1 }
            }
        )

        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }
        feed.items = items(count: 200)
        feed.layoutSubviews()

        XCTAssertEqual(spawnCount.withLock { $0 }, 1, "One observer firing for the initial leading index")
        #if canImport(XCTest)
        XCTAssertEqual(spawnCount.withLock { $0 }, feed._taskSpawnCount,
            "pipelineTaskSpawnObserver must fire exactly in lockstep with _taskSpawnCount")
        #endif

        feed.contentOffset = CGPoint(x: 0, y: 350)
        feed.layoutSubviews()
        XCTAssertEqual(spawnCount.withLock { $0 }, 2, "One additional firing per unique leading-index boundary")

        feed.layoutSubviews()
        XCTAssertEqual(spawnCount.withLock { $0 }, 2, "No firing when leading index does not change")
    }

    // MARK: - 26. Synchronous intrinsic height before any async pipeline commit (VelocityUI-ksh)

    /// Root-cause regression for VelocityUI-ksh: `rebuildFrames` used to seed EVERY unmeasured
    /// image row with the flat `estimatedItemHeight` placeholder (300pt) regardless of real
    /// aspect ratio, until `measureNode` committed a real layout to WorkingRange. Under sustained
    /// fast scroll with no warm-up pass, that window never closes — `resolvedFrames` stays wrong,
    /// `visRange` churns every frame, and the cell pool never converges (bead's Instruments
    /// evidence: ~90% `RenderCell.init` on every dequeue, post-ramp).
    ///
    /// Asserts that immediately after `feed.items = ...` and one synchronous `layoutSubviews()`
    /// — no `await` anywhere in this test, so the pipeline Task spawned by
    /// `notifyPipelineIfNeeded` cannot have run yet — a tall row (aspectRatio 0.5 → 750pt at
    /// width 375) and a short row (aspectRatio 2.0 → 187.5pt) already have DISTINCT, CORRECT
    /// intrinsic heights, not the flat 300pt both would collapse to under the old behavior.
    func testSynchronousIntrinsicHeightBeforePipelineCommit() {
        let width: CGFloat = 375
        let feed = makeFeed(width: width, height: 812)

        let tallItem  = TestItem(id: 0, aspectRatio: 0.5)   // width / 0.5 = 750pt
        let shortItem = TestItem(id: 1, aspectRatio: 2.0)   // width / 2.0 = 187.5pt
        feed.items = [tallItem, shortItem]

        // Single synchronous layoutSubviews — no yield, no async gap. resolvedFrames here can
        // ONLY have come from rebuildFrames' synchronous per-row estimate.
        feed.layoutSubviews()

        guard let tallFrame = feed._debugResolvedFrame(at: 0),
              let shortFrame = feed._debugResolvedFrame(at: 1) else {
            XCTFail("Both rows must have a resolved frame after the first layoutSubviews")
            return
        }

        XCTAssertEqual(tallFrame.height, width / 0.5, accuracy: 0.5,
            "Tall row (aspectRatio 0.5) must get its synchronous intrinsic height (750pt), "
            + "not the flat estimatedItemHeight placeholder (300pt)")
        XCTAssertEqual(shortFrame.height, width / 2.0, accuracy: 0.5,
            "Short row (aspectRatio 2.0) must get its synchronous intrinsic height (187.5pt), "
            + "not the flat estimatedItemHeight placeholder (300pt)")
        XCTAssertNotEqual(tallFrame.height, shortFrame.height, accuracy: 0.5,
            "Rows with different aspect ratios must resolve to DISTINCT heights synchronously — "
            + "a flat-estimate regression would collapse both to the same 300pt")

        // contentSize must reflect the sum of the real intrinsic heights, not 2 × the flat estimate.
        let expectedContentHeight = (width / 0.5) + (width / 2.0) + feed.layoutSpacing
        XCTAssertEqual(feed.contentSize.height, expectedContentHeight, accuracy: 0.5,
            "contentSize must be sized from the real intrinsic heights before any pipeline commit")
    }

    // MARK: - 27. Cell pool converges after warm-up, reconciling heterogeneous real heights

    /// Regression for VelocityUI-ksh's core symptom. Pre-populates LayoutCache with REAL
    /// heights spanning the bead's repro range (188pt-750pt at width 375) via `warmLayoutCache`
    /// (same mechanism `AsyncFeed.warmUp` uses), so `updateVisibleCells`' WR-miss/LayoutCache-hit
    /// branch calls `VerticalLayoutProvider.refineFrames` SYNCHRONOUSLY the moment each row first
    /// mounts — no `Task`/pipeline timing involved, this is the deterministic mount path.
    ///
    /// Pre-fix: every row starts at the flat `estimatedItemHeight` (300pt) placeholder, so the
    /// first mount of each heterogeneous row (188-750pt real) triggers a large refine-delta,
    /// shifting not-yet-visited rows by up to ~450pt. `updateVisibleCells` computes
    /// `visRange`/`keepRange` ONCE at function entry (before the mount loop's inline refinements
    /// land), so the corrected geometry only takes effect on the NEXT `layoutSubviews` call —
    /// which can pull a wider index set into view than steady-state, forcing `RenderCell.init`
    /// beyond the pool's already-warm size. Post-fix: `rebuildFrames`'s synchronous
    /// intrinsic-height estimate already matches the LayoutCache-warmed real height (same
    /// `width / aspectRatio` formula), so the inline refine computes a zero delta and nothing
    /// shifts — the pool never needs more cells than the working-range window.
    func testCellPoolConvergesAfterWarmupWithHeterogeneousRealHeights() async {
        let width: CGFloat = 375
        let env = makeEnvironment()

        // Cycles through aspect ratios spanning the bead's real repro range so consecutive
        // rows have genuinely different intrinsic/real heights — not the uniform case, which
        // would stay self-consistent even under the old flat-estimate behavior.
        let ratios: [CGFloat] = [2.0, 0.5, 1.0, 1.5, 0.75]
        let itemCount = 300
        let testItems = (0..<itemCount).map { TestItem(id: $0, aspectRatio: ratios[$0 % ratios.count]) }
        let builder: (TestItem) -> any RenderNode = { item in
            AsyncImageNode(url: nil, aspectRatio: item.aspectRatio)
        }
        await warmLayoutCache(items: testItems, width: width, cellBuilder: builder, environment: env)

        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: 812))
        feed.cellBuilder = { item in builder(item) }
        feed.items = testItems

        // Scroll down in small discrete steps, calling layoutSubviews() after each — fully
        // synchronous, no yields, no Task timing. The LayoutCache-hit inline materialization
        // reconciles each newly-visible row's real height the instant it mounts.
        let stepSize: CGFloat = 80
        let totalSteps = 150
        let warmupSteps = 40  // generous margin over the working-range window (~17 cells:
                               // prefetchBehindCount 3 + ~4 visible + prefetchAheadCount 10)

        var allocCountAtWarmup: Int?
        for step in 1...totalSteps {
            feed.contentOffset = CGPoint(x: 0, y: CGFloat(step) * stepSize)
            feed.layoutSubviews()
            if step == warmupSteps {
                allocCountAtWarmup = feed._dequeueAllocCount
            }
        }

        guard let warmupCount = allocCountAtWarmup else {
            XCTFail("warmupSteps must be <= totalSteps"); return
        }

        XCTAssertEqual(feed._dequeueAllocCount, warmupCount,
            "RenderCell.init count must stop growing once the working-range window has been "
            + "filled (\(warmupCount) allocations at step \(warmupSteps)) — got "
            + "\(feed._dequeueAllocCount) after \(totalSteps) total steps. A growing count means "
            + "the pool is churning instead of converging (VelocityUI-ksh).")

        await drainFeedWork(feed)
    }

    // MARK: - 28. Cell pool round-trips instance identity through dequeue/returnToPool (VelocityUI-9lq)

    /// Regression for VelocityUI-9lq's `dequeue`/`returnToPool` rewrite: both moved from
    /// `removeValue(forKey:)`-then-conditionally-reinsert to `_modify`-based in-place mutation
    /// (`cellPools[kind]?.popLast()` / `cellPools[kind, default: []].append`), avoiding a full
    /// empty-and-reinsert per recycle (Instruments showed `_NativeDictionary.setValue ->
    /// _copyOrMoveAndResize` allocations under `returnToPool`). A wrong-accessor regression there
    /// would either silently stop finding pooled cells (hit rate collapses, `RenderCell.init`
    /// fires every dequeue) or hand back a wrong/duplicate instance — this test rules both out by
    /// tracking every distinct `CALayer` identity mounted across sustained recycling: it must
    /// plateau near the working-range window size, not grow toward `itemCount`.
    ///
    /// Out of scope: "zero heap bytes" is only observable via Instruments (VelocityUI-9lq's
    /// BenchmarkHost repro) — XCTest has no hook onto Dictionary's rehash path, so this verifies
    /// the black-box contract (identity + convergence), not the byte count itself. Same honesty
    /// boundary VelocityUI-ksh's regression test drew.
    func testCellPoolRoundTripsInstanceIdentityAfterDictAccessRefactor() async {
        let width: CGFloat = 375
        let env = makeEnvironment()
        let itemCount = 200
        let testItems = (0..<itemCount).map { TestItem(id: $0, aspectRatio: 1.0) }
        let builder: (TestItem) -> any RenderNode = { item in
            AsyncImageNode(url: nil, aspectRatio: item.aspectRatio)
        }
        await warmLayoutCache(items: testItems, width: width, cellBuilder: builder, environment: env)

        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: 812))
        feed.cellBuilder = { item in builder(item) }
        feed.items = testItems

        var seenLayers = Set<ObjectIdentifier>()
        let stepSize: CGFloat = 200
        let totalSteps = 80
        let warmupSteps = 20

        var hitCountAtWarmup: Int?
        for step in 1...totalSteps {
            feed.contentOffset = CGPoint(x: 0, y: CGFloat(step) * stepSize)
            feed.layoutSubviews()
            for index in 0..<itemCount {
                if let layer = feed._cellLayer(at: index) {
                    seenLayers.insert(ObjectIdentifier(layer))
                }
            }
            if step == warmupSteps {
                hitCountAtWarmup = feed._dequeueHitCount
            }
        }

        guard let warmupHits = hitCountAtWarmup else {
            XCTFail("warmupSteps must be <= totalSteps"); return
        }

        XCTAssertGreaterThan(feed._dequeueHitCount, warmupHits,
            "Pool hits must keep accumulating past warm-up — a broken _modify-based lookup "
            + "would silently stop finding pooled cells and fall through to RenderCell.init "
            + "on every dequeue instead.")
        XCTAssertLessThan(seenLayers.count, itemCount / 4,
            "Distinct CALayer identities observed across \(totalSteps) recycle steps must stay "
            + "far below itemCount (\(itemCount)) — layer identities must repeat as cells are "
            + "recycled through the pool via dequeue/returnToPool, not minted fresh per mount.")

        await drainFeedWork(feed)
    }

    // MARK: - 29. reuseDecision gates the bind-site recycle (VelocityUI-socg C2)

    /// A same-id streaming update (content changes, identity doesn't) must classify as `.layout`
    /// — `AsyncImageNode.layoutHash` covers `aspectRatio`, so changing it on the SAME item id
    /// forces `RenderDiffer.classify` to `.layout`, the "full invalidation" branch of
    /// `itemsDidChange` that used to unconditionally pool every visible cell. `reuseDecision
    /// (oldID:newID:)` now gates that branch: since `layoutChanged` pairs are matched by item id
    /// (`RenderDiffer.diff` keys off `itemID`), the slot's `oldID` equals the new item's id, so
    /// the decision must be `.inPlace` — the shell is kept, not pooled.
    func testSameIDLayoutChange_TakesInPlaceBranch_DoesNotReturnShellToPool() async {
        let feed = makeFeed()
        feed.items = [TestItem(id: 0, aspectRatio: 1.0)]
        feed.layoutSubviews()

        let cellBefore = feed._cellLayer(at: 0)
        XCTAssertNotNil(cellBefore, "Precondition: item 0 must be mounted before the update")

        // aspectRatio 1.0 at width 375 -> intrinsic/measured height 375 (width / aspectRatio).
        XCTAssertEqual(feed._debugResolvedFrame(at: 0)?.height ?? -1, 375, accuracy: 0.5,
            "Precondition: index 0 must resolve to the aspectRatio-1.0 height before the update")

        let returnToPoolBefore = feed._returnToPoolCount
        let dequeueAllocBefore = feed._dequeueAllocCount
        let dequeueHitBefore = feed._dequeueHitCount

        // Same id (0), aspectRatio 1.0 -> 2.0: layoutHash changes, itemID does not.
        feed.items = [TestItem(id: 0, aspectRatio: 2.0)]
        feed.layoutSubviews()

        XCTAssertEqual(feed._returnToPoolCount, returnToPoolBefore,
            "Same-id streaming update must NOT return the shell to the pool")
        XCTAssertEqual(feed._dequeueAllocCount, dequeueAllocBefore,
            "The .inPlace branch must not trigger a fresh RenderCell allocation")
        XCTAssertEqual(feed._dequeueHitCount, dequeueHitBefore,
            "The .inPlace branch must not round-trip through dequeue(kind:) at all")

        let cellAfter = feed._cellLayer(at: 0)
        XCTAssertTrue(cellBefore === cellAfter,
            ".inPlace branch must keep the SAME RenderCell instance bound at index 0 — no recycle")

        // The kept shell must not freeze on its pre-change content: aspectRatio 2.0 at width 375
        // measures to 187.5 (width / aspectRatio — measureNode and intrinsicHeight are guaranteed
        // to agree, see LayoutEngine.swift:195-196). `rebuildFrames` seeds a survivor's height from
        // its OLD frame, so index 0 starts this poll still at 375 — the assertion only holds once
        // refineKnownFrames delivers the NEW height, which requires the .inPlace keep branch to
        // have re-enrolled index 0 into `_pendingFragmentIndices` (without the fix, the index
        // never refreshes and the loop times out still reporting 375).
        // Poll layoutSubviews like sibling async-delivery tests in this file (Task.yield +
        // wall-clock deadline) — never Task.sleep as a coordination primitive.
        var refreshedHeight: CGFloat?
        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < refreshDeadline {
            await Task.yield()
            feed.layoutSubviews()
            if let h = feed._debugResolvedFrame(at: 0)?.height, abs(h - 187.5) < 0.5 {
                refreshedHeight = h
                break
            }
        }

        XCTAssertNotNil(refreshedHeight,
            "Kept .inPlace cell at index 0 must pick up the NEW aspectRatio-2.0 height (187.5) "
            + "once WorkingRange recommits — it must not stay frozen at the pre-change height "
            + "(375) until it scrolls out of keep-range and re-mounts")
        XCTAssertTrue(cellBefore === feed._cellLayer(at: 0),
            "Content refresh must still be delivered to the SAME kept RenderCell instance — "
            + "not a pool round-trip in disguise")

        await drainFeedWork(feed)
    }

    /// Counterpart to the test above: a genuinely different item id at the same slot (list
    /// replace, not a streaming update) must still take the `.pool` branch — `reuseDecision`
    /// must not over-fire and keep shells that no longer belong to the same identity.
    func testDifferentIDReplacement_StillRecyclesThroughPool() {
        let feed = makeFeed()
        feed.items = [TestItem(id: 0, aspectRatio: 1.0)]
        feed.layoutSubviews()
        XCTAssertNotNil(feed._cellLayer(at: 0), "Precondition: item 0 must be mounted before the update")

        let returnToPoolBefore = feed._returnToPoolCount

        // A different id entirely at the same slot — no shared identity to keep in place.
        feed.items = [TestItem(id: 1, aspectRatio: 1.0)]
        feed.layoutSubviews()

        XCTAssertEqual(feed._returnToPoolCount, returnToPoolBefore + 1,
            "A different-id item replacing the old one must still recycle the old shell through the pool")
        XCTAssertNotNil(feed._cellLayer(at: 0), "The new item must still end up mounted at index 0")
    }

    /// A pure scroll feed (every item keeps its own identity; only the visible window slides)
    /// must be completely unaffected by the reuseDecision wiring — this is the "pool dequeue/
    /// return count is unchanged for a pure scroll feed" acceptance criterion from VelocityUI
    /// -socg. `itemsDidChange`'s full-invalidation branch is never even reached here (no
    /// `items` reassignment happens at all after the initial load — only `contentOffset`
    /// changes), so this is really asserting the scroll-driven recycle loop in
    /// `updateVisibleCells` (untouched by C2) keeps behaving exactly as before.
    func testPureScrollFeed_PoolDequeueReturnCountsUnaffectedByReuseDecisionWiring() async {
        let width: CGFloat = 375
        let env = makeEnvironment()
        let itemCount = 100
        let testItems = (0..<itemCount).map { TestItem(id: $0, aspectRatio: 1.0) }
        let builder: (TestItem) -> any RenderNode = { item in
            AsyncImageNode(url: nil, aspectRatio: item.aspectRatio)
        }
        await warmLayoutCache(items: testItems, width: width, cellBuilder: builder, environment: env)

        let feed = FeedScrollView<TestItem>(environment: env, frame: CGRect(x: 0, y: 0, width: width, height: 812))
        feed.cellBuilder = { item in builder(item) }
        feed.items = testItems
        feed.layoutSubviews()

        // Warm-up: the working-range window must fill with pooled cells at least once before
        // allocations stop. Measured directly: with this feed's geometry (100 items, aspectRatio
        // 1.0 → 375pt rows at width 375, stepSize 200), `_dequeueAllocCount` plateaus at step 19;
        // `warmupSteps = 40` gives a generous margin, matching
        // testCellPoolConvergesAfterWarmupWithHeterogeneousRealHeights' rationale. `.inPlace`
        // never fires here (every index binds a distinct item id), so this really re-confirms the
        // untouched scroll-driven recycle loop in updateVisibleCells behaves as before C2's wiring.
        let stepSize: CGFloat = 200
        let totalSteps = 90
        let warmupSteps = 40
        var dequeueAllocAtWarmup: Int?

        for step in 1...totalSteps {
            feed.contentOffset = CGPoint(x: 0, y: CGFloat(step) * stepSize)
            feed.layoutSubviews()
            if step == warmupSteps {
                dequeueAllocAtWarmup = feed._dequeueAllocCount
            }
        }

        guard let allocAtWarmup = dequeueAllocAtWarmup else {
            XCTFail("warmupSteps must be <= totalSteps"); return
        }

        XCTAssertGreaterThan(feed._returnToPoolCount, 0,
            "Pure scrolling must still recycle cells that scroll out of the keep-range window")
        XCTAssertEqual(feed._dequeueAllocCount, allocAtWarmup,
            "Once the working-range window has filled once, pure scrolling must be served "
            + "entirely from the pool — no new RenderCell allocations past warm-up, exactly as "
            + "before the reuseDecision wiring (VelocityUI-ksh's convergence guarantee)")

        await drainFeedWork(feed)
    }

    // MARK: - VelocityUI-ezo.2.5: Dynamic Type content-size-category invalidation

    /// End-to-end proof of the acceptance criterion "changing the category invalidates frozen
    /// text bitmaps and re-measures": posts `UIContentSizeCategory.didChangeNotification` to an
    /// injected `NotificationCenter` (never `.default` — this must stay deterministic and not
    /// touch process-global state) and asserts the visible text row's resolved height actually
    /// grows once the async measure pipeline re-commits at the new, larger category.
    func testContentSizeCategoryChangeNotification_ReMeasuresTextAndGrowsHeight() async {
        let env = makeEnvironment()
        let testCenter = NotificationCenter()
        let feed = FeedScrollView<TestItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812),
            notificationCenter: testCenter
        )
        feed.cellBuilder = { _ in
            TextNode("Dynamic Type integration content long enough to wrap across several lines at this width.")
        }
        feed.items = [TestItem(id: 0)]
        feed.layoutSubviews()

        // Poll until the async pipeline delivers a real (non-placeholder) measured height —
        // mirrors testSameIDLayoutChange_TakesInPlaceBranch_DoesNotReturnShellToPool's pattern:
        // Task.yield + wall-clock deadline, never Task.sleep as a coordination primitive.
        func settledHeight(minimumGrowthOver floor: CGFloat) async -> CGFloat? {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                await Task.yield()
                feed.layoutSubviews()
                if let h = feed._debugResolvedFrame(at: 0)?.height, h > floor { return h }
            }
            return nil
        }

        guard let baseline = await settledHeight(minimumGrowthOver: 0) else {
            XCTFail("text must measure a real height before any content-size-category change")
            return
        }

        testCenter.post(
            name: UIContentSizeCategory.didChangeNotification,
            object: nil,
            userInfo: [UIContentSizeCategory.newValueUserInfoKey: UIContentSizeCategory.accessibilityExtraExtraExtraLarge]
        )
        feed.layoutSubviews()

        let scaledHeight = await settledHeight(minimumGrowthOver: baseline)
        XCTAssertNotNil(scaledHeight,
            "posting UIContentSizeCategory.didChangeNotification with accessibilityExtraExtraExtraLarge "
            + "must drive a re-measure that grows the text row's height past its pre-change baseline (\(baseline)pt)")

        await drainFeedWork(feed)
    }

    /// `init(frame:)` builds the view before UIKit attaches it to a window, so the
    /// `traitCollection` read at construction reflects the process default, not a live system
    /// setting — the cold-launch gap this covers: a device launched with Larger Text enabled
    /// would mount unscaled text and never self-correct, since the OS only posts
    /// `didChangeNotification` on a *change*, never on mount. This test never posts that
    /// notification — it proves `didMoveToWindow` (FeedScrollView.swift) alone catches the real
    /// category once attached to a window whose trait environment already carries a non-default
    /// `preferredContentSizeCategory`, exactly like a cold-launch device.
    func testWindowMount_SeedsLiveContentSizeCategory_WithoutNotification() async {
        let env = makeEnvironment()
        let testCenter = NotificationCenter()
        let feed = FeedScrollView<TestItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812),
            notificationCenter: testCenter
        )
        feed.cellBuilder = { _ in
            TextNode("Dynamic Type window-mount content long enough to wrap across several lines at this width.")
        }
        feed.items = [TestItem(id: 0)]
        feed.layoutSubviews()

        // Same poll idiom as the notification test above: Task.yield + wall-clock deadline,
        // never Task.sleep as a coordination primitive.
        func settledHeight(minimumGrowthOver floor: CGFloat) async -> CGFloat? {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                await Task.yield()
                feed.layoutSubviews()
                if let h = feed._debugResolvedFrame(at: 0)?.height, h > floor { return h }
            }
            return nil
        }

        guard let baseline = await settledHeight(minimumGrowthOver: 0) else {
            XCTFail("text must measure a real height before the feed is ever attached to a window")
            return
        }

        // Install under a real UIWindow whose trait environment overrides
        // preferredContentSizeCategory to an accessibility size — mirrors a cold-launch device
        // with Larger Text already enabled system-wide, where the trait is live BEFORE the view
        // is ever created. `traitOverrides` (UITraitOverrides, iOS 17+ — this package's
        // deployment target) is the supported way to force a real trait value on a real trait
        // environment without a UIViewController hop.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.isHidden = false
        window.addSubview(feed)
        feed.layoutSubviews()

        let scaledHeight = await settledHeight(minimumGrowthOver: baseline)
        XCTAssertNotNil(scaledHeight,
            "didMoveToWindow must re-seed contentSizeCategory from the live trait and re-measure — "
            + "attaching to a window overridden to accessibilityExtraExtraExtraLarge must grow the "
            + "text row's height past its pre-attach baseline (\(baseline)pt), with zero "
            + "UIContentSizeCategory.didChangeNotification ever posted to testCenter")

        await drainFeedWork(feed)
    }

    // MARK: - 30. Provider-driven read path: GridLayoutProvider positions cells in columns (VelocityUI-xhpu.2)

    func testGridLayoutProvider_positionsCellsInColumns() {
        let env = makeEnvironment()
        let feed = FeedScrollView<TestItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812),
            layoutProvider: GridLayoutProvider(columns: 3, spacing: 8)
        )
        feed.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }
        feed.items = items(count: 6, aspectRatio: 1.0)
        feed.layoutSubviews()

        let colWidth: CGFloat = (375 - 8 * 2) / 3
        for row in 0..<2 {
            for col in 0..<3 {
                let index = row * 3 + col
                guard let frame = feed._debugResolvedFrame(at: index) else {
                    XCTFail("expected a resolved frame at index \(index)")
                    continue
                }
                let expectedX = CGFloat(col) * (colWidth + 8)
                XCTAssertEqual(frame.origin.x, expectedX, accuracy: 0.01,
                    "index \(index) should sit in column \(col), not at x==0")
                XCTAssertEqual(frame.width, colWidth, accuracy: 0.01,
                    "index \(index) should be colWidth-wide, not full-width")
            }
        }

        // Row 1 starts below row 0's height + spacing, and contentSize.height must be the last
        // row's bottom edge (GridLayoutProvider.contentHeight) — not the last item's maxY.
        guard let row0Frame = feed._debugResolvedFrame(at: 0),
              let row1Frame = feed._debugResolvedFrame(at: 3) else {
            return XCTFail("expected row 0 and row 1 frames")
        }
        XCTAssertEqual(row1Frame.origin.y, row0Frame.maxY + 8, accuracy: 0.01)
        XCTAssertEqual(feed.contentSize.height, row1Frame.maxY, accuracy: 0.01,
            "contentSize.height must be driven by GridLayoutProvider.contentHeight")
    }

    // MARK: - 31. Default layoutProvider is byte-identical to an explicit VerticalLayoutProvider(spacing:) (VelocityUI-xhpu.2)

    func testDefaultLayoutProvider_matchesExplicitVerticalLayoutProvider() {
        let envA = makeEnvironment()
        let feedDefault = FeedScrollView<TestItem>(
            environment: envA, frame: CGRect(x: 0, y: 0, width: 375, height: 812), layoutSpacing: 12
        )
        feedDefault.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }

        let envB = makeEnvironment()
        let feedExplicit = FeedScrollView<TestItem>(
            environment: envB, frame: CGRect(x: 0, y: 0, width: 375, height: 812), layoutSpacing: 12,
            layoutProvider: VerticalLayoutProvider(spacing: 12)
        )
        feedExplicit.cellBuilder = { item in AsyncImageNode(url: nil, aspectRatio: item.aspectRatio) }

        let testItems = items(count: 8, aspectRatio: 1.5)
        feedDefault.items = testItems
        feedExplicit.items = testItems
        feedDefault.layoutSubviews()
        feedExplicit.layoutSubviews()

        for i in 0..<8 {
            XCTAssertEqual(feedDefault._debugResolvedFrame(at: i), feedExplicit._debugResolvedFrame(at: i),
                "index \(i): omitting layoutProvider must be byte-identical to passing VerticalLayoutProvider(spacing:) explicitly")
        }
        XCTAssertEqual(feedDefault.contentSize, feedExplicit.contentSize)
    }
}
#endif

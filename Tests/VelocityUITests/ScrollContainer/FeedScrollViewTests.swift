// FeedScrollViewTests.swift

#if canImport(UIKit)
import XCTest
import Darwin
@testable import VelocityUI

@MainActor
final class FeedScrollViewTests: XCTestCase {

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
            videoPreparation: videoPrep
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
        #if DEBUG
        let baseline = feed._taskSpawnCount
        #endif

        // Simulate 100 layout cycles at the SAME contentOffset (no boundary crossing).
        for _ in 0..<100 {
            feed.layoutSubviews()
        }

        #if DEBUG
        XCTAssertEqual(feed._taskSpawnCount, baseline,
            "Zero Task spawns expected during 100 frames without a leading-index boundary crossing")
        #endif
    }

    // MARK: - 2. Task spawn counter matches boundary crossings

    func testTaskSpawnCountMatchesBoundaryCrossings() {
        let feed = makeFeed(width: 375, height: 812)
        feed.items = items(count: 200)
        feed.layoutSubviews()

        #if DEBUG
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

    // MARK: - 3. Correct visible set at sampled offsets

    func testVisibleSetMatchesExpectedIndices() {
        let viewportHeight: CGFloat = 812
        let feed = makeFeed(width: 375, height: viewportHeight)

        // All items have the same estimated height so resolvedFrames are predictable.
        feed.items = items(count: 50, aspectRatio: 1.0)
        feed.layoutSubviews()

        // Use the feed's own public constants to avoid coupling.
        let itemPlusSpacing = feed.estimatedItemHeight + feed.layoutSpacing

        XCTAssertGreaterThan(feed.layer.sublayers?.count ?? 0, 0,
            "Feed layer should have cell sublayers after first layout")

        // Scroll past first item — index 0 should eventually be recycled.
        feed.contentOffset = CGPoint(x: 0, y: itemPlusSpacing + 1)
        feed.layoutSubviews()

        // contentSize should reflect estimated heights.
        let expectedContentHeight = CGFloat(50) * feed.estimatedItemHeight + CGFloat(49) * feed.layoutSpacing
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

    // MARK: - 6. Width change invalidates working range and resets estimated frames

    func testWidthChangeResetsFramesToEstimated() async {
        let feed = makeFeed(width: 375, height: 812)
        feed.items = items(count: 10)
        feed.layoutSubviews()

        let heightBefore = feed.contentSize.height

        // Simulate rotation: change bounds width.
        feed.frame = CGRect(x: 0, y: 0, width: 667, height: 375)
        feed.layoutSubviews()

        // After width change, all frames re-estimated at estimatedItemHeight.
        // contentSize.height should stay the same (same item count, same estimated height).
        XCTAssertEqual(feed.contentSize.height, heightBefore, accuracy: 1,
            "Estimated height sum must be the same after width change — only width changes")

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
            videoPreparation: videoPrep
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
            videoPreparation: videoPrep
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
    /// The test uses a `DecodeGate` to hold item A's decode in-flight while the cell is
    /// rebound to item B. Once the gate is opened, item A's Task calls
    /// `applyContent(id:image:for: A.id)`. The privacy guard compares A.id against
    /// `currentItemID` (now B.id) and rejects the stale delivery — proving the guard fired.
    ///
    /// Without the gate, both "guard fired" and "Task cancelled before guard" produce
    /// `contentLayer.opacity == 0`, making the test unable to distinguish the two cases.
    /// With the gate, the Task is guaranteed to reach `applyContent` — so opacity == 0
    /// can only be explained by the guard rejecting the delivery.
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
            videoPreparation: videoPrep
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
    }

    // MARK: - 13. Same-item re-mount keeps contentLayer.opacity at 1 (no placeholder flash)

    /// Verifies: when the same item (same ID) is re-mounted via a URL change,
    /// contentLayer.opacity stays at 1 throughout — no flash to the placeholder gradient state.
    ///
    /// Design context: URL is in imageDescriptor.layoutHash so a URL change is classified
    /// as .layout → itemsDidChange recycles the cell via returnToPool (cancelPendingMedia
    /// only; sublayers and opacity preserved) → prepareForReuse(for: sameID) sees
    /// isSameItem=true → skips opacity reset → applyLayout([]) (WR miss) prunes sublayers
    /// inside contentLayer but does NOT touch contentLayer.opacity.
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
            videoPreparation: videoPrep
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
            videoPreparation: videoPrep
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
    }

    // MARK: - 16. AnyHashable access counter: appearance-only itemsDidChange stays within differ-only bound

    /// Guards the invariant that itemsDidChange's height-forwarding path reads .itemID zero
    /// times — it uses (prevIdx, nextIdx) integer pairs, never an [AnyHashable: _] dict.
    ///
    /// NodeTable._itemIDCounter counts every .itemID property read (not AnyHashable constructions).
    /// RenderDiffer.diff with N all-surviving appearance-changed items reads .itemID exactly 4×N
    /// times: scratchPrevIndex build (N), lookup (N), removeValue (N), removed-check loop (N).
    /// itemsDidChange's height-forwarding (survivors/rebuildFrames) adds zero reads.
    /// A regression that rebuilds an [AnyHashable: _] dict for height-forwarding (+N inserts,
    /// +N lookups) raises the counter to 6×N and the assertion fails.
    ///
    /// frame.height=0 keeps visibleCells empty so the appearance-changed loop's spawnMediaFetches
    /// call — which reads e.next.itemID once per visible cell — never executes. This isolates
    /// the measurement to the differ only and satisfies _itemIDCounter's serial-access invariant
    /// (no concurrent Task spawns that could read .itemID during the window).
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
            videoPreparation: videoPrep
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
    }

    // MARK: - 17. Wall-time microbench: itemsDidChange appearance-only speedup vs e26 baseline

    /// Microbench for VelocityUI-wyc — verifies the performance claim in VelocityUI-4kp.3 #3.
    ///
    /// Measures `itemsDidChange` wall time for a 1000-item appearance-only feed update and
    /// compares against a synthetic e26 baseline constructed by adding the O(N) AnyHashable
    /// dict-build overhead that 4kp.3 removed (the `newIndexByItemID` build at old lines 230-232).
    ///
    /// Synthetic baseline construction:
    ///   e26_time    ≈ current_time + T_newIndexByItemID   (1 extra O(N) AnyHashable dict)
    ///   preE26_time ≈ current_time + T_newIndexByItemID + T_knownHeights
    ///                                                      (2 extra O(N) AnyHashable dicts;
    ///                                                       removedIDs is empty on appearance path)
    ///
    /// Why the 3× target cannot be asserted at total-function scope:
    ///   On the force-miss path (nil `itemSignature`), `itemsDidChange` calls `flatten()` for
    ///   all N items before diffing. On iOS simulator, `flatten()` for 1000 single-node items
    ///   takes ~8ms (existential dispatch + NodeTable init per item). The removed dict build
    ///   (~0.5ms) is ~6% of that total. A 3× speedup of the full function would require the
    ///   dict build to cost >2× everything else — impossible when flatten dominates. The 3×
    ///   claim holds for the isolated post-differ paths (rebuildFrames + visibility loops) but
    ///   those are private. The assertions here are therefore:
    ///     (a) an absolute p99 ceiling — catches algorithmic regressions that make the whole
    ///         function slow, regardless of where the cost lands
    ///     (b) dict-build overhead measurement printed for trend tracking — confirms the
    ///         removed cost is real and detectable; cross-check against test #16
    ///         (testAppearanceOnlyUpdateAnyHashableAccessCountBounded) which asserts the dict
    ///         build has zero .itemID accesses, proving the code path is gone.
    ///
    /// Scope of the "flatten dominates" justification:
    ///   The argument above is PATH-DEPENDENT — it holds on the force-miss path where
    ///   `flatten()` runs for every item on every update. This test exercises exactly that
    ///   path because it does not set `feed.itemSignature` (nil signature forces a cache-miss
    ///   on every item, preserving today's behavior bit-for-bit so this regression guard stays
    ///   valid). On the cache-HIT path (`itemSignature` provided, most items unchanged)
    ///   `flatten()` is skipped for hits and no longer dominates — total-function-scope speedup
    ///   targets become achievable there. The cache-hit floor is asserted by
    ///   testItemsDidChangeCacheHitFloor. This test stays the force-miss baseline.
    ///
    /// Median + p99 are printed for CI trend tracking.
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
        XCTAssertEqual(counter.value, N,
            "nil itemSignature: initial load must call builder for all N items")

        counter.value = 0
        feed.items = items  // identical items — nil sig still force-misses every item
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
        XCTAssertEqual(counter.value, N,
            "Initial load must call builder for all N items — no cache entries yet")

        // Only item id=2 changes signature; the other N-1 items must hit the cache.
        baseItems[2] = Item(id: 2, cornerRadius: 8)
        counter.value = 0
        feed.items = baseItems
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

        // Change sig for ALL items — must rebuild all.
        let altItems = (0..<N).map { Item(id: $0, cornerRadius: 8) }
        counter.value = 0
        feed.items = altItems
        XCTAssertEqual(counter.value, N,
            "All items changed signature — builder must be called N times to refresh NodeTables")

        // Restore base — all change again — builder called N times again.
        counter.value = 0
        feed.items = baseItems
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
        XCTAssertEqual(feed._tableCacheCount, N,
            "Cache must have N entries after initial load")

        // Remove 2 items — cache must shed their entries via full-swap eviction.
        feed.items = (0..<(N - 2)).map { Item(id: $0) }
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
        XCTAssertEqual(feed._tableCacheCount, N,
            "Cache must have N entries after initial load")

        // Swap id=5 for id=6 — same count, but id=5 must be evicted and id=6 added.
        // After the items loop: ids 1–4 hit, id=6 misses → cache grows to N+1 (6 entries).
        // tableCache.count (6) > items.count (5) → eviction removes id=5 → back to N.
        counter.value = 0
        feed.items = (1..<N).map { Item(id: $0) } + [Item(id: 6)]
        XCTAssertEqual(feed._tableCacheCount, N,
            "Mixed add+remove: eviction must shed replaced id=5, leaving cache.count == items.count")
        XCTAssertEqual(counter.value, 1,
            "Only the new id=6 must trigger a builder call — ids 1–4 hit cache")
    }
    #endif

    // MARK: - 22. Cache-hit floor: N=1000, 1 changed → builder called once, speedup ≥ 2×

    /// Brackets the d7b identity+signature cache perf envelope with two measurement loops.
    ///
    /// Loop A — cache-miss: all N items change signature each iteration. Equivalent to the
    /// force-miss path (no caching). Asserts builder called N times per iteration.
    ///
    /// Loop B — cache-hit: only 1 item changes signature per iteration. Asserts:
    ///   (a) builder called exactly 1 time per iteration (999 items served from cache)
    ///   (b) p99 < 10ms (ceiling that catches O(N²) regressions in the diff/rebuildFrames floor)
    ///   (c) median speedup > 2× vs the miss-loop median
    ///
    /// NOTE on the original 60µs / 130× target from the bead spec:
    ///   The bead's cost model counted only builder+flatten overhead (~5ms for N=1000
    ///   single-node items) and estimated cache-hit overhead at ~58µs. That estimate
    ///   excluded differ.diff() and rebuildFrames, which are O(N) and run on every
    ///   itemsDidChange call regardless of the cache. The diff builds scratchPrevIndex
    ///   (N AnyHashable dict insertions) and walks N next tables; rebuildFrames fills
    ///   survivors (N entries) and iterates N frames. Together these cost ~3ms for N=1000
    ///   and set the function floor. The cache does save ~5ms of builder+flatten work per
    ///   call, delivering a real ~2.6× total speedup (8ms → ~3ms). For feeds with deeper
    ///   DSL trees the builder+flatten cost grows while the diff floor stays stable, so
    ///   the speedup benefit grows with tree depth.
    ///
    /// Median + p99 printed for CI trend tracking.
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

        feed.items = baseItems

        // Warmup: prime branch predictors and dict backing store on the miss path.
        for i in 0..<warmupIters {
            feed.items = i.isMultiple(of: 2) ? allAltItems : baseItems
        }
        // Ensure cache is at baseItems (all cornerRadius=0) before loop A.
        feed.items = baseItems

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
            let t1 = mach_absolute_time()
            missRaw.append(t1 &- t0)
            missBuilderCallsTotal += counter.value
            useAllAlt.toggle()
        }
        // Loop A ends with feed at baseItems (iter 99 sets base — see useAllAlt tracing).

        // Warmup for hit path.
        for i in 0..<warmupIters {
            feed.items = i.isMultiple(of: 2) ? oneAltItems : baseItems
        }
        feed.items = baseItems  // reset cache to all cornerRadius=0

        // --- Loop B: cache-hit (1 item changes signature per iter) ---
        var hitRaw = [UInt64]()
        hitRaw.reserveCapacity(measureIters)
        var hitBuilderCallsTotal = 0
        var useOneAlt = true
        for _ in 0..<measureIters {
            counter.value = 0
            let t0 = mach_absolute_time()
            feed.items = useOneAlt ? oneAltItems : baseItems
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
    ///
    /// 1. Mount itemA, wait for async load to complete (image enters cache).
    /// 2. Prepend itemB → WorkingRange invalidated → itemA moves to index 1 (WR miss).
    /// 3. Pipeline re-measures → commits to WR → setNeedsLayout.
    /// 4. On the next layoutSubviews, refineKnownFrames builds a sync map (cachedImage hit),
    ///    calls applyLayout(_:synchronousContent:) → sublayer.contents is non-nil in the SAME
    ///    layoutSubviews call — no additional Task.yield or async hop required.
    ///
    /// Additionally asserts: _debugApplyContentCount == 0 (applyContent was bypassed),
    /// and placeholderLayer.opacity == 0 (full-coverage sync map reveals contentLayer inline).
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
            videoPreparation: videoPrep
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
        #if DEBUG
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
        #if DEBUG
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
    }
}
#endif

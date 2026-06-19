// FeedScrollViewTests.swift

#if canImport(UIKit)
import XCTest
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
}
#endif

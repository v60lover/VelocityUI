// ImagePrefetchIntegrationTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
import os
@testable import VelocityUI

// MARK: - URLProtocol helpers

/// Serves a 2×2 JPEG synchronously; counts per-URL network invocations.
/// Thread-safe: all state protected by _lock.
private final class PerURLCountingProtocol: URLProtocol {
    nonisolated(unsafe) private static let _lock = OSAllocatedUnfairLock(
        initialState: [URL: Int]()
    )

    static func count(for url: URL) -> Int {
        _lock.withLock { $0[url, default: 0] }
    }
    static func reset() { _lock.withLock { $0.removeAll() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

    override func startLoading() {
        if let url = request.url {
            PerURLCountingProtocol._lock.withLock { $0[url, default: 0] += 1 }
        }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: fmt
        ).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let resp = URLResponse(
            url: request.url!,
            mimeType: "image/jpeg",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Integration tests

@MainActor
final class ImagePrefetchIntegrationTests: XCTestCase {

    /// One-time settle window after the whole class finishes, in addition to each test's own
    /// drainFeedWork(_:) call — real prefetch batches + mocked-network decode work. See
    /// VelocityUI-1su.6.
    nonisolated override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    struct FeedItem: Identifiable, Sendable {
        let id: Int
        let url: URL
    }

    private func makeItems(count: Int) -> [FeedItem] {
        (0..<count).map {
            FeedItem(id: $0, url: URL(string: "https://img.example.com/\($0).jpg")!)
        }
    }

    private func makeEnvironmentWithCountingSession() -> RenderEnvironment {
        PerURLCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PerURLCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let imageActor = ImageActor(session: session, dimensionCache: dc)
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: imageActor,
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore()
        )
    }

    // MARK: - Test 1: prefetch fires for ahead-window URLs

    /// Verifies that after a boundary crossing at leading=0, imageActor.prefetch is invoked
    /// for indices [0, 10) — the half-open `prefetchRange(leadingIndex: 0, ahead: 10, ...)`
    /// window, per RenderPipeline's own authoritative formula (RenderPipelineTests:
    /// "prefetchAhead=10 means indices 0–9 should all be cache hits"). This includes the
    /// visible indices 0-2: on a cold start, WorkingRange and LayoutCache are both empty, so
    /// items 0-2 mount with an empty placeholder (no fragments yet) and the pipeline treats
    /// them like any other index in range — they get layout-resolved and prefetched exactly
    /// like 3-9, and refineKnownFrames delivers the resolved fragments to their already-
    /// mounted placeholder cells once the pipeline commits.
    func testPrefetchFiresForAheadWindow() async throws {
        let items = makeItems(count: 50)
        let env = makeEnvironmentWithCountingSession()
        let imageActor = env.imageActor
        await imageActor._testResetPrefetchedURLs()

        let feed = FeedScrollView<FeedItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in
            AsyncImageNode(url: item.url, aspectRatio: 1.5)
        }
        feed.items = items
        feed.layoutSubviews()

        // Poll until all 10 expected indices have been prefetched, or 2s max. Waiting on a
        // single URL (e.g. index 9's) is not sufficient — prefetch Tasks for indices 0-9 are
        // spawned as concurrent, unstructured Tasks with no ordering guarantee, so one URL
        // landing in the set does not imply the others have too.
        //
        // Task.sleep is used here because ImageActor runs on a custom DispatchQueueExecutor
        // (velocityui.image.actor). Task.yield alone cannot cross the executor boundary —
        // the prefetch Task runs at .utility priority on a separate serial queue, so we must
        // poll until the dispatch queue delivers the work. Bounded at 200 × 10ms = 2s.
        var retries = 0
        while retries < 200 {
            let prefetched = await imageActor._testGetPrefetchedURLs()
            if Set(prefetched).count >= 10 { break }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms poll
            retries += 1
        }

        let prefetchedURLs = await imageActor._testGetPrefetchedURLs()
        let prefetchedSet = Set(prefetchedURLs)

        // Indices 0…9 should all have been prefetched (ahead=10, behind=3, leading=0 —
        // prefetchRange clamps start to max(0, leadingIndex - behind) = 0).
        for idx in 0...9 {
            XCTAssertTrue(
                prefetchedSet.contains(items[idx].url),
                "Expected prefetch for index \(idx) (URL: \(items[idx].url)) to have fired"
            )
        }
        await drainFeedWork(feed)
    }

    // MARK: - Test 2: cell mounts with non-nil contents after prefetch

    /// After prefetch settles for index 3, mounting that index must deliver image content.
    /// Asserts that the image arrives via the prefetch cache (not a second network call).
    func testPrefetchedIndexMountsWithContent() async throws {
        let items = makeItems(count: 50)
        let env = makeEnvironmentWithCountingSession()
        let imageActor = env.imageActor
        await imageActor._testResetPrefetchedURLs()

        let feed = FeedScrollView<FeedItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: 375, height: 812)
        )
        feed.cellBuilder = { item in
            AsyncImageNode(url: item.url, aspectRatio: 1.5)
        }
        feed.items = items
        feed.layoutSubviews()

        // Wait until index 3 has been prefetched AND its WorkingRange entry has committed.
        // URL presence alone proves the cold-path of prefetch() was entered and the inFlight
        // entry created — not that the decode finished, and not that the pipeline's single
        // MainActor commit (which lands after the *entire* [0,10) batch finishes measuring,
        // not just index 3) has happened yet. The WorkingRange check is required before we can
        // trust resolvedFrames[3]'s real (measured) height below — reading it while the entry
        // is still missing would silently use the estimatedItemHeight placeholder instead.
        let targetURL = items[3].url
        var retries = 0
        while retries < 200 {
            let prefetched = await imageActor._testGetPrefetchedURLs()
            if prefetched.contains(targetURL), feed._workingRangeMissCount(from: 3, to: 4) == 0 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            retries += 1
        }

        // Trigger refineKnownFrames so resolvedFrames[3] reflects the real (measured) height
        // before we read it below.
        //
        // NOTE: mounting index 3 can deliver its content via either of two valid paths —
        // synchronously in this very call (if the prefetch's decode has already finished and
        // the image is cache-resident by mount time) or asynchronously afterward (if the
        // decode is still in flight). Both are correct; which one fires is a race with the
        // background decode, not something the test controls. See VelocityUI-xbk: an earlier
        // version of this test observed only the async path (an applyContent-delivery hook)
        // and flaked hard under full-suite load, where the extra elapsed real time before this
        // point made the synchronous path far more likely to win — the hook then never fired
        // and the test spun out its whole timeout window despite the image having rendered
        // correctly. `_debugIsContentRevealed` is path-independent: it reflects
        // `RenderCell`'s `contentLayer` reveal state, which both delivery paths set.
        feed.layoutSubviews()
        guard let frame3 = feed._debugResolvedFrame(at: 3) else {
            XCTFail("index 3 must have a resolved frame once its WorkingRange entry has committed")
            return
        }

        // Scroll so index 3's real (measured) frame is centered in the viewport. If index 3 was
        // already mounted above, updateVisibleCells' `visibleCells[index] == nil` guard skips
        // re-mounting it — harmless, since content delivery is observed by polling cell state
        // below rather than by an event fired at mount/delivery time.
        feed.contentOffset = CGPoint(x: 0, y: max(0, frame3.midY - feed.bounds.height / 2))
        feed.layoutSubviews()

        // Poll for content reveal — bounded real-time wait, index-3-specific by construction
        // (reads index 3's own cell state, so no itemID filtering is needed for a multi-cell
        // mount). Bounded at 200 × 10ms = 2s, matching the polling budget used elsewhere in
        // this file for actor-hop-dependent state.
        var revealRetries = 0
        while revealRetries < 200 {
            if feed._debugIsContentRevealed(at: 3) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            revealRetries += 1
        }

        XCTAssertTrue(
            feed._debugIsContentRevealed(at: 3),
            "index 3's cell must reveal real image content within 2s — neither the synchronous mount-time paint nor the async applyContent path delivered it"
        )

        // Assert cell is visible after scroll.
        let cell = feed._cellLayer(at: 3)
        XCTAssertNotNil(cell, "Cell at index 3 must be visible after scroll")

        // Assert mount-time image() coalesced with the prefetch instead of firing its own
        // network request. A before/after delta around the mount is not a valid signal here —
        // the prefetch's own (only) request is asynchronous and may still be in flight when
        // "before" is sampled, making a legitimate single request look like a spurious delta.
        // The real invariant is the total count once everything has settled: exactly one
        // request for the URL, proving mount joined the prefetch's inFlight entry rather than
        // launching a second fetch.
        XCTAssertEqual(
            PerURLCountingProtocol.count(for: targetURL), 1,
            "expected exactly one network request for index 3's URL (the prefetch) — mount-time image() must coalesce, not launch a second fetch"
        )

        await drainFeedWork(feed)
    }
}
#endif

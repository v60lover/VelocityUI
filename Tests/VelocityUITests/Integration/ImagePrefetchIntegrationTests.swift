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
            videoPreparation: videoPrep
        )
    }

    // MARK: - Test 1: prefetch fires for ahead-window URLs

    /// Verifies that after a boundary crossing at leading=0 (viewport shows items 0-2),
    /// imageActor.prefetch is invoked for indices in [3, 12] (ahead=10).
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

        // Poll until index 3 has been prefetched, or 2s max.
        // Task.sleep is used here because ImageActor runs on a custom DispatchQueueExecutor
        // (velocityui.image.actor). Task.yield alone cannot cross the executor boundary —
        // the prefetch Task runs at .utility priority on a separate serial queue, so we must
        // poll until the dispatch queue delivers the work. Bounded at 200 × 10ms = 2s.
        let targetURL = items[3].url
        var retries = 0
        while retries < 200 {
            let prefetched = await imageActor._testGetPrefetchedURLs()
            if prefetched.contains(targetURL) { break }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms poll
            retries += 1
        }

        let prefetchedURLs = await imageActor._testGetPrefetchedURLs()
        let prefetchedSet = Set(prefetchedURLs)

        // Indices 3…12 should all have been prefetched (ahead=10, leading=0).
        for idx in 3...12 {
            XCTAssertTrue(
                prefetchedSet.contains(items[idx].url),
                "Expected prefetch for index \(idx) (URL: \(items[idx].url)) to have fired"
            )
        }
        // Indices 0…2 are in the visible window — they mount via spawnMediaFetches
        // directly via imageActor.image(), not via prefetch().
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

        // Wait until index 3 has been prefetched (same bounded poll as Test 1).
        let targetURL = items[3].url
        var retries = 0
        // URL presence proves the cold-path of prefetch() was entered and the inFlight entry
        // created — not that the decode finished. The inFlight entry is sufficient for
        // mount-time image() to coalesce; the PerURLCountingProtocol assertion below verifies
        // no second network call was issued.
        while retries < 200 {
            let prefetched = await imageActor._testGetPrefetchedURLs()
            if prefetched.contains(targetURL) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            retries += 1
        }

        // Record network count BEFORE mounting index 3.
        let networkCountBeforeMount = PerURLCountingProtocol.count(for: targetURL)

        // Settlement flag — true only if applyContent hook fired before the timeout.
        // The timeout also signals the semaphore so the wait unblocks; the flag
        // distinguishes an actual delivery from a silent timeout.
        let deliveredLock = OSAllocatedUnfairLock<Bool>(initialState: false)
        let contentDelivered = AsyncSemaphore(value: 0)
        feed._setOnContentDelivered { [contentDelivered, deliveredLock] in
            deliveredLock.withLock { $0 = true }
            await contentDelivered.signal()
        }

        #if DEBUG
        RenderCell._debugResetApplyContentCount()
        #endif

        // Scroll to make index 3 visible.
        // Each item is ~562pt tall at aspectRatio=1.5 on 375pt width; index 3 starts ~1686pt.
        feed.contentOffset = CGPoint(x: 0, y: 1650)
        feed.layoutSubviews()

        // Await content delivery via semaphore (no Task.sleep — explicit structured wait).
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await contentDelivered.signal()  // unblocks wait on timeout; deliveredLock stays false
        }
        try? await contentDelivered.wait()
        timeoutTask.cancel()

        XCTAssertTrue(
            deliveredLock.withLock { $0 },
            "applyContent must fire for index 3 within 5s — delivery hook never triggered"
        )

        #if DEBUG
        XCTAssertGreaterThanOrEqual(
            RenderCell._debugApplyContentCount, 1,
            "applyContent must have fired at least once for the visible cell at index 3"
        )
        #endif

        // Assert cell is visible after scroll.
        let cell = feed._cellLayer(at: 3)
        XCTAssertNotNil(cell, "Cell at index 3 must be visible after scroll")

        // Assert no second network request was made for index 3's URL (prefetch coalescing).
        // When prefetch populates the cache before mount, imageActor.image() returns a cache
        // hit — PerURLCountingProtocol receives no additional request for that URL.
        let networkCountAfterMount = PerURLCountingProtocol.count(for: targetURL)
        XCTAssertEqual(
            networkCountAfterMount, networkCountBeforeMount,
            "mount-time image() for index 3 must coalesce with the prefetch — zero additional network requests expected"
        )

        feed._setOnContentDelivered(nil)
    }
}
#endif

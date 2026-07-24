// WarmUpTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
import os
@testable import VelocityUI

// MARK: - URLProtocol helper

/// Serves a 2×2 JPEG synchronously. Counts requests per URL so tests can verify
/// that warmUp makes exactly one network fetch per image fragment, and that a second
/// warmUp call for the same items makes zero additional fetches (idempotency).
private final class WarmUpCountingProtocol: URLProtocol {
    nonisolated(unsafe) private static let _lock = OSAllocatedUnfairLock(
        initialState: [URL: Int]()
    )

    static func count(for url: URL) -> Int { _lock.withLock { $0[url, default: 0] } }
    static func reset() { _lock.withLock { $0.removeAll() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

    override func startLoading() {
        if let url = request.url {
            WarmUpCountingProtocol._lock.withLock { $0[url, default: 0] += 1 }
        }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: fmt
        ).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.systemGreen.setFill()
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

// MARK: - Test types

private struct TestItem: Identifiable, Sendable, Equatable {
    let id: Int
    let imageURL: URL
}

private struct TestCell: RenderView {
    let item: TestItem
    var renderBody: AsyncImageNode {
        AsyncImageNode(url: item.imageURL, aspectRatio: 1.5)
    }
}

// MARK: - Tests

@MainActor
final class WarmUpTests: XCTestCase {

    /// One-time settle window after the whole class finishes — AsyncFeed.warmUp() spawns
    /// real concurrent prefetch Tasks against a real ImageActor. See VelocityUI-1su.6.
    nonisolated override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        WarmUpCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WarmUpCountingProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Test 1: AC#2 + AC#3 — warmUp populates LayoutCache and image cache

    /// After awaiting warmUp, LayoutCache holds a CellEntry for each item (AC#3) and
    /// ImageActor has fetched every image fragment URL exactly once (AC#2).
    func testWarmUp_populatesBothCaches() async {
        let env = RenderEnvironment(session: makeSession())
        let n = 3
        let width: CGFloat = 375
        let scale: CGFloat = 2
        let imageURLs = (0..<n).map { URL(string: "https://warmup-caches.example/\($0).jpg")! }
        let items = (0..<n).map { TestItem(id: $0, imageURL: imageURLs[$0]) }

        await AsyncFeed<TestItem, TestCell>.warmUp(
            items: items, width: width, scale: scale, environment: env,
            cellBuilder: { TestCell(item: $0) }
        ).value

        // AC#3: LayoutCache has an entry for every warmed item.
        // Reproduce the same key warmUp would have used — flatten produces the same
        // layoutHash as long as the node tree is identical.
        for item in items {
            let table = flatten(TestCell(item: item).renderBody, itemID: item.id)
            let key = CacheKey(layoutHash: table.layoutHash, width: width)
            let entry = await env.layoutCache.get(key)
            XCTAssertNotNil(entry, "LayoutCache must have a CellEntry for item \(item.id) after warmUp")
        }

        // AC#2: Every image URL is resident in ImageActor's NSCache.
        // cachedImage() is the authoritative check — it reads the same NSCache that
        // mount-time buildSyncMap() reads. _testPrefetchedURLs only confirms the cold
        // path was entered; cachedImage() confirms the image is actually stored.
        //
        // targetSize derivation: AsyncImageNode(aspectRatio: 1.5) at width 375 →
        // measureNode returns totalFrame CGRect(0,0,375,250) → fragment.frame.size = (375,250).
        // scale is clamped to max(1, scale) = 2 inside warmUp, matching cachedImage's key.
        let expectedTargetSize = CGSize(width: 375, height: 250)
        for (i, url) in imageURLs.enumerated() {
            let img = env.imageActor.cachedImage(
                for: url, targetSize: expectedTargetSize, cornerRadius: 0, scale: scale)
            XCTAssertNotNil(img, "AC#2: cachedImage must be non-nil for URL \(i) after warmUp")
        }

        let prefetchedURLs = await env.imageActor._testGetPrefetchedURLs()
        XCTAssertEqual(
            Set(prefetchedURLs), Set(imageURLs),
            "warmUp must prefetch every image URL exactly once"
        )
        XCTAssertEqual(prefetchedURLs.count, n, "No duplicate prefetches: expected \(n), got \(prefetchedURLs.count)")

        for (i, url) in imageURLs.enumerated() {
            XCTAssertEqual(
                WarmUpCountingProtocol.count(for: url), 1,
                "URL \(i): expected exactly 1 network fetch, got \(WarmUpCountingProtocol.count(for: url))"
            )
        }
    }

    // MARK: - Test 2: AC#5 — empty items completes immediately

    func testWarmUp_emptyItems_completesImmediately() async {
        let env = RenderEnvironment(session: makeSession())
        await AsyncFeed<TestItem, TestCell>.warmUp(
            items: [], width: 375, scale: 2, environment: env,
            cellBuilder: { TestCell(item: $0) }
        ).value
        // No assertion needed — test times out if warmUp hangs on empty input.
    }

    // MARK: - Test 3: AC#7 — second call is idempotent, zero additional network fetches

    /// The second warmUp call for the same items, width, and scale must hit LayoutCache
    /// (skipping re-measure) and ImageActor's NSCache (skipping re-fetch). The network
    /// request count for each URL stays at exactly 1 after both calls.
    func testWarmUp_calledTwice_isIdempotent() async {
        let env = RenderEnvironment(session: makeSession())
        let n = 2
        let width: CGFloat = 375
        let scale: CGFloat = 2
        let imageURLs = (0..<n).map { URL(string: "https://warmup-idempotent.example/\($0).jpg")! }
        let items = (0..<n).map { TestItem(id: $0, imageURL: imageURLs[$0]) }
        let builder: @MainActor (TestItem) -> TestCell = { TestCell(item: $0) }

        // First call — cold path.
        await AsyncFeed<TestItem, TestCell>.warmUp(
            items: items, width: width, scale: scale, environment: env, cellBuilder: builder
        ).value

        for (i, url) in imageURLs.enumerated() {
            XCTAssertEqual(WarmUpCountingProtocol.count(for: url), 1,
                           "First warmUp: URL \(i) must have exactly 1 fetch")
        }

        // Reset counter only — leave both LayoutCache and image NSCache warm.
        WarmUpCountingProtocol.reset()

        // Second call — both caches hit; zero network requests.
        await AsyncFeed<TestItem, TestCell>.warmUp(
            items: items, width: width, scale: scale, environment: env, cellBuilder: builder
        ).value

        for (i, url) in imageURLs.enumerated() {
            XCTAssertEqual(
                WarmUpCountingProtocol.count(for: url), 0,
                "Second warmUp: URL \(i) must have 0 additional fetches (cache hit), got \(WarmUpCountingProtocol.count(for: url))"
            )
        }
    }

    // MARK: - Test 4: AC#6 smoke — cancel + await does not deadlock or crash

    /// Cancelling the returned Task and awaiting it must complete without hanging.
    /// Fine-grained cancellation ordering (prefetch gate held + Task.cancel) is verified
    /// by the RenderPipeline generation-guard tests, which share the same ImageActor
    /// prefetch contract. This test focuses on the API surface: cancel is safe to call
    /// at any point and the Task drains cleanly.
    func testWarmUp_cancellation_doesNotDeadlock() async {
        let env = RenderEnvironment(session: makeSession())
        let items = (0..<5).map {
            TestItem(id: $0, imageURL: URL(string: "https://warmup-cancel.example/\($0).jpg")!)
        }
        let task = AsyncFeed<TestItem, TestCell>.warmUp(
            items: items, width: 375, scale: 2, environment: env,
            cellBuilder: { TestCell(item: $0) }
        )
        task.cancel()
        await task.value
    }
}
#endif

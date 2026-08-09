// ImageActorTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
import CoreGraphics
import os
@testable import VelocityUI

#if DEBUG
private let log = Logger(subsystem: "com.velocityui.tests", category: "ImageActorTests")
#endif

private final class CountingURLProtocol: URLProtocol {
    private static let _lock = OSAllocatedUnfairLock(initialState: 0)

    static var count: Int { _lock.withLock { $0 } }
    static func reset() { _lock.withLock { $0 = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CountingURLProtocol._lock.withLock { $0 += 1 }
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: {
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = 1
                return fmt
            }()
        ).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let response = URLResponse(
            url: request.url!,
            mimeType: "image/jpeg",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
    override func stopLoading() {}
}

/// Blocks in startLoading() until the test calls release(). Lets tests inject a network
/// pause so other Tasks can join an inFlight entry before the response arrives.
private final class BarrierURLProtocol: URLProtocol {
    private static let _hitSem = DispatchSemaphore(value: 0)
    private static let _releaseSem = DispatchSemaphore(value: 0)

    /// Block the calling thread until startLoading has been entered.
    /// Must be called from a non-cooperative thread (e.g. DispatchQueue.global).
    static func waitForHit() { _hitSem.wait() }
    /// Unblock startLoading so it delivers its response.
    static func release() { _releaseSem.signal() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        BarrierURLProtocol._hitSem.signal()
        BarrierURLProtocol._releaseSem.wait()
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()
        ).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let response = URLResponse(
            url: request.url!, mimeType: "image/jpeg",
            expectedContentLength: data.count, textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Avoid deadlock if URLSession cancels the request while blocked in _releaseSem.wait().
        BarrierURLProtocol._releaseSem.signal()
    }
}

final class ImageActorTests: XCTestCase {

    /// One-time settle window after the whole class finishes. Every test here spins up its
    /// own `ImageActor` (own DispatchQueueExecutor + concurrent decode queue); back-to-back
    /// across ~25 tests that churns a lot of short-lived GCD queues at once. Swift's
    /// cooperative thread pool and GCD's QoS-scoped worker pool are both process-wide, so a
    /// class immediately following this one can have its own real decode/network work
    /// throttled by leftover pool pressure — see VelocityUI-1su.6 (confirmed via bisection:
    /// this class alone, with no FeedScrollViewTests beforehand, is enough to make
    /// ImagePrefetchIntegrationTests.testPrefetchedIndexMountsWithContent miss its 5s window).
    override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    // MARK: - Fixture helpers

    private func makeFormat(scale: CGFloat = 1) -> UIGraphicsImageRendererFormat {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale  // force 1:1 pt→px so pixel dimensions == logical dimensions
        return fmt
    }

    private func jpegData(width: Int, height: Int) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: makeFormat())
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

    /// Extract the alpha byte from BGRA8888 premultiplied pixel at (x, y) in CGContext
    /// coordinates (origin bottom-left, matching CGContext draw conventions).
    private func alpha(of image: CGImage, atContextX x: Int, y: Int) -> UInt8 {
        let w = image.width
        let h = image.height
        var pixels = [UInt32](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // BGRA8888 LE: value = B | (G<<8) | (R<<16) | (A<<24)
        let pixel = pixels[y * w + x]
        return UInt8((pixel >> 24) & 0xFF)
    }

    // MARK: - Test 1: Round-trip produces correctly sized BGRA8888 CGImage

    func testRoundTrip() async throws {
        let url = try writeTempJPEG(width: 120, height: 90)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor()
        let image = await actor.image(
            for: url,
            targetSize: CGSize(width: 120, height: 90),
            cornerRadius: 0,
            scale: 1
        )

        XCTAssertNotNil(image, "Decode must succeed for a valid JPEG file URL")
        XCTAssertEqual(image?.width, 120)
        XCTAssertEqual(image?.height, 90)
    }

    // MARK: - Test 2: Output is BGRA8888 premultiplied

    func testOutputIsBGRA8888Premultiplied() async throws {
        let url = try writeTempJPEG(width: 40, height: 40)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor()
        let image = await actor.image(
            for: url,
            targetSize: CGSize(width: 40, height: 40),
            cornerRadius: 0,
            scale: 1
        )

        XCTAssertNotNil(image)
        if let image {
            XCTAssertTrue(
                isBGRA8888(image),
                "Output must be BGRA8888 premultiplied (CA's preferred format)"
            )
        }
    }

    // MARK: - Test 3: cornerRadius > 0 makes corner pixels transparent, center opaque

    func testCornerRadiusTransparency() async throws {
        let side = 100
        let url = try writeTempJPEG(width: side, height: side)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor()
        // radius = side/2 → full circle; every corner pixel must be clipped (alpha = 0)
        let image = await actor.image(
            for: url,
            targetSize: CGSize(width: side, height: side),
            cornerRadius: CGFloat(side) / 2,
            scale: 1
        )

        XCTAssertNotNil(image, "Decode must succeed")
        guard let image else { return }

        // CGContext origin is bottom-left; corner (0,0) = bottom-left of image.
        XCTAssertEqual(
            alpha(of: image, atContextX: 0, y: 0),
            0,
            "Bottom-left corner must be transparent (outside circle clip)"
        )
        // Top-right corner in CGContext coordinates: (w-1, h-1)
        XCTAssertEqual(
            alpha(of: image, atContextX: image.width - 1, y: image.height - 1),
            0,
            "Top-right corner must be transparent"
        )
        // Center pixel must be opaque
        XCTAssertGreaterThan(
            alpha(of: image, atContextX: image.width / 2, y: image.height / 2),
            200,
            "Center pixel must be mostly opaque"
        )
    }

    // MARK: - Test 4: Cache hit returns same CGImage instance

    func testCacheHitReturnsSameInstance() async throws {
        let url = try writeTempJPEG(width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor()
        let size = CGSize(width: 60, height: 60)

        let first = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        let second = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        // NSCache stores the wrapper by reference; same CachedImage → same CGImage pointer.
        XCTAssertTrue(
            first === second,
            "Cache hit must return the identical CGImage instance (no redundant decode)"
        )
    }

    // MARK: - Test 5: Different targetSize produces separate cache entries

    func testDifferentSizesAreSeparateCacheEntries() async throws {
        let url = try writeTempJPEG(width: 200, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor()
        let small = await actor.image(
            for: url,
            targetSize: CGSize(width: 50, height: 50),
            cornerRadius: 0,
            scale: 1
        )
        let large = await actor.image(
            for: url,
            targetSize: CGSize(width: 100, height: 100),
            cornerRadius: 0,
            scale: 1
        )

        XCTAssertNotNil(small)
        XCTAssertNotNil(large)
        XCTAssertFalse(
            small === large,
            "Different targetSizes must produce different cached images"
        )
    }

    // MARK: - Test 5b (VelocityUI-zgs Fix A): decodeScaleCeiling clamps the cache key

    func testDecodeScaleCeilingCollapsesCacheKeyAboveTheCeiling() async throws {
        // Default ceiling is 2.0. Requests at scale 2 and scale 3 must collapse to the same
        // cache entry — the second call is a cache hit, not a fresh decode at 3x.
        let url = try writeTempJPEG(width: 200, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor()
        let size = CGSize(width: 60, height: 60)

        let atCeiling = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 2)
        let aboveCeiling = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 3)

        XCTAssertNotNil(atCeiling)
        XCTAssertNotNil(aboveCeiling)
        XCTAssertTrue(
            atCeiling === aboveCeiling,
            "scale: 3 must clamp to the 2.0 ceiling and hit the same cache entry as scale: 2"
        )
        XCTAssertEqual(atCeiling?.width, 120, "Decoded at the clamped scale (60pt * 2), not full scale (60pt * 3 = 180)")
    }

    func testDecodeScaleCeilingCustomValueIsHonoured() async throws {
        let url = try writeTempJPEG(width: 200, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor(dimensionCache: DimensionCache(), decodeScaleCeiling: 1.0)
        let size = CGSize(width: 60, height: 60)

        let atOne = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        let atThree = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 3)

        XCTAssertNotNil(atOne)
        XCTAssertTrue(atOne === atThree, "A custom 1.0 ceiling must clamp scale: 3 down to 1")
        XCTAssertEqual(atOne?.width, 60)
    }

    func testCachedImageRespectsDecodeScaleCeiling() async throws {
        let url = try writeTempJPEG(width: 200, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let actor = ImageActor()
        let size = CGSize(width: 60, height: 60)

        _ = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 2)

        // A synchronous probe at the raw (unclamped) scale must still hit — cachedImage()
        // has to clamp identically to image(), or the probe used at mount time would
        // spuriously miss a warm cache and fall back to the async path every time.
        let probed = actor.cachedImage(for: url, targetSize: size, cornerRadius: 0, scale: 3)
        XCTAssertNotNil(probed, "cachedImage() must clamp scale the same way image() does")
    }

    // MARK: - Test 6: DimensionCache stores raw source dimensions, not the render-target size

    func testDimensionCacheStoresRawSourceDimensions() async throws {
        // Source is 200×150. We request a 100×75 thumbnail. DimensionCache must record
        // 200×150 (the true source aspect ratio) so classify() can use it at any size.
        let url = try writeTempJPEG(width: 200, height: 150)
        defer { try? FileManager.default.removeItem(at: url) }

        let dimensions = DimensionCache()
        let actor = ImageActor(dimensionCache: dimensions)

        XCTAssertNil(dimensions.get(url), "No dimension entry before fetch")
        _ = await actor.image(
            for: url,
            targetSize: CGSize(width: 100, height: 75),
            cornerRadius: 0,
            scale: 1
        )

        let stored = dimensions.get(url)
        XCTAssertNotNil(stored, "DimensionCache must be populated after decode")
        XCTAssertEqual(stored?.width, 200, "Must store raw source width, not thumbnail width")
        XCTAssertEqual(stored?.height, 150, "Must store raw source height, not thumbnail height")
    }

    // MARK: - Test 7: AsyncSemaphore caps concurrent executions at its value

    func testSemaphoreMaxConcurrency() async {
        let sem = AsyncSemaphore(value: 3)
        let active = OSAllocatedUnfairLock(initialState: 0)
        let highWater = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await sem.wait()

                    let current = active.withLock { v -> Int in v += 1; return v }
                    highWater.withLock { v in if current > v { v = current } }

                    // Hold the slot briefly so concurrency overlaps.
                    try? await Task.sleep(nanoseconds: 5_000_000)

                    active.withLock { v in v -= 1 }
                    await sem.signal()
                }
            }
        }

        XCTAssertLessThanOrEqual(
            highWater.withLock { $0 },
            3,
            "Semaphore must never allow more than 3 concurrent holders"
        )
    }

    // MARK: - Test 8: AsyncSemaphore cancellation throws CancellationError

    func testSemaphoreCancellationThrows() async throws {
        let sem = AsyncSemaphore(value: 0)  // no slots — will block indefinitely

        let task = Task<Void, any Error> {
            try await sem.wait()
        }

        // Let the task reach the wait.
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected CancellationError from cancelled wait")
        } catch is CancellationError {
            // Correct path
        }
    }

    // MARK: - Test 9: AsyncSemaphore FIFO — waiters wake in order

    func testSemaphoreFIFOOrdering() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // take the only slot

        var order: [Int] = []
        let lock = OSAllocatedUnfairLock(initialState: [Int]())

        // Queue 3 waiters; they should wake 0 → 1 → 2.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask {
                    try? await sem.wait()
                    lock.withLock { v in v.append(i) }
                    await sem.signal()
                }
                // Tiny yield so each task reaches wait() before the next is added.
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            // Release the initial slot — wakes waiter 0.
            await sem.signal()
        }

        order = lock.withLock { $0 }
        XCTAssertEqual(order, [0, 1, 2], "Waiters must wake in FIFO order")
    }

    // MARK: - Test 9a: AsyncSemaphore priority admission — .visible jumps ahead of
    // earlier-enqueued .ahead/.behind waiters; FIFO preserved within a tier.

    /// Trace + assertion:
    /// | Invariant | Assertion |
    /// |---|---|
    /// | A later-enqueued `.visible` waiter is admitted before earlier `.ahead`/`.behind` waiters | wake order starts with "visible0" even though it was enqueued last |
    /// | FIFO is preserved WITHIN a tier | "behind0" wakes before "behind1" |
    func testSemaphorePriorityAdmissionOrder() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // take the only slot — every subsequent wait() below contends

        let lock = OSAllocatedUnfairLock(initialState: [String]())

        // Enqueue two .behind, then one .ahead, then one .visible — each spawned only after
        // the previous one has actually reached its tier's queue (deterministic anchor via
        // _waiterCount; no sleeping).
        let behind0 = Task {
            try? await sem.wait(priority: .behind)
            lock.withLock { $0.append("behind0") }
            await sem.signal()
        }
        while await sem._waiterCount(priority: .behind) < 1 { await Task.yield() }

        let behind1 = Task {
            try? await sem.wait(priority: .behind)
            lock.withLock { $0.append("behind1") }
            await sem.signal()
        }
        while await sem._waiterCount(priority: .behind) < 2 { await Task.yield() }

        let ahead0 = Task {
            try? await sem.wait(priority: .ahead)
            lock.withLock { $0.append("ahead0") }
            await sem.signal()
        }
        while await sem._waiterCount(priority: .ahead) < 1 { await Task.yield() }

        // Enqueued LAST but must be admitted FIRST — proves priority beats arrival order.
        let visible0 = Task {
            try? await sem.wait(priority: .visible)
            lock.withLock { $0.append("visible0") }
            await sem.signal()
        }
        while await sem._waiterCount(priority: .visible) < 1 { await Task.yield() }

        // Release the slot held at the top. Each waiter signals after recording, cascading
        // the release through the remaining queue.
        await sem.signal()

        _ = await behind0.value
        _ = await behind1.value
        _ = await ahead0.value
        _ = await visible0.value

        XCTAssertEqual(
            lock.withLock { $0 },
            ["visible0", "ahead0", "behind0", "behind1"],
            "A later-enqueued .visible waiter must be admitted before earlier .ahead/.behind "
            + "waiters, and FIFO must hold within the .behind tier"
        )
    }

    // MARK: - Test 9b: AsyncSemaphore cancellation removes the waiter from its own tier
    // only, and never consumes a slot.

    func testSemaphoreCancellationRemovesFromCorrectTierWithoutConsumingSlot() async throws {
        let sem = AsyncSemaphore(value: 0)  // no slots — every wait() blocks

        let behindTask = Task<Void, any Error> {
            try await sem.wait(priority: .behind)
        }
        while await sem._waiterCount(priority: .behind) < 1 { await Task.yield() }

        let visibleTask = Task<Void, any Error> {
            try await sem.wait(priority: .visible)
        }
        while await sem._waiterCount(priority: .visible) < 1 { await Task.yield() }

        behindTask.cancel()

        do {
            try await behindTask.value
            XCTFail("Cancelled .behind waiter must throw CancellationError")
        } catch is CancellationError {
            // Expected — and by the time this continuation resumes, cancelWaiter() has
            // already removed the entry from waiterTiers[.behind] (removal happens before
            // the resume, in the same actor-isolated call).
        }

        let behindCountAfterCancel = await sem._waiterCount(priority: .behind)
        XCTAssertEqual(
            behindCountAfterCancel, 0,
            "Cancelled waiter must be removed from its own tier"
        )
        let visibleCountAfterCancel = await sem._waiterCount(priority: .visible)
        XCTAssertEqual(
            visibleCountAfterCancel, 1,
            "Cancelling a .behind waiter must not disturb the .visible tier's queue"
        )

        // Releasing once must wake the surviving .visible waiter — proving the cancelled
        // waiter's slot was never consumed (it never held one to leak).
        await sem.signal()
        try await visibleTask.value

        // A second signal() with no waiters left increments count. A fresh wait() must
        // then hit the uncontended fast path (not block) — confirms no slot was lost to
        // the earlier cancellation.
        await sem.signal()
        try await sem.wait()
    }

    // MARK: - Test 9c: AsyncSemaphore uncontended fast-path round-trip stays cheap
    // (VelocityUI-qtc) — priority lanes must not add cost to the count>0 / no-waiter paths.

    /// Threshold rationale: quiet hardware measures ~2-5us; loaded CI measures ~20-50us.
    /// 100us is a generous ~10x-regression trigger, not a perf guarantee — it absorbs CI
    /// noise while still catching the fast path silently growing (e.g. a per-call array
    /// allocation, an executor hop, or a tier scan on every wait()/signal()).
    func testSemaphoreUncontendedRoundTripStaysFast() async throws {
        let sem = AsyncSemaphore(value: 1)
        let warmupIterations = 1_000
        let measuredIterations = 10_000

        for _ in 0..<warmupIterations {
            try await sem.wait()
            await sem.signal()
        }

        var samplesNs: [UInt64] = []
        samplesNs.reserveCapacity(measuredIterations)
        for _ in 0..<measuredIterations {
            let start = DispatchTime.now()
            try await sem.wait()
            await sem.signal()
            let end = DispatchTime.now()
            samplesNs.append(end.uptimeNanoseconds - start.uptimeNanoseconds)
        }

        let sorted = samplesNs.sorted()
        let median = sorted[sorted.count / 2]
        let p99 = sorted[max(0, Int(Double(sorted.count) * 0.99) - 1)]

        #if DEBUG
        log.debug("[qtc] AsyncSemaphore uncontended round-trip N=\(measuredIterations): median=\(median)ns  p99=\(p99)ns")
        #endif

        XCTAssertLessThan(
            Double(p99), 100_000,
            "Uncontended wait()/signal() round-trip p99 must stay < 100us; measured \(p99)ns. "
            + "Priority lanes must not add cost to the uncontended fast path."
        )
    }

    // MARK: - Test 9d: AsyncSemaphore.elevate moves a queued waiter to a higher tier and it
    // is admitted ahead of a non-elevated waiter in its original tier (VelocityUI-8nz).

    /// Trace + assertion:
    /// | Invariant | Assertion |
    /// |---|---|
    /// | `elevate(id: A, to: .visible)` moves A out of `.behind` into `.visible` while still queued | `_waiterCount(.behind) == 1` and `_waiterCount(.visible) == 1` immediately after the call |
    /// | The elevated waiter A is admitted before non-elevated `.behind` waiter B, even though A was enqueued first at `.behind` (elevation, not arrival order, decides) | wake order is `["A", "B"]` |
    func testSemaphoreElevateAdmitsAheadOfOriginalTier() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // take the only slot — both waiters below contend

        let lock = OSAllocatedUnfairLock(initialState: [String]())
        let idA = UUID()
        let idB = UUID()

        let taskA = Task {
            try? await sem.wait(id: idA, priority: .behind)
            lock.withLock { $0.append("A") }
            await sem.signal()
        }
        while await sem._waiterCount(priority: .behind) < 1 { await Task.yield() }

        let taskB = Task {
            try? await sem.wait(id: idB, priority: .behind)
            lock.withLock { $0.append("B") }
            await sem.signal()
        }
        while await sem._waiterCount(priority: .behind) < 2 { await Task.yield() }

        await sem.elevate(id: idA, to: .visible)

        let behindCountAfterElevate = await sem._waiterCount(priority: .behind)
        XCTAssertEqual(behindCountAfterElevate, 1, "A must have moved out of .behind")
        let visibleCountAfterElevate = await sem._waiterCount(priority: .visible)
        XCTAssertEqual(visibleCountAfterElevate, 1, "A must now be queued in .visible")

        await sem.signal()  // admits the sole .visible waiter (A) ahead of .behind
        _ = await taskA.value

        await sem.signal()  // admits the remaining .behind waiter (B)
        _ = await taskB.value

        XCTAssertEqual(
            lock.withLock { $0 }, ["A", "B"],
            "Elevated waiter A must be admitted before non-elevated waiter B"
        )
    }

    // MARK: - Test 9e: AsyncSemaphore.elevate with an id not queued in any lower tier is a
    // safe no-op (unknown id — never enqueued, or enqueued at/above the target already).

    func testSemaphoreElevateUnknownIdIsNoOp() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // take the only slot

        let queuedID = UUID()
        let waiterTask = Task {
            try? await sem.wait(id: queuedID, priority: .behind)
            await sem.signal()
        }
        while await sem._waiterCount(priority: .behind) < 1 { await Task.yield() }

        // Unrelated id — must not crash, and must not disturb the real waiter's tier.
        await sem.elevate(id: UUID(), to: .visible)

        let behindCountAfterNoOp = await sem._waiterCount(priority: .behind)
        XCTAssertEqual(behindCountAfterNoOp, 1, "Unknown-id elevate must not move the real waiter")
        let visibleCountAfterNoOp = await sem._waiterCount(priority: .visible)
        XCTAssertEqual(visibleCountAfterNoOp, 0, "Unknown-id elevate must not create a phantom .visible entry")

        await sem.signal()
        _ = await waiterTask.value
    }

    // MARK: - Test 9f: AsyncSemaphore.elevate targeting a waiter that already holds its slot
    // is a safe no-op — no crash, no double-signal, no count corruption.

    func testSemaphoreElevateAfterSlotAcquiredIsNoOpAndDoesNotDoubleSignal() async throws {
        let sem = AsyncSemaphore(value: 1)
        let id = UUID()
        try await sem.wait(id: id, priority: .behind)  // uncontended fast path — id holds the slot now

        // id is not queued anywhere (it already holds the slot) — elevate must no-op.
        await sem.elevate(id: id, to: .visible)

        let visibleCountWhileHeld = await sem._waiterCount(priority: .visible)
        XCTAssertEqual(visibleCountWhileHeld, 0)
        let behindCountWhileHeld = await sem._waiterCount(priority: .behind)
        XCTAssertEqual(behindCountWhileHeld, 0)

        await sem.signal()      // release the held slot — count goes 0 -> 1
        try await sem.wait()    // fresh wait() hits the fast path — proves count wasn't corrupted

        // Elevate again now that the same id has "completed" (released, no longer tracked
        // anywhere in the semaphore at all) — still a safe no-op.
        await sem.elevate(id: id, to: .visible)
        let visibleCountAfterCompletion = await sem._waiterCount(priority: .visible)
        XCTAssertEqual(visibleCountAfterCompletion, 0)
    }

    // MARK: - Test 9g: Cancelling a waiter AFTER it has been elevated to a different tier
    // still throws CancellationError and is fully removed — not just from its original tier
    // (VelocityUI-8nz fix-round regression: cancelWaiter must scan all tiers by id, since
    // elevate(id:to:) can have moved the waiter since wait() enqueued it).

    func testSemaphoreCancellationAfterElevationRemovesFromAllTiers() async throws {
        let sem = AsyncSemaphore(value: 0)  // no slots — every wait() blocks

        let idA = UUID()
        let taskA = Task<Void, any Error> {
            try await sem.wait(id: idA, priority: .behind)
        }
        while await sem._waiterCount(priority: .behind) < 1 { await Task.yield() }

        await sem.elevate(id: idA, to: .visible)

        let behindCountAfterElevate = await sem._waiterCount(priority: .behind)
        XCTAssertEqual(behindCountAfterElevate, 0, "A must have moved out of .behind")
        let visibleCountAfterElevate = await sem._waiterCount(priority: .visible)
        XCTAssertEqual(visibleCountAfterElevate, 1, "A must now be queued in .visible")

        // Cancel A while it sits in .visible — NOT the tier wait() originally enqueued it
        // into. A tier-hinted cancelWaiter(id:priority:) would look in .behind, find nothing,
        // and leave A neither removed nor resumed — the bug this test guards against.
        taskA.cancel()

        do {
            try await taskA.value
            XCTFail("Cancelled waiter must throw CancellationError even after elevation to a different tier")
        } catch is CancellationError {
            // Expected.
        }

        let behindCountAfterCancel = await sem._waiterCount(priority: .behind)
        XCTAssertEqual(behindCountAfterCancel, 0, "A must not reappear in its original tier")
        let visibleCountAfterCancel = await sem._waiterCount(priority: .visible)
        XCTAssertEqual(visibleCountAfterCancel, 0, "A must be removed from the tier it was elevated into")

        // A second signal() with no waiters left increments count. A fresh wait() must
        // then hit the uncontended fast path (not block) — confirms the cancelled waiter's
        // slot was never consumed (no count corruption from the elevation + cancellation).
        await sem.signal()
        try await sem.wait()
    }

    // MARK: - Test 10: Actor work runs on the dedicated serial executor

    func testActorRunsOnDedicatedExecutor() async {
        let actor = ImageActor()
        // Would trap (dispatchPrecondition) if unownedExecutor were removed and the
        // actor fell back to the cooperative pool.
        await actor.assertOnDedicatedExecutor()
    }

    // MARK: - Test 11: Pre-cancelled task returns nil without caching

    func testPreCancelledTaskReturnsNil() async throws {
        let url = try writeTempJPEG(width: 20, height: 20)
        defer { try? FileManager.default.removeItem(at: url) }

        let dimensions = DimensionCache()
        let actor = ImageActor(dimensionCache: dimensions)

        // Cancel before starting; the guard !Task.isCancelled check must fire first.
        let task = Task<CGImage?, Never> {
            // Yield once so the cancel registered above can propagate.
            await Task.yield()
            return await actor.image(
                for: url,
                targetSize: CGSize(width: 20, height: 20),
                cornerRadius: 0,
                scale: 1
            )
        }
        task.cancel()
        let result = await task.value

        XCTAssertNil(result, "Pre-cancelled task must return nil")
        // DimensionCache must not have been populated (decode never ran).
        XCTAssertNil(
            dimensions.get(url),
            "Cache must not be populated when task is cancelled before decode"
        )
    }

    // MARK: - Test 12: preload() warms cache so image() succeeds without a network request

    func testPreloadThenImageHitsCache() async throws {
        let data = jpegData(width: 40, height: 40)
        let url = URL(string: "https://test.preload.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        await actor.preload(data, for: url, targetSize: size, cornerRadius: 0, scale: 1)

        let result = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        XCTAssertNotNil(result, "image() must return the preloaded CGImage without hitting the network")
    }

    // MARK: - Test 13: corrupt preload data leaves cache empty; image() proceeds to decode

    func testPreloadBadDataSkipsCache() async throws {
        let url = try writeTempJPEG(width: 30, height: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 30, height: 30)
        let actor = ImageActor(dimensionCache: DimensionCache())

        await actor.preload(Data(count: 8), for: url, targetSize: size, cornerRadius: 0, scale: 1)

        let result = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        XCTAssertNotNil(result, "Bad preload data must not poison cache; image() must succeed via decode")
    }

    // MARK: - Test 14: pre-cancelled preload tasks do not exhaust the semaphore

    func testPreloadPreCancelledDoesNotLeakSemaphoreSlot() async throws {
        let data = jpegData(width: 20, height: 20)
        let url = URL(string: "https://test.preload.example/c.jpg")!
        let size = CGSize(width: 20, height: 20)
        let actor = ImageActor(dimensionCache: DimensionCache())

        for _ in 0..<3 {
            let t = Task {
                await Task.yield()
                await actor.preload(data, for: url, targetSize: size, cornerRadius: 0, scale: 1)
            }
            t.cancel()
            _ = await t.value
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await actor.preload(data, for: url, targetSize: size, cornerRadius: 0, scale: 1)
                }
            }
        }
    }

    // MARK: - Test 15: preload() populates DimensionCache with raw source dimensions

    func testPreloadPopulatesDimensionCache() async throws {
        let data = jpegData(width: 160, height: 120)
        let url = URL(string: "https://test.preload.example/d.jpg")!
        let dimensions = DimensionCache()
        let actor = ImageActor(dimensionCache: dimensions)

        XCTAssertNil(dimensions.get(url), "No entry before preload")
        await actor.preload(data, for: url, targetSize: CGSize(width: 80, height: 60), cornerRadius: 0, scale: 1)

        let stored = dimensions.get(url)
        XCTAssertNotNil(stored, "DimensionCache must be populated after preload")
        XCTAssertEqual(stored?.width,  160, "Must store raw source width, not thumbnail width")
        XCTAssertEqual(stored?.height, 120, "Must store raw source height, not thumbnail height")
    }

    // MARK: - Test 16: preload() and image() produce identical cache keys for fractional point sizes

    func testPreloadCacheKeyAlignmentFractional() async throws {
        let data = jpegData(width: 101, height: 162)
        let url = URL(string: "https://test.preload.example/e.jpg")!
        let size = CGSize(width: 50.4, height: 80.6)
        let scale: CGFloat = 2

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        await actor.preload(data, for: url, targetSize: size, cornerRadius: 8, scale: scale)

        let result = await actor.image(for: url, targetSize: size, cornerRadius: 8, scale: scale)
        XCTAssertNotNil(
            result,
            "image() must hit cache after preload() with identical fractional size+radius+scale"
        )
    }

    // MARK: - Test 18: prefetch() returns immediately on cache hit — no network request

    func testPrefetchCacheHitNoNetwork() async throws {
        CountingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let data = jpegData(width: 40, height: 40)
        let url = URL(string: "https://test.prefetch.cachehit.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)

        // Prime cache via preload() — no network involved.
        await actor.preload(data, for: url, targetSize: size, cornerRadius: 0, scale: 1)
        XCTAssertEqual(CountingURLProtocol.count, 0, "preload() must not use the network session")

        // prefetch() must detect the cache hit and return without a network request.
        await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .ahead)
        XCTAssertEqual(CountingURLProtocol.count, 0, "prefetch() on a cached key must not make a network request")
    }

    // MARK: - Test 19: prefetch() then image() returns cached CGImage — zero additional network calls

    func testPrefetchThenImageHitsCacheNoExtraNetwork() async throws {
        CountingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let url = URL(string: "https://test.prefetch.then.image.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)

        await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .ahead)
        XCTAssertEqual(CountingURLProtocol.count, 1, "prefetch() must make exactly one network request")

        let result = await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        XCTAssertNotNil(result, "image() must return the CGImage cached by prefetch()")
        XCTAssertEqual(CountingURLProtocol.count, 1, "image() after prefetch() must not make an additional network request")
    }

    // MARK: - Test 20: Concurrent prefetch() + image() coalesce to one network fetch

    func testPrefetchAndImageCoalesceToOneNetworkCall() async throws {
        CountingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let url = URL(string: "https://test.prefetch.coalesce.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)

        // prefetch returns Void; image returns CGImage?. Wrap both as CGImage? so the group
        // is typed and Swift 6 doesn't flag the captured-var mutation.
        let results = await withTaskGroup(of: CGImage?.self) { group in
            group.addTask { await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .ahead); return nil }
            group.addTask { return await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1) }
            var collected: [CGImage?] = []
            for await r in group { collected.append(r) }
            return collected
        }

        XCTAssertNotNil(results.compactMap { $0 }.first, "image() must return a valid CGImage")
        XCTAssertEqual(
            CountingURLProtocol.count,
            1,
            "Concurrent prefetch() + image() for the same key must coalesce to one network fetch"
        )
    }

    // MARK: - Test 21: Cancelling prefetch() calling Task does not cancel image() sharing the same inFlight entry

    func testPrefetchCancellationDoesNotCancelConcurrentImageTask() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BarrierURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let url = URL(string: "https://test.prefetch.cancel.barrier.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)

        // Gate: pauses image() before the cache/inFlight check. The hook signals when hit
        // (explicit happens-before anchor) then blocks until released.
        let imageHitSem = AsyncSemaphore(value: 0)
        let imageReleaseSem = AsyncSemaphore(value: 0)
        await actor.set_testDecodeGateHook {
            await imageHitSem.signal()
            try? await imageReleaseSem.wait()
        }
        defer { Task { await actor.set_testDecodeGateHook(nil) } }

        // Step 1: prefetch launches. Its inner Task calls session.data(from:).
        // BarrierURLProtocol blocks startLoading() until released.
        // inFlight[key] is set before the actor suspends at `await task.value`.
        let prefetchTask = Task {
            await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .ahead)
        }

        // Step 2: Block a background thread until the network request has started.
        // When this returns: inFlight[key] is populated, the actor is free.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                BarrierURLProtocol.waitForHit()
                cont.resume()
            }
        }

        // Step 3: image() launches and immediately hits the decode gate hook, suspending
        // before the cache or inFlight check.
        let imageTask = Task {
            await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        }
        // Step 3b: Explicit happens-before anchor — wait until imageTask has hit the gate.
        try await imageHitSem.wait()

        // Step 4: Release the gate. imageTask resumes, finds cache miss (inner Task still
        // blocked in BarrierURLProtocol), finds inFlight[key] HIT, and joins.
        await imageReleaseSem.signal()

        // Step 5: Cancel the prefetch calling Task. The inner Task<DecodeResult, Never>
        // is unstructured — cancellation does not propagate to it or to imageTask's
        // `await existing.value` on the same inFlight entry.
        prefetchTask.cancel()

        // Step 6: Release the network barrier. The inner Task receives data, decodes,
        // stores in cache. Both prefetch() and image() receive the DecodeResult.
        BarrierURLProtocol.release()

        let result = await imageTask.value
        _ = await prefetchTask.value

        XCTAssertNotNil(
            result,
            "image() must return a valid CGImage even when the concurrent prefetch() calling Task is cancelled while both share the same inFlight entry"
        )
    }

    // MARK: - Test 21a: A .visible image() decode acquires a slot before a queued .behind prefetch

    /// Trace + assertion:
    /// | Invariant | Assertion |
    /// |---|---|
    /// | After N `.behind` waiters are blocked on the 3 decode slots, a subsequently-requested `.visible` decode acquires a slot before any remaining `.behind` | `visibleTask` completes with a non-nil image while the queued `.behind` prefetch is still waiting (`_testDecodeSemaphoreWaiterCount(priority: .behind) == 1`) after only one slot is released |
    ///
    /// Method: fill all 3 decode slots with `.behind` prefetches held open at
    /// `_testDecodeBodyGateHook` (fires immediately after `decodeSemaphore.wait()` returns,
    /// slot already held — every invocation blocks here, not just the first 3, so the test
    /// can also catch and hold the `.visible` decode the instant it is admitted, before it
    /// finishes and releases its own slot). Queue a 4th `.behind` prefetch (blocks — slots
    /// exhausted), then a `.visible` image() call enqueued strictly after it. Release exactly
    /// one held slot and confirm the very next hook invocation — held before it can complete
    /// and cascade a second release — is the `.visible` call, with the earlier-queued
    /// `.behind` waiter still queued at that instant.
    func testVisibleDecodeJumpsAheadOfQueuedBehindPrefetch() async throws {
        CountingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let holderURLs = (0..<3).map { URL(string: "https://priority.holder.example/\($0).jpg")! }
        let queuedBehindURL = URL(string: "https://priority.queued.behind.example/x.jpg")!
        let visibleURL = URL(string: "https://priority.visible.example/x.jpg")!
        let size = CGSize(width: 20, height: 20)

        let atGate = AsyncSemaphore(value: 0)
        let holdGate = AsyncSemaphore(value: 0)
        await actor.set_testDecodeBodyGateHook {
            await atGate.signal()          // notify test: this decode now holds a slot
            try? await holdGate.wait()     // hold until the test explicitly releases it
        }
        defer { Task { await actor.set_testDecodeBodyGateHook(nil) } }

        // Fill all 3 decode slots. Each acquires its slot on the uncontended fast path
        // (count starts at 3) and blocks at the hook, holding it.
        for url in holderURLs {
            Task { await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .behind) }
        }
        for _ in 0..<3 { try? await atGate.wait() }

        // Queue a 4th .behind prefetch — slots exhausted, so it blocks in the .behind tier.
        // Confirm it actually reached the queue before proceeding.
        let queuedBehindTask = Task {
            await actor.prefetch(for: queuedBehindURL, targetSize: size, cornerRadius: 0, scale: 1, priority: .behind)
        }
        while await actor._testDecodeSemaphoreWaiterCount(priority: .behind) < 1 { await Task.yield() }

        // Queue a .visible image() call AFTER the .behind waiter — enqueued later, must
        // still be admitted first once a slot frees.
        let visibleTask = Task {
            await actor.image(for: visibleURL, targetSize: size, cornerRadius: 0, scale: 1)
        }
        while await actor._testDecodeSemaphoreWaiterCount(priority: .visible) < 1 { await Task.yield() }

        // Release exactly one held slot. Since only one waiter can be admitted, and every
        // hook invocation now blocks (including this one), waiting on atGate again anchors
        // precisely to "the admitted decode has acquired its slot and is held at the hook,
        // not yet completed" — before it could finish and cascade a second release that
        // would otherwise let the still-queued .behind waiter in too.
        await holdGate.signal()
        try? await atGate.wait()

        let behindWaiterCountAfterOneRelease = await actor._testDecodeSemaphoreWaiterCount(priority: .behind)
        XCTAssertEqual(
            behindWaiterCountAfterOneRelease, 1,
            "The .behind waiter must remain queued — the single released slot must have gone to .visible"
        )

        // Drain everything: the 2 remaining original holders, the now-held .visible decode,
        // and (once admitted) the queued .behind decode. Extra signals beyond what's needed
        // are harmless — AsyncSemaphore.signal() with no waiters just increments count.
        for _ in 0..<8 { await holdGate.signal() }

        let visibleResult = await visibleTask.value
        XCTAssertNotNil(visibleResult, "The .visible decode must be admitted and complete")
        await queuedBehindTask.value
    }

    // MARK: - Test 21b: A .visible image() joining an already-queued .behind prefetch's
    // inFlight decode elevates that decode's semaphore waiter to .visible — admitted ahead of
    // an independent .behind waiter that was queued earlier but never joined (VelocityUI-8nz).

    /// Trace + assertion:
    /// | Invariant | Assertion |
    /// |---|---|
    /// | `image()` joining an in-flight `.behind` prefetch elevates `inFlightDecodes[key]` to `.visible` | `actor._testInFlightDecodePriority(...) == .visible` right after the join |
    /// | The elevation moves the already-queued semaphore waiter out of `.behind` into `.visible` | `_testDecodeSemaphoreWaiterCount(.behind)` drops from 2 to 1; `_testDecodeSemaphoreWaiterCount(.visible)` becomes 1 |
    /// | The elevated (joined) decode is admitted ahead of the independent, never-joined `.behind` waiter | releasing exactly one slot leaves the independent `.behind` waiter still queued |
    func testVisibleImageJoinElevatesInFlightPrefetchAheadOfIndependentBehindWaiter() async throws {
        CountingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let holderURLs = (0..<3).map { URL(string: "https://elevate.holder.example/\($0).jpg")! }
        let joinedURL = URL(string: "https://elevate.joined.example/x.jpg")!
        let independentBehindURL = URL(string: "https://elevate.independent.behind.example/x.jpg")!
        let size = CGSize(width: 20, height: 20)

        let atGate = AsyncSemaphore(value: 0)
        let holdGate = AsyncSemaphore(value: 0)
        await actor.set_testDecodeBodyGateHook {
            await atGate.signal()
            try? await holdGate.wait()
        }
        defer { Task { await actor.set_testDecodeBodyGateHook(nil) } }

        // Fill all 3 decode slots so both waiters below must queue.
        for url in holderURLs {
            Task { await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .behind) }
        }
        for _ in 0..<3 { try? await atGate.wait() }

        // This prefetch is the one that will later be JOINED by a .visible image() call —
        // "prefetch started it, now it's on screen". Queues at .behind (slots exhausted).
        let joinedPrefetchTask = Task {
            await actor.prefetch(for: joinedURL, targetSize: size, cornerRadius: 0, scale: 1, priority: .behind)
        }
        while await actor._testDecodeSemaphoreWaiterCount(priority: .behind) < 1 { await Task.yield() }

        // An independent .behind prefetch — never joined by anything — must stay put.
        let independentBehindTask = Task {
            await actor.prefetch(for: independentBehindURL, targetSize: size, cornerRadius: 0, scale: 1, priority: .behind)
        }
        while await actor._testDecodeSemaphoreWaiterCount(priority: .behind) < 2 { await Task.yield() }

        // The .visible image() call joins the SAME key as joinedPrefetchTask (same URL/size/
        // radius/scale) — it must hit the inFlight coalescing path and elevate.
        let visibleJoinTask = Task {
            await actor.image(for: joinedURL, targetSize: size, cornerRadius: 0, scale: 1)
        }
        while await actor._testDecodeSemaphoreWaiterCount(priority: .visible) < 1 { await Task.yield() }

        let joinedPriorityAfterElevate = await actor._testInFlightDecodePriority(url: joinedURL, targetSize: size, cornerRadius: 0, scale: 1)
        XCTAssertEqual(
            joinedPriorityAfterElevate,
            .visible,
            "Joining a .visible image() call must elevate the in-flight admission record to .visible"
        )
        let behindCountAfterElevate = await actor._testDecodeSemaphoreWaiterCount(priority: .behind)
        XCTAssertEqual(
            behindCountAfterElevate, 1,
            "The joined decode must have moved OUT of .behind, leaving only the independent waiter"
        )

        // Release exactly one held slot. Every hook invocation blocks (holders included), so
        // waiting on atGate again anchors precisely to "the admitted decode is held at the
        // hook" before it could finish and cascade a second release.
        await holdGate.signal()
        try? await atGate.wait()

        let behindCountAfterOneRelease = await actor._testDecodeSemaphoreWaiterCount(priority: .behind)
        XCTAssertEqual(
            behindCountAfterOneRelease, 1,
            "The independent .behind waiter must remain queued — the released slot went to the elevated (now .visible) joined decode"
        )

        // Drain everything.
        for _ in 0..<8 { await holdGate.signal() }

        let visibleResult = await visibleJoinTask.value
        XCTAssertNotNil(visibleResult, "The joined+elevated decode must complete and image() must return a valid CGImage")
        await joinedPrefetchTask.value
        await independentBehindTask.value
    }

    // MARK: - Test 21c: A .visible image() join that lands while the prefetch decode is still
    // in its network-fetch phase (before it has even reached decodeSemaphore.wait()) elevates
    // inFlightDecodes[key] in time for _decode()'s admission read — the decode goes straight
    // into the .visible tier and never touches .behind at all (VelocityUI-8nz).

    func testVisibleImageJoinDuringNetworkPhaseElevatesBeforeDecodeReachesSemaphore() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BarrierURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let holderURLs = (0..<3).map { URL(string: "https://elevate.network.holder.example/\($0).jpg")! }
        let sharedURL = URL(string: "https://elevate.network.shared.example/x.jpg")!
        let size = CGSize(width: 20, height: 20)

        let atGate = AsyncSemaphore(value: 0)
        let holdGate = AsyncSemaphore(value: 0)
        await actor.set_testDecodeBodyGateHook {
            await atGate.signal()
            try? await holdGate.wait()
        }
        defer { Task { await actor.set_testDecodeBodyGateHook(nil) } }

        // Fill all 3 decode slots via holder prefetches. Each blocks momentarily in
        // BarrierURLProtocol; release the network barrier for each immediately so they reach
        // the decode body hook and hold their slot there.
        var holderTasks: [Task<Void, Never>] = []
        for url in holderURLs {
            holderTasks.append(Task {
                await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .behind)
            })
        }
        for _ in holderURLs {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    BarrierURLProtocol.waitForHit()
                    cont.resume()
                }
            }
            BarrierURLProtocol.release()
        }
        for _ in 0..<3 { try? await atGate.wait() }

        // Launch the prefetch that will be joined. Its network fetch blocks in
        // BarrierURLProtocol — it has NOT reached decodeSemaphore.wait() yet.
        let prefetchTask = Task {
            await actor.prefetch(for: sharedURL, targetSize: size, cornerRadius: 0, scale: 1, priority: .behind)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                BarrierURLProtocol.waitForHit()
                cont.resume()
            }
        }

        // Join with a .visible image() call while the decode is still stuck in the network
        // phase — inFlight[key] is populated, but inFlightDecodes[key] still reads .behind
        // and the semaphore has no waiter for this id yet (elevate() will no-op on the
        // semaphore side, but the actor-side record updates synchronously).
        let imageTask = Task {
            await actor.image(for: sharedURL, targetSize: size, cornerRadius: 0, scale: 1)
        }
        while await actor._testInFlightDecodePriority(url: sharedURL, targetSize: size, cornerRadius: 0, scale: 1) != .visible {
            await Task.yield()
        }

        // Release the network barrier. The decode proceeds into _decode(), reads the
        // (already-elevated) admission record, and calls wait(priority: .visible) directly —
        // it must queue straight into .visible, never touching .behind.
        BarrierURLProtocol.release()

        while await actor._testDecodeSemaphoreWaiterCount(priority: .visible) < 1 { await Task.yield() }
        let behindCountAfterNetworkPhaseElevation = await actor._testDecodeSemaphoreWaiterCount(priority: .behind)
        XCTAssertEqual(
            behindCountAfterNetworkPhaseElevation, 0,
            "The network-phase-elevated decode must never enqueue in .behind — it should read .visible before its first wait() call"
        )

        for _ in 0..<8 { await holdGate.signal() }

        let imageResult = await imageTask.value
        XCTAssertNotNil(imageResult, "The network-phase-elevated join must complete and image() must return a valid CGImage")
        await prefetchTask.value
        for t in holderTasks { await t.value }
    }

    // MARK: - Test 22: prefetch() populates DimensionCache with raw source dimensions

    func testPrefetchPopulatesDimensionCache() async throws {
        CountingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache()
        let actor = ImageActor(session: session, dimensionCache: dc)

        let url = URL(string: "https://test.prefetch.dimcache.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)

        XCTAssertNil(dc.get(url), "DimensionCache must be empty before prefetch()")
        await actor.prefetch(for: url, targetSize: size, cornerRadius: 0, scale: 1, priority: .ahead)

        // CountingURLProtocol returns a 2×2 JPEG; raw source dimensions must be stored.
        let stored = dc.get(url)
        XCTAssertNotNil(stored, "prefetch() must populate DimensionCache as a decode-time side effect")
        XCTAssertEqual(stored?.width, 2, "Must store raw source width, not render-target width")
        XCTAssertEqual(stored?.height, 2, "Must store raw source height, not render-target height")
    }

    // MARK: - Test 23: Cache-key alignment — prefetch() + image() with fractional point sizes

    func testPrefetchCacheKeyAlignmentFractional() async throws {
        CountingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let url = URL(string: "https://test.prefetch.keyfrac.example/a.jpg")!
        let size = CGSize(width: 50.4, height: 80.6)
        let scale: CGFloat = 2

        await actor.prefetch(for: url, targetSize: size, cornerRadius: 8, scale: scale, priority: .ahead)
        XCTAssertEqual(CountingURLProtocol.count, 1, "prefetch() must make exactly one network request")

        // image() with identical fractional params must hit the cache and not re-fetch.
        let result = await actor.image(for: url, targetSize: size, cornerRadius: 8, scale: scale)
        XCTAssertNotNil(
            result,
            "image() must hit cache after prefetch() with identical fractional size + radius + scale"
        )
        XCTAssertEqual(
            CountingURLProtocol.count,
            1,
            "image() after prefetch() with same fractional params must not make an additional network request"
        )
    }

    // MARK: - Test 24: cachedImage() returns non-nil from a non-actor context after warm-up

    func testCachedImageNonNilAfterWarmUp() async throws {
        let data = jpegData(width: 40, height: 40)
        let url = URL(string: "https://test.cachedimage.hit.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)
        let actor = ImageActor(dimensionCache: DimensionCache())

        await actor.preload(data, for: url, targetSize: size, cornerRadius: 0, scale: 1)

        // XCTestCase is nonisolated — exercises the non-actor call path.
        let result = actor.cachedImage(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        XCTAssertNotNil(result, "cachedImage() must return non-nil for a warmed cache entry")
    }

    // MARK: - Test 25: cachedImage() returns nil on a cold cache

    func testCachedImageNilOnColdCache() {
        let url = URL(string: "https://test.cachedimage.cold.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)
        let actor = ImageActor(dimensionCache: DimensionCache())

        let result = actor.cachedImage(for: url, targetSize: size, cornerRadius: 0, scale: 1)
        XCTAssertNil(result, "cachedImage() must return nil on a cold cache")
    }

    // MARK: - Test 17: Concurrent same-key image() calls coalesce to one network fetch

    func testImageCoalescesConcurrentSameURLRequests() async throws {
        CountingURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        let actor = ImageActor(session: session, dimensionCache: DimensionCache())

        let url = URL(string: "https://test.coalesce.example/a.jpg")!
        let size = CGSize(width: 40, height: 40)

        let results = await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
            }
            group.addTask {
                await actor.image(for: url, targetSize: size, cornerRadius: 0, scale: 1)
            }
            var collected: [CGImage?] = []
            for await r in group { collected.append(r) }
            return collected
        }

        let nonNilCount = results.compactMap { $0 }.count
        XCTAssertEqual(nonNilCount, 2, "Both concurrent callers must receive a non-nil image")
        XCTAssertEqual(
            CountingURLProtocol.count, 1,
            "In-flight coalescing must collapse N concurrent same-key requests to one network fetch"
        )
    }
}
#endif

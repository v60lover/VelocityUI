// ImageActorTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
import CoreGraphics
import os
@testable import VelocityUI

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

final class ImageActorTests: XCTestCase {

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

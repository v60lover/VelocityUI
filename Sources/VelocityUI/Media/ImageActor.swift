// ImageActor.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO
import os

// MARK: - Debug logger

#if DEBUG
private let log = Logger(subsystem: "com.velocityui", category: "ImageActor")
#endif

// MARK: - Private helpers

private struct DecodeResult: @unchecked Sendable {
    let image: CGImage?
    let rawSourceSize: CGSize?  // pixel dimensions from source header, for DimensionCache
}

private final class ImageCacheKey: NSObject {
    let url: URL
    let pixelWidth: Int    // Int(targetSize.width * scale, rounded) — avoids CGFloat equality
    let pixelHeight: Int
    let scaledRadius: Int  // Int(cornerRadius * scale, rounded)

    init(url: URL, targetSize: CGSize, cornerRadius: CGFloat, scale: CGFloat) {
        self.url = url
        self.pixelWidth = pixelLength(targetSize.width, scale: scale)
        self.pixelHeight = pixelLength(targetSize.height, scale: scale)
        self.scaledRadius = pixelLength(cornerRadius, scale: scale)
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ImageCacheKey else { return false }
        return url == other.url
            && pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
            && scaledRadius == other.scaledRadius
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(url)
        h.combine(pixelWidth)
        h.combine(pixelHeight)
        h.combine(scaledRadius)
        return h.finalize()
    }
}

private final class CachedImage {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

// MARK: - ImageActor

/// Layer 4 image pipeline: network fetch (cooperative pool) → bounded concurrent decode
/// (dedicated DispatchQueue, max 3 simultaneous via AsyncSemaphore) → BGRA8888 normalise
/// + corner-round → NSCache.
///
/// Design invariants:
/// - Network and decode run on separate executors. URLSession suspends on the cooperative
///   pool (no thread held). CGImageSource decode runs on the dedicated concurrent queue.
///   A serial pipeline doing 200ms network + 5ms decode would be 2.5% utilised and starve
///   visible-priority decodes under burst load.
/// - AsyncSemaphore(value: 3) caps concurrent decode closures so decode bursts cannot
///   exhaust cooperative pool threads needed by measureNode (contract clause 3).
/// - Cache key is (url, pixelWidth, pixelHeight, scaledRadius) — integer pixels eliminate
///   CGFloat equality hazards and collapse (50pt @2x, 100pt @1x) to the same entry.
/// - DimensionCache.store() receives the raw source dimensions from the image header —
///   not the render-size thumbnail — so classify() gets the true aspect ratio for any
///   future layout size without a secondary ranged probe.
/// - No singleton. Constructed once in RenderEnvironment, injected by initializer.
public actor ImageActor {
    nonisolated let _executor: DispatchQueueExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        _executor.asUnownedSerialExecutor()
    }

    private let decodeQueue = DispatchQueue(
        label: "velocityui.image.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let decodeSemaphore = AsyncSemaphore(value: 3)

    private let cache = NSCache<ImageCacheKey, CachedImage>()
    private let session: URLSession
    /// `nonisolated` so RenderEnvironment can check identity (===) in its designated init.
    nonisolated let dimensionCache: DimensionCache

    /// - Parameters:
    ///   - session:        URLSession for image fetches. Defaults to `.shared`; tests can
    ///                     inject a custom session.
    ///   - dimensionCache: Cache for raw source dimensions. Must be the same instance
    ///                     used by classify() — separate instances break the hit contract.
    ///                     Callers should obtain this from RenderEnvironment, not construct it here.
    public init(
        session: URLSession = .shared,
        dimensionCache: DimensionCache
    ) {
        self._executor = DispatchQueueExecutor(label: "velocityui.image.actor")
        // 64 MB cap. At 4 bytes/pixel: a 400×800-pt image at scale 3 costs ~11.5 MB
        // (~5 images at production density). At scale 1 (tests) it costs ~1.2 MB.
        cache.totalCostLimit = 64 * 1024 * 1024
        self.session = session
        self.dimensionCache = dimensionCache
        #if canImport(XCTest)
        // Tag decodeQueue so the async closure can verify it is on the right queue.
        decodeQueue.setSpecific(key: _testDecodeQueueKey, value: true)
        #endif
    }

    /// Test-only convenience: creates a private DimensionCache not shared with any other
    /// collaborator. Use only in unit tests that don't verify classify() hit behaviour.
    init() {
        self.init(dimensionCache: DimensionCache())
    }

    // MARK: - Test hooks

    #if canImport(XCTest)
    /// DispatchSpecificKey set on decodeQueue so the decode closure can assert
    /// it is running on the expected queue rather than the cooperative pool.
    /// Captured as a local before `withCheckedContinuation` to avoid retaining `self` in the async closure.
    nonisolated let _testDecodeQueueKey = DispatchSpecificKey<Bool>()

    /// Counts decode closures that ran on velocityui.image.decode (expected) vs other queues.
    /// Protected by _testDecodeLock — lock makes writes safe across concurrent Task/queue threads.
    /// Pattern matches NodeTable._itemIDCounter — nonisolated(unsafe) is the lesser violation.
    ///
    /// Serial-test invariant: these static counters assume one ImageActor instance is under
    /// test at a time and no concurrent test-suite processes share them. Call
    /// _testDecodeResetCounts() before each test that reads these values. Any test that reads
    /// the counters while a concurrent test target could be running decodes will produce
    /// false-passing or under-counted results.
    nonisolated(unsafe) private static let _testDecodeLock = NSLock()
    nonisolated(unsafe) static var _testDecodeOnQueueCount: Int = 0
    nonisolated(unsafe) static var _testDecodeTotalCount: Int = 0

    nonisolated static func _testDecodeRecord(onQueue: Bool) {
        ImageActor._testDecodeLock.lock()
        defer { ImageActor._testDecodeLock.unlock() }
        ImageActor._testDecodeTotalCount += 1
        if onQueue { ImageActor._testDecodeOnQueueCount += 1 }
    }

    /// Reset counters before each test that checks decode queue isolation.
    nonisolated static func _testDecodeResetCounts() {
        ImageActor._testDecodeLock.lock()
        defer { ImageActor._testDecodeLock.unlock() }
        ImageActor._testDecodeOnQueueCount = 0
        ImageActor._testDecodeTotalCount = 0
    }

    /// Injected by unit tests to interpose before `image()` returns.
    ///
    /// When non-nil, `image()` suspends at this hook before the cache-hit check.
    /// The hook is `@Sendable async` but does NOT check `Task.isCancelled` internally —
    /// callers control the resume point explicitly. This lets tests hold the decode
    /// in-flight until after a cross-item recycle, then deliver the image to exercise
    /// the `applyContent` privacy guard.
    ///
    /// Set only from test code via `@testable import VelocityUI`. Never set in production.
    var _testDecodeGateHook: (@Sendable () async -> Void)?

    /// Sets `_testDecodeGateHook` from test code. Actor-isolated setter so the assignment
    /// is safe across executor boundaries (tests call `await actor.set_testDecodeGateHook(...)`).
    func set_testDecodeGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testDecodeGateHook = hook
    }
    #endif

    // MARK: - Public API

    /// Fetch and decode an image for `url`.
    ///
    /// - Parameters:
    ///   - url:          Source URL (file:// and https:// supported).
    ///   - targetSize:   Desired render size in points (not pixels).
    ///   - cornerRadius: Rounding radius in points, applied at decode time via CGContext
    ///                   clip. Pass 0 for no rounding.
    ///   - scale:        Screen scale (points → pixels). Must be captured from UIScreen at
    ///                   the @MainActor call site — UIScreen.main is not safe off main.
    /// - Returns: BGRA8888 premultiplied CGImage, or nil on error / cancellation.
    public func image(
        for url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) async -> CGImage? {
        #if canImport(XCTest)
        // Test gate: suspend here before any work so the test can control when this call
        // proceeds relative to a cross-item recycle. The hook is NOT cancellation-aware —
        // it suspends until the test explicitly signals, regardless of Task.isCancelled.
        if let hook = _testDecodeGateHook { await hook() }
        #endif

        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: scale)

        // 1. Cache hit — O(1), no allocation on the hot path.
        if let hit = cache.object(forKey: key) { return hit.image }

        // 2. Before-network cancellation check.
        guard !Task.isCancelled else { return nil }

        // 3. Network fetch on the cooperative pool (URLSession suspends, no thread held).
        #if DEBUG
        let networkStart = CFAbsoluteTimeGetCurrent()
        #endif
        guard let (data, response) = try? await session.data(from: url) else { return nil }

        // 3a. Reject non-2xx: HTML error bodies waste a decode slot and fail at CGImageSource.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        #if DEBUG
        let networkMs = (CFAbsoluteTimeGetCurrent() - networkStart) * 1_000
        log.debug("network \(url.lastPathComponent) \(String(format: "%.1f", networkMs))ms")
        #endif

        // 4. After-network cancellation check.
        guard !Task.isCancelled else { return nil }

        // 5. Acquire a decode slot. Throws CancellationError if cancelled while waiting;
        //    the slot is never consumed on the thrown path — do NOT call signal().
        do {
            try await decodeSemaphore.wait()
        } catch {
            return nil
        }

        // 5a. Cancellation check after semaphore acquire — a cancellation arriving between
        //     wait() and the dispatch enqueue would otherwise spend a slot on dead work.
        guard !Task.isCancelled else {
            Task { await decodeSemaphore.signal() }
            return nil
        }

        // 6. Decode on the dedicated concurrent queue via dispatch-and-resume.
        //    withCheckedContinuation is safe: every DispatchQueue.async path calls
        //    cont.resume exactly once (explicit success path + guard-else paths).
        let sem = decodeSemaphore
        #if canImport(XCTest)
        // Capture key here (actor-isolated context) so the @Sendable async closure
        // can call DispatchQueue.getSpecific without retaining self.
        let capturedQueueKey = _testDecodeQueueKey
        #endif
        let result: DecodeResult = await withCheckedContinuation { cont in
            let capturedData = data
            let capturedSize = targetSize
            let capturedRadius = cornerRadius
            let capturedScale = scale
            let capturedUrl = url

            // TODO(VelocityUI-vim+): decodeQueue runs at .userInitiated regardless of the
            // calling Task's priority. Prefetch decodes should run at .utility. Deferred to
            // fling-handling.
            decodeQueue.async {
                #if canImport(XCTest)
                // Verify we are running on velocityui.image.decode (not the cooperative pool).
                let onDecodeQueue = DispatchQueue.getSpecific(key: capturedQueueKey) == true
                ImageActor._testDecodeRecord(onQueue: onDecodeQueue)
                #endif
                #if DEBUG
                let decodeStart = CFAbsoluteTimeGetCurrent()
                #endif
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelLength(
                        max(capturedSize.width, capturedSize.height),
                        scale: capturedScale
                    ),
                    kCGImageSourceShouldCache: false,
                ]

                guard let src = CGImageSourceCreateWithData(capturedData as CFData, nil) else {
                    Task { await sem.signal() }
                    cont.resume(returning: DecodeResult(image: nil, rawSourceSize: nil))
                    return
                }

                // Raw pixel dimensions from the image header — stored in DimensionCache to give
                // classify() the true aspect ratio for future layouts at any size, without
                // triggering a secondary ranged probe. Must be read from src, not the thumbnail.
                let rawSize: CGSize? = {
                    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                    guard
                        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                        w > 0, h > 0
                    else { return nil }
                    return CGSize(width: w, height: h)
                }()

                guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                    Task { await sem.signal() }
                    // rawSourceSize intentionally nil: don't populate DimensionCache for a
                    // URL whose decode failed — a cached dimension with no paintable image
                    // would let classify() size a row that can never be filled.
                    cont.resume(returning: DecodeResult(image: nil, rawSourceSize: nil))
                    return
                }

                let normalised = normaliseAndRound(
                    thumb,
                    targetSize: capturedSize,
                    cornerRadius: capturedRadius,
                    scale: capturedScale
                )
                #if DEBUG
                let decodeMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1_000
                log.debug("decode \(capturedUrl.lastPathComponent) \(String(format: "%.1f", decodeMs))ms")
                #endif
                // Release the slot BEFORE resuming so the next waiter can acquire it without
                // waiting for the continuation-resume actor hop (compresses tail latency in
                // 50-decode bursts — M3).
                Task { await sem.signal() }
                cont.resume(returning: DecodeResult(image: normalised, rawSourceSize: rawSize))
            }
        }

        // 7. Cache store + DimensionCache side-effect.
        if let decoded = result.image {
            let cost = decoded.width * decoded.height * 4
            cache.setObject(CachedImage(decoded), forKey: key, cost: cost)
            if let rawSize = result.rawSourceSize {
                dimensionCache.store(rawSize, for: url)
            }
        }

        return result.image
    }

    /// Cancel fetches below the visible range.
    /// Phase 1: no-op body. Real priority bookkeeping deferred to fling-handling (Phase 3+).
    public func cancelBelowVisible() {}

    /// Trap if the caller is not on velocityui.image.actor. For use in tests and
    /// debug assertions only — proves the custom executor is active and not silently
    /// replaced by the cooperative pool (e.g. by removing unownedExecutor).
    func assertOnDedicatedExecutor() {
        _executor.checkIsolated()
    }
}
#endif

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

// MARK: - Module-internal types

/// Parameters identifying a prefetch task for batch-cancel by RenderPipeline.
struct PrefetchSpec: Sendable {
    let url: URL
    let targetSize: CGSize
    let cornerRadius: CGFloat
    let scale: CGFloat
}

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
/// - Concurrent requests for the same (url, size, radius, scale) key share one decode
///   `Task` via an `inFlight` map — both `image()` and `preload()` coalesce against it.
///   Mirrors DimensionCache's coalescing pattern: creator handles cache store; joiners await
///   the result.
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
    private static let maxConcurrentDecodes = 3
    private let decodeSemaphore = AsyncSemaphore(value: ImageActor.maxConcurrentDecodes)

    /// Upper bound on the scale (screen points → pixels) used for both the cache key and the
    /// decode target size. Real display scale (e.g. 3x on Pro-class devices) is clamped down
    /// to this ceiling before it reaches `ImageCacheKey`, `_decode`, or `normaliseAndRound` —
    /// shrinking bitmap area by (realScale/ceiling)^2 and letting the 64 MB NSCache hold
    /// proportionally more images. Pass 3.0 (or higher) to disable the cap. See VelocityUI-zgs.
    nonisolated let decodeScaleCeiling: CGFloat

    // nonisolated(unsafe): NSCache guarantees thread-safe concurrent reads and writes.
    // The reference itself never rebinds (let), and all mutating paths run on the actor
    // executor, so data-race safety holds without an additional lock.
    // Required for cachedImage() — a nonisolated synchronous probe on the hot path.
    nonisolated(unsafe) private let cache = NSCache<ImageCacheKey, CachedImage>()
    private var inFlight: [ImageCacheKey: Task<DecodeResult, Never>] = [:]
    private let session: URLSession
    /// `nonisolated` so RenderEnvironment can check identity (===) in its designated init.
    nonisolated let dimensionCache: DimensionCache

    /// - Parameters:
    ///   - session:            URLSession for image fetches. Defaults to `.shared`; tests can
    ///                         inject a custom session.
    ///   - dimensionCache:     Cache for raw source dimensions. Must be the same instance
    ///                         used by classify() — separate instances break the hit contract.
    ///                         Callers should obtain this from RenderEnvironment, not construct it here.
    ///   - decodeScaleCeiling: Upper bound on decode scale. Defaults to 2.0 — see the property's
    ///                         docstring. Pass 3.0+ to decode at full display scale.
    public init(
        session: URLSession = .shared,
        dimensionCache: DimensionCache,
        decodeScaleCeiling: CGFloat = 2.0
    ) {
        self._executor = DispatchQueueExecutor(label: "velocityui.image.actor")
        // 64 MB cap. At 4 bytes/pixel: a 400×800-pt image at scale 3 costs ~11.5 MB
        // (~5 images at production density). At scale 1 (tests) it costs ~1.2 MB.
        cache.totalCostLimit = 64 * 1024 * 1024
        self.session = session
        self.dimensionCache = dimensionCache
        self.decodeScaleCeiling = decodeScaleCeiling
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

    /// Injected by unit tests to interpose in `preload()` before the decode Task is created —
    /// fires after the in-flight coalescing check and the pre-launch cancellation guard.
    ///
    /// When non-nil, `preload()` suspends at this hook. Cancelling the outer task during this
    /// hook has no effect on the inner decode Task (unstructured; does not inherit cancellation).
    /// Use to observe actor state at the inFlight boundary, not to test slot-release under
    /// cancellation (for that, see VelocityUI-bw1: hook inside `_decode()` after wait()).
    ///
    /// Set only from test code via `@testable import VelocityUI`. Never set in production.
    var _testPreloadGateHook: (@Sendable () async -> Void)?

    /// Sets `_testPreloadGateHook` from test code.
    func set_testPreloadGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testPreloadGateHook = hook
    }

    /// Injected by unit tests to interpose in `prefetch()` before the inner decode Task is
    /// created — fires after the in-flight coalescing check and the pre-launch cancellation
    /// guard. Use to observe actor state at the inFlight boundary.
    ///
    /// Set only from test code via `@testable import VelocityUI`. Never set in production.
    var _testPrefetchGateHook: (@Sendable () async -> Void)?

    /// Sets `_testPrefetchGateHook` from test code.
    func set_testPrefetchGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testPrefetchGateHook = hook
    }

    /// Injected by unit tests to interpose in `_decode()` after `decodeSemaphore.wait()`
    /// returns and before `withCheckedContinuation`. Fires with the semaphore slot already
    /// held — cancel the inner Task during this hook then signal, and verify the slot is
    /// released (subsequent wait() calls must succeed). Gates the `image()`, `preload()`,
    /// and `prefetch()` paths since all three funnel through `_decode()` (both `image()`
    /// and `prefetch()` via `_networkFetchAndDecode`).
    ///
    /// Set only from test code via `@testable import VelocityUI`. Never set in production.
    var _testDecodeBodyGateHook: (@Sendable () async -> Void)?

    func set_testDecodeBodyGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testDecodeBodyGateHook = hook
    }

    /// URLs that reached the cold-path inside `prefetch()` — populated after the
    /// inFlight/cache checks pass and before the inner Task is created.
    /// Actor-isolated; access with `await actor._testGetPrefetchedURLs()`.
    private(set) var _testPrefetchedURLs: [URL] = []

    func _testGetPrefetchedURLs() -> [URL] { _testPrefetchedURLs }
    func _testResetPrefetchedURLs() { _testPrefetchedURLs.removeAll() }
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
    /// - Returns: BGRA8888 premultiplied CGImage, or nil on error or pre-launch cancellation.
    ///   If an in-flight task for this key is already running, returns its result regardless
    ///   of the calling task's cancellation state (shared work is not killed for one caller).
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

        let decodeScale = min(scale, decodeScaleCeiling)
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale)

        // 1. Cache hit — O(1), no allocation on the hot path.
        if let hit = cache.object(forKey: key) { return hit.image }

        // 2. Join an existing in-flight task for the same key rather than launching a
        //    second network fetch + decode — creator handles cache store.
        if let existing = inFlight[key] {
            let result = await existing.value
            return result.image
        }

        // 3. Before-launch cancellation check.
        guard !Task.isCancelled else { return nil }

        // 4. Launch a task that owns the network fetch + decode for this key.
        let task = Task<DecodeResult, Never> {
            await self._networkFetchAndDecode(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        // 5. Cache store + DimensionCache side-effect.
        if let decoded = result.image {
            let cost = decoded.width * decoded.height * 4
            cache.setObject(CachedImage(decoded), forKey: key, cost: cost)
            if let rawSize = result.rawSourceSize {
                dimensionCache.store(rawSize, for: url)
            }
        }

        return result.image
    }

    /// Decode pre-loaded Data and prime the image cache at the given layout dimensions.
    ///
    /// Equivalent to steps 1 + 5–7 of `image(for:targetSize:cornerRadius:scale:)` — the decode
    /// and cache-store path — without the network fetch (steps 3–4a). Shared with `image()` to
    /// cap total decode concurrency at 3 — preload and visible-cell decodes draw from one slot
    /// pool. FIFO ordering means a preload burst can delay a concurrent `image()` call; intended
    /// for one-shot warm-up before the visible feed begins fetching.
    ///
    /// - Parameters:
    ///   - data:         Raw image bytes (caller-supplied; not fetched here).
    ///   - url:          Canonical URL the data originated from. Must match the URL later passed
    ///                   to `image(for:…)` so the cache key aligns and produces a hit.
    ///   - targetSize:   Desired render size in points — must match the layout-computed size used
    ///                   at measurement time, or the cache key will miss.
    ///   - cornerRadius: Rounding radius in points, applied at decode time. Pass 0 for none.
    ///   - scale:        Screen scale captured at a @MainActor call site.
    /// - Note: Bad data (nil CGImageSource or thumbnail failure) silently skips the cache store;
    ///         the caller receives no signal. Verify warm-up success by probing image(for:…)
    ///         before measurement begins.
    /// - Note: Concurrent calls for the same key join the in-flight decode — only one decode
    ///         Task runs per key at a time. Use during warm-up before the visible feed begins.
    public func preload(
        _ data: Data,
        for url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) async {
        let decodeScale = min(scale, decodeScaleCeiling)
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale)

        if cache.object(forKey: key) != nil { return }

        // Join an existing in-flight task for the same key — creator handles cache store.
        if let existing = inFlight[key] {
            _ = await existing.value
            return
        }

        guard !Task.isCancelled else { return }

        #if canImport(XCTest)
        if let hook = _testPreloadGateHook { await hook() }
        #endif

        let capturedData = data
        let capturedTargetSize = targetSize
        let capturedCornerRadius = cornerRadius
        let capturedScale = decodeScale
        let task = Task<DecodeResult, Never> {
            await self._decode(
                data: capturedData,
                targetSize: capturedTargetSize,
                cornerRadius: capturedCornerRadius,
                scale: capturedScale
            )
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let decoded = result.image {
            let cost = decoded.width * decoded.height * 4
            cache.setObject(CachedImage(decoded), forKey: key, cost: cost)
            if let rawSize = result.rawSourceSize {
                dimensionCache.store(rawSize, for: url)
            }
        }
    }

    /// Network-fetch, decode, and cache an image at lower scheduling priority.
    ///
    /// - Cache hit → returns immediately (no work).
    /// - In-flight hit → joins the existing Task (from a concurrent `image()` or `prefetch()`);
    ///   the shared `inFlight` map keyed by `ImageCacheKey` guarantees coalescing across all
    ///   entry points. Creator handles cache store; joiners await the result.
    /// - Cold path → network fetch → decode via `_networkFetchAndDecode` → normalise +
    ///   corner-round → cache store + `DimensionCache.store()` side-effect. Same pipeline
    ///   as `image()`; return value is discarded.
    /// - QoS: inner Task runs at `.utility` so the cooperative scheduler deprioritises
    ///   prefetch network waits relative to mount-time `image()` callers (`.userInitiated`).
    ///   `decodeQueue` always runs at `.userInitiated` (shared; see TODO in `_decode`).
    ///   URLSession connection pool is shared — QoS differentiation is effective at the
    ///   cooperative pool scheduler layer only, not at TCP/TLS or server-side ordering.
    /// - Cancellation: `await task.value` on `Task<DecodeResult, Never>` does not throw on
    ///   cancellation; `prefetch()` awaits the inner Task regardless. The inner Task is
    ///   unstructured — cancelling the calling Task of `prefetch()` does NOT cancel the
    ///   inner Task or any concurrent `image()` awaiting the same inFlight entry.
    ///
    /// - Parameters:
    ///   - url:          Source URL.
    ///   - targetSize:   Desired render size in points — must match the size passed to the
    ///                   paired `image(for:…)` call so the cache key aligns.
    ///   - cornerRadius: Rounding radius in points. Pass 0 for no rounding.
    ///   - scale:        Screen scale captured at a @MainActor call site.
    ///   - isCurrent:    Optional generation-guard closure. Called immediately before the
    ///                   inner decode Task is spawned — no await between the check and the
    ///                   spawn. Returns `false` when the originating prefetch batch has been
    ///                   superseded by a newer `onIndexBoundary` call; the fetch is abandoned
    ///                   without starting any network work. Pass `nil` to skip the guard
    ///                   (backwards-compatible default).
    public func prefetch(
        for url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat,
        isCurrent: (@Sendable () -> Bool)? = nil
    ) async {
        let decodeScale = min(scale, decodeScaleCeiling)
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale)

        if cache.object(forKey: key) != nil { return }

        if let existing = inFlight[key] {
            _ = await existing.value
            return
        }

        guard !Task.isCancelled else { return }

        #if canImport(XCTest)
        if let hook = _testPrefetchGateHook { await hook() }
        #endif

        // Generation guard: check immediately before spawning — no await between check
        // and Task creation ensures the check-and-spawn pair is effectively atomic.
        if let isCurrent, !isCurrent() { return }

        #if canImport(XCTest)
        _testPrefetchedURLs.append(url)
        #endif

        let task = Task<DecodeResult, Never>(priority: .utility) {
            await self._networkFetchAndDecode(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let decoded = result.image {
            let cost = decoded.width * decoded.height * 4
            cache.setObject(CachedImage(decoded), forKey: key, cost: cost)
            if let rawSize = result.rawSourceSize {
                dimensionCache.store(rawSize, for: url)
            }
        }
    }

    // MARK: - Pipeline cancel API (internal)

    /// Cancel the in-flight decode Task for each URL+dimensions combination, if any.
    ///
    /// Called by `RenderPipeline` when a new `onIndexBoundary` supersedes the previous
    /// batch — stops network fetches for abandoned URLs that are already past the
    /// generation-guard check and have a running inner decode Task. No-op for specs with
    /// no active `inFlight` entry. Cancellation is cooperative: the inner Task's
    /// `session.data(from:)` respects task cancellation; any acquired decode semaphore
    /// slot is released by the `guard !Task.isCancelled` path in `_decode()`.
    ///
    /// Caution: the `inFlight` map is shared by `image()`, `preload()`, and `prefetch()`.
    /// A concurrent `image()` caller joined to the same key will receive `nil` when the
    /// Task is cancelled. This is safe in the typical discrete-jump scenario — cells for
    /// the abandoned range are recycled before the cancel fires — but two edge windows exist:
    ///
    /// (a) Jump-then-jump-back: `boundary(500)` cancels prefetches for [0, 10); the user
    ///     immediately scrolls back, and `image()` for cells 0–9 may join the
    ///     still-cancelling Task before its creator clears `inFlight[key]`, receiving
    ///     `nil` → potential gray flash on remount.
    ///
    /// (b) `visibleCount > prefetchAhead`: a visible cell at index
    ///     `leadingIndex + prefetchAhead + k` falls outside the stale filter's range and
    ///     can have its prefetch cancelled while a concurrent `image()` call is in-flight
    ///     for the same key, also receiving `nil`.
    ///
    /// Assumption: the cell mount path retries on `nil` — a `nil` return does not
    /// permanently gray the cell. Verify before widening deep-cancel to larger windows.
    func cancelInFlightPrefetches(_ specs: [PrefetchSpec]) {
        for spec in specs {
            let key = ImageCacheKey(
                url: spec.url,
                targetSize: spec.targetSize,
                cornerRadius: spec.cornerRadius,
                scale: min(spec.scale, decodeScaleCeiling)
            )
            inFlight[key]?.cancel()
        }
    }

    // MARK: - Private helpers

    /// Acquire a decode slot, run CGImageSource decode on `decodeQueue`, release the slot,
    /// and return the result. Semaphore acquire/release and continuation are owned here so
    /// callers share one implementation.
    ///
    /// - Returns: `DecodeResult(image: nil, rawSourceSize: nil)` on cancellation or decode
    ///   failure. Never throws — all error paths are folded into the nil result.
    private func _decode(
        data: Data,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) async -> DecodeResult {
        // Cancellation paths below (`catch` + post-acquire guard) are exercised by
        // `cancelInFlightPrefetches`, which cancels the inner Task<DecodeResult, Never>
        // handle via `inFlight[key]?.cancel()`. The catch path fires if cancellation
        // arrives while blocked on `decodeSemaphore.wait()`; the post-acquire guard
        // fires if cancellation arrives after the slot is consumed. Both release the slot.
        //
        // Acquire a decode slot. Throws CancellationError if cancelled while waiting;
        // the slot is never consumed on the thrown path — do NOT call signal().
        do {
            try await decodeSemaphore.wait()
        } catch {
            return DecodeResult(image: nil, rawSourceSize: nil)
        }

        // Cancellation arriving between wait() returning and the dispatch enqueue would
        // otherwise spend a slot on dead work.
        guard !Task.isCancelled else {
            Task { await decodeSemaphore.signal() }
            return DecodeResult(image: nil, rawSourceSize: nil)
        }

        #if canImport(XCTest)
        // Gate fires with the decode slot held — cancel the inner Task during this hook
        // then signal; the guard below releases the slot on resumed cancellation.
        if let hook = _testDecodeBodyGateHook { await hook() }
        guard !Task.isCancelled else {
            Task { await decodeSemaphore.signal() }
            return DecodeResult(image: nil, rawSourceSize: nil)
        }
        #endif

        let sem = decodeSemaphore
        #if canImport(XCTest)
        // Capture before the continuation (actor-isolated context) so the @Sendable
        // closure can call DispatchQueue.getSpecific without retaining self.
        let capturedQueueKey = _testDecodeQueueKey
        #endif
        return await withCheckedContinuation { cont in
            let capturedData = data
            let capturedSize = targetSize
            let capturedRadius = cornerRadius
            let capturedScale = scale

            // TODO(VelocityUI-vim+): decodeQueue runs at .userInitiated regardless of the
            // calling Task's priority. Prefetch decodes should run at .utility. Deferred to
            // fling-handling.
            decodeQueue.async {
                #if canImport(XCTest)
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
                log.debug("decode \(capturedSize.width)×\(capturedSize.height) \(String(format: "%.1f", decodeMs))ms")
                #endif
                // Release the slot BEFORE resuming so the next waiter can acquire it without
                // waiting for the continuation-resume actor hop (compresses tail latency in
                // 50-decode bursts — M3).
                Task { await sem.signal() }
                cont.resume(returning: DecodeResult(image: normalised, rawSourceSize: rawSize))
            }
        }
    }

    /// Network fetch + decode; shared by `image()` and `prefetch()` so the pipeline has one
    /// implementation. Called from inside an unstructured `Task<DecodeResult, Never>` — hops
    /// to the actor for `session` access, suspends during the network request (releasing the
    /// actor), then hops back for `_decode`.
    private func _networkFetchAndDecode(
        url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) async -> DecodeResult {
        #if DEBUG
        let networkStart = CFAbsoluteTimeGetCurrent()
        #endif
        guard let (data, response) = try? await session.data(from: url) else {
            return DecodeResult(image: nil, rawSourceSize: nil)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return DecodeResult(image: nil, rawSourceSize: nil)
        }
        #if DEBUG
        let networkMs = (CFAbsoluteTimeGetCurrent() - networkStart) * 1_000
        log.debug("network \(url.lastPathComponent) \(String(format: "%.1f", networkMs))ms")
        #endif
        guard !Task.isCancelled else { return DecodeResult(image: nil, rawSourceSize: nil) }
        return await _decode(data: data, targetSize: targetSize, cornerRadius: cornerRadius, scale: scale)
    }

    /// Synchronous cache probe — callable from any isolation context, including `@MainActor`.
    ///
    /// Returns the decoded `CGImage` if the entry is already in the NSCache, or `nil` on:
    /// - Cache miss (not yet fetched or evicted).
    /// - In-flight hit (the decode Task exists in `inFlight` but has not stored its result
    ///   yet). Checking `inFlight` requires actor isolation; this method intentionally omits
    ///   it. Callers must fall back to `await image(for:…)` on a nil return.
    ///
    /// NSCache guarantees thread-safe concurrent reads. The `cache` property is `let`
    /// (constant reference, no rebinding), satisfying Swift 6's Sendable requirement for
    /// `nonisolated` access on actor stored properties.
    ///
    /// Parameters match `image(for:targetSize:cornerRadius:scale:)` exactly — the key uses
    /// the same `pixelLength` rounding, so entries written by `image()`, `preload()`, and
    /// `prefetch()` are all visible here.
    public nonisolated func cachedImage(
        for url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: min(scale, decodeScaleCeiling))
        return cache.object(forKey: key)?.image
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

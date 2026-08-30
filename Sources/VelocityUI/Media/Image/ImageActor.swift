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

/// `internal`, not `private`: `_testInFlightDecodePriority(...)` in ImageActor+TestHooks.swift
/// constructs a key to look up `inFlightDecodes`.
final class ImageCacheKey: NSObject {
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
/// (dedicated DispatchQueue, max 3 via AsyncSemaphore) → BGRA8888 normalise + corner-round → NSCache.
///
/// - Network and decode use separate executors, so a burst of decodes can't starve visible-priority work waiting on the cooperative pool.
/// - `AsyncSemaphore(value: 3)` caps concurrent decodes so bursts can't exhaust cooperative-pool threads `measureNode` needs.
/// - Cache key is `(url, pixelWidth, pixelHeight, scaledRadius)` — integer pixels collapse e.g. (50pt@2x, 100pt@1x) to one entry.
/// - `DimensionCache.store()` gets raw source header dimensions, not the thumbnail size, so `classify()` has the true aspect ratio at any future layout size.
/// - Concurrent requests for the same key share one decode `Task` via `inFlight`.
/// - No singleton — constructed once in `RenderEnvironment`, injected by initializer.
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
    /// `internal`, not `private`: `_testDecodeSemaphoreWaiterCount(priority:)` in
    /// ImageActor+TestHooks.swift reads this.
    let decodeSemaphore = AsyncSemaphore(value: ImageActor.maxConcurrentDecodes)

    /// Upper bound on the scale (screen points → pixels) used for the cache key and decode target
    /// size. Clamps real display scale (e.g. 3x) down before decode, so the 64 MB NSCache holds
    /// proportionally more images. Pass 3.0+ to disable the cap.
    nonisolated let decodeScaleCeiling: CGFloat

    // nonisolated(unsafe): NSCache is thread-safe and the reference never rebinds (let) —
    // required so cachedImage() can probe synchronously off-actor on the hot path.
    nonisolated(unsafe) private let cache = NSCache<ImageCacheKey, CachedImage>()
    private var inFlight: [ImageCacheKey: Task<DecodeResult, Never>] = [:]
    /// Per-key admission record for the in-flight decode's `decodeSemaphore` waiter, kept in lockstep
    /// with `inFlight`. Lets a later, higher-priority joiner elevate the waiter via
    /// `AsyncSemaphore.elevate(id:to:)` instead of silently inheriting the original priority.
    /// `internal`, not `private`: `_testInFlightDecodePriority(...)` in ImageActor+TestHooks.swift
    /// reads this.
    var inFlightDecodes: [ImageCacheKey: (id: UUID, priority: DecodePriority)] = [:]
    private let session: URLSession
    /// `nonisolated` so RenderEnvironment can check identity (===) in its designated init.
    nonisolated let dimensionCache: DimensionCache

    /// - Parameters:
    ///   - session: Defaults to `.shared`; tests can inject a custom session.
    ///   - dimensionCache: Must be the same instance used by `classify()` — separate instances break the hit contract.
    ///   - decodeScaleCeiling: Defaults to 2.0; pass 3.0+ for full display scale.
    public init(
        session: URLSession = .shared,
        dimensionCache: DimensionCache,
        decodeScaleCeiling: CGFloat = 2.0
    ) {
        self._executor = DispatchQueueExecutor(label: "velocityui.image.actor")
        // 64 MB cap — ~5 images at production density (400×800pt @3x, 4 bytes/pixel).
        cache.totalCostLimit = 64 * 1024 * 1024
        self.session = session
        self.dimensionCache = dimensionCache
        self.decodeScaleCeiling = decodeScaleCeiling
        // Tag decodeQueue so the async closure can verify it is on the right queue.
        decodeQueue.setSpecific(key: _testDecodeQueueKey, value: true)
    }

    /// Test-only convenience: creates a private DimensionCache not shared with any other
    /// collaborator. Use only in unit tests that don't verify classify() hit behaviour.
    init() {
        self.init(dimensionCache: DimensionCache())
    }

    // MARK: - Test hooks

    /// DispatchSpecificKey set on decodeQueue so the decode closure can assert it's running on the
    /// expected queue, not the cooperative pool. `nonisolated`, not actor-isolated — read from inside
    /// the raw `decodeQueue.async` closure, which isn't on the actor. A stored instance property, so
    /// it can't move to ImageActor+TestHooks.swift (extensions forbid stored instance properties);
    /// always present (no XCTest guard) since `init` and the decode closure reference it unconditionally.
    nonisolated let _testDecodeQueueKey = DispatchSpecificKey<Bool>()

    /// Stored test-only observability state that must stay actor-isolated (gate hooks, prefetch
    /// tracking) — as opposed to `_testDecodeQueueKey` above, which deliberately isn't. Always
    /// present (no XCTest guard) — production code (`image()`, `preload()`, `prefetch()`, `_decode()`)
    /// references it unconditionally. See `ImageActorTestHooks` in ImageActor+TestHooks.swift.
    let _testHooks = ImageActorTestHooks()

    // MARK: - Public API

    /// Fetch and decode an image for `url`.
    ///
    /// - Parameters:
    ///   - url: Source URL (file:// and https:// supported).
    ///   - targetSize: Desired render size in points (not pixels).
    ///   - cornerRadius: Rounding radius in points, applied at decode time via CGContext clip. Pass 0 for no rounding.
    ///   - scale: Screen scale (points → pixels); must be captured from UIScreen at the @MainActor call site.
    /// - Returns: BGRA8888 premultiplied CGImage, or nil on error or pre-launch cancellation. An in-flight
    ///   task for this key returns its result regardless of the calling task's own cancellation.
    public func image(
        for url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) async -> CGImage? {
        // Test gate: suspends here so a test can control timing relative to a cross-item recycle.
        // Not cancellation-aware — resumes only when the test explicitly signals.
        if let hook = _testHooks.decodeGateHook { await hook() }

        let decodeScale = min(scale, decodeScaleCeiling)
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale)

        // 1. Cache hit — O(1), no allocation on the hot path.
        if let hit = cache.object(forKey: key) { return hit.image }

        // 2. Join an existing in-flight task for the same key rather than launching a second fetch —
        //    creator handles cache store. A .visible caller elevates a lower-tier prefetch it joins.
        if let existing = inFlight[key] {
            await elevateInFlightDecode(key: key, to: .visible)
            let result = await existing.value
            return result.image
        }

        // 3. Before-launch cancellation check.
        guard !Task.isCancelled else { return nil }

        // 4. Launch a task that owns the network fetch + decode for this key.
        let task = Task<DecodeResult, Never> {
            await self._networkFetchAndDecode(key: key, url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale, priority: .visible)
        }
        inFlight[key] = task
        inFlightDecodes[key] = (id: UUID(), priority: .visible)
        let result = await task.value
        inFlight[key] = nil
        inFlightDecodes[key] = nil

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

    /// Decodes pre-loaded `Data` and primes the image cache — the decode + cache-store path of
    /// `image(for:targetSize:cornerRadius:scale:)` without the network fetch. Parameters must match
    /// the later `image(for:…)` call, or the cache key misses. Shares `image()`'s decode pool (FIFO),
    /// so use only for one-shot warm-up; bad data silently skips the cache store.
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

        if let hook = _testHooks.preloadGateHook { await hook() }

        let capturedData = data
        let capturedTargetSize = targetSize
        let capturedCornerRadius = cornerRadius
        let capturedScale = decodeScale
        let task = Task<DecodeResult, Never> {
            await self._decode(
                key: key,
                data: capturedData,
                targetSize: capturedTargetSize,
                cornerRadius: capturedCornerRadius,
                scale: capturedScale,
                priority: .visible
            )
        }
        inFlight[key] = task
        inFlightDecodes[key] = (id: UUID(), priority: .visible)
        let result = await task.value
        inFlight[key] = nil
        inFlightDecodes[key] = nil

        if let decoded = result.image {
            let cost = decoded.width * decoded.height * 4
            cache.setObject(CachedImage(decoded), forKey: key, cost: cost)
            if let rawSize = result.rawSourceSize {
                dimensionCache.store(rawSize, for: url)
            }
        }
    }

    /// Network-fetch, decode, and cache an image at lower scheduling priority; discards the return
    /// value. Cache/in-flight hits behave like `image()`. The inner Task runs at `.utility` so the
    /// cooperative scheduler deprioritises it relative to `image()` callers, and is unstructured —
    /// cancelling `prefetch()`'s caller does NOT cancel it.
    ///
    /// - Parameters:
    ///   - targetSize/cornerRadius/scale: must match the paired `image(for:…)` call so the cache key aligns.
    ///   - priority: decode-gate admission tier — no default, every call site states intent.
    ///   - isCurrent: optional generation guard; `false` abandons the fetch before any network work starts.
    public func prefetch(
        for url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat,
        priority: DecodePriority,
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

        if let hook = _testHooks.prefetchGateHook { await hook() }

        // Generation guard: check immediately before spawning — no await between check
        // and Task creation ensures the check-and-spawn pair is effectively atomic.
        if let isCurrent, !isCurrent() { return }

        _testHooks.prefetchedURLs.append(url)
        _testHooks.prefetchedPriorities.append((url, priority))

        let task = Task<DecodeResult, Never>(priority: .utility) {
            await self._networkFetchAndDecode(key: key, url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: decodeScale, priority: priority)
        }
        inFlight[key] = task
        inFlightDecodes[key] = (id: UUID(), priority: priority)
        let result = await task.value
        inFlight[key] = nil
        inFlightDecodes[key] = nil

        if let decoded = result.image {
            let cost = decoded.width * decoded.height * 4
            cache.setObject(CachedImage(decoded), forKey: key, cost: cost)
            if let rawSize = result.rawSourceSize {
                dimensionCache.store(rawSize, for: url)
            }
        }
    }

    // MARK: - Pipeline cancel API (internal)

    /// Cancel the in-flight decode Task for each URL+dimensions combination, if any — called by
    /// `RenderPipeline` when a new `onIndexBoundary` supersedes the previous batch. Cancellation is
    /// cooperative (`_decode()` releases the held semaphore slot). Caution: `inFlight` is shared with
    /// `image()`/`preload()`, so a concurrent `image()` joined to the same key can get `nil` if it lands
    /// mid-cancellation (e.g. a jump-then-jump-back) — assumes the cell mount path retries on `nil`.
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

    /// Elevates the semaphore waiter for `key`'s in-flight decode to `newPriority` if currently
    /// recorded strictly lower; no-op otherwise. Called only when a `.visible` `image()` caller
    /// joins a decode a lower-priority prefetch already started.
    private func elevateInFlightDecode(key: ImageCacheKey, to newPriority: DecodePriority) async {
        guard let admission = inFlightDecodes[key], admission.priority > newPriority else { return }
        inFlightDecodes[key]?.priority = newPriority
        await decodeSemaphore.elevate(id: admission.id, to: newPriority)
    }

    /// Acquires a decode slot, runs `CGImageSource` decode on `decodeQueue`, releases the slot, and
    /// returns the result. Never throws — cancellation and decode failure both fold into a
    /// `nil`-fielded `DecodeResult`.
    ///
    /// - Parameter key: read from `inFlightDecodes[key]` immediately before `wait()`, so a priority
    ///   elevation applied during the network-fetch phase still takes effect on first admission.
    private func _decode(
        key: ImageCacheKey,
        data: Data,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat,
        priority: DecodePriority
    ) async -> DecodeResult {
        // Cancellation releases the slot on both paths: the `catch` below if cancelled while blocked on
        // `wait()`, the post-acquire guard if cancelled after the slot is consumed.
        //
        // Read the admission record with no `await` before `wait()`, so it reflects any elevation applied
        // during the network-fetch phase. Residual benign race: a `.visible` join landing in this gap
        // admits one cycle later at its original tier — never a slot leak.
        let admission = inFlightDecodes[key]

        // Acquire a decode slot. Throws CancellationError if cancelled while waiting;
        // the slot is never consumed on the thrown path — do NOT call signal().
        do {
            try await decodeSemaphore.wait(id: admission?.id ?? UUID(), priority: admission?.priority ?? priority)
        } catch {
            return DecodeResult(image: nil, rawSourceSize: nil)
        }

        // Cancellation arriving between wait() returning and the dispatch enqueue would
        // otherwise spend a slot on dead work.
        guard !Task.isCancelled else {
            Task { await decodeSemaphore.signal() }
            return DecodeResult(image: nil, rawSourceSize: nil)
        }

        // Gate fires with the decode slot held — cancel the inner Task during this hook
        // then signal; the guard below releases the slot on resumed cancellation.
        if let hook = _testHooks.decodeBodyGateHook { await hook() }
        guard !Task.isCancelled else {
            Task { await decodeSemaphore.signal() }
            return DecodeResult(image: nil, rawSourceSize: nil)
        }

        let sem = decodeSemaphore
        // Capture before the continuation (actor-isolated context) so the @Sendable
        // closure can call DispatchQueue.getSpecific without retaining self.
        let capturedQueueKey = _testDecodeQueueKey
        return await withCheckedContinuation { cont in
            let capturedData = data
            let capturedSize = targetSize
            let capturedRadius = cornerRadius
            let capturedScale = scale

            // TODO: decodeQueue runs at .userInitiated regardless of the calling Task's priority.
            // Prefetch decodes should run at .utility — deferred to fling-handling.
            decodeQueue.async {
                let onDecodeQueue = DispatchQueue.getSpecific(key: capturedQueueKey) == true
                ImageActor._testDecodeRecord(onQueue: onDecodeQueue)
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

                // Raw pixel dimensions from the image header — stored in DimensionCache so classify() has the
                // true aspect ratio without a secondary ranged probe. Must be read from src, not the thumbnail.
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
                    // rawSourceSize intentionally nil: a cached dimension with no paintable image would let
                    // classify() size a row that can never be filled.
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
                // Release the slot BEFORE resuming so the next waiter can acquire it without waiting for
                // the continuation-resume actor hop — compresses tail latency in decode bursts.
                Task { await sem.signal() }
                cont.resume(returning: DecodeResult(image: normalised, rawSourceSize: rawSize))
            }
        }
    }

    /// Network fetch + decode; shared by `image()` and `prefetch()` so the pipeline has one
    /// implementation. Hops to the actor for `session`, suspends during the network request, then
    /// hops back for `_decode`.
    private func _networkFetchAndDecode(
        key: ImageCacheKey,
        url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat,
        priority: DecodePriority
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
        return await _decode(key: key, data: data, targetSize: targetSize, cornerRadius: cornerRadius, scale: scale, priority: priority)
    }

    /// Synchronous cache probe, callable from any isolation context. Returns `nil` on a cache miss OR
    /// an in-flight hit (checking `inFlight` needs actor isolation, intentionally omitted here) —
    /// callers must fall back to `await image(for:…)` on `nil`.
    public nonisolated func cachedImage(
        for url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: min(scale, decodeScaleCeiling))
        return cache.object(forKey: key)?.image
    }

    /// Cancel fetches below the visible range. No-op until fling-handling (Phase 3+).
    public func cancelBelowVisible() {}

    /// Trap if the caller is not on velocityui.image.actor — proves the custom executor is active,
    /// not silently replaced by the cooperative pool. Tests/debug assertions only.
    func assertOnDedicatedExecutor() {
        _executor.checkIsolated()
    }
}
#endif

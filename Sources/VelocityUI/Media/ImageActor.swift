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
/// (dedicated DispatchQueue, max 3 via AsyncSemaphore) → BGRA8888 normalise + corner-round →
/// NSCache.
///
/// - Network and decode use separate executors (URLSession suspends on the cooperative pool,
///   decode on a dedicated concurrent queue) — a serial pipeline would starve visible-priority
///   decodes under burst load.
/// - `AsyncSemaphore(value: 3)` caps concurrent decodes so bursts can't exhaust cooperative pool
///   threads `measureNode` needs (contract clause 3).
/// - Cache key is `(url, pixelWidth, pixelHeight, scaledRadius)` — integer pixels avoid CGFloat
///   equality hazards and collapse e.g. (50pt@2x, 100pt@1x) to one entry.
/// - `DimensionCache.store()` gets raw source header dimensions, not the thumbnail size, so
///   `classify()` has the true aspect ratio for any future layout size.
/// - Concurrent requests for the same key share one decode `Task` via `inFlight` — `image()` and
///   `preload()` both coalesce against it (mirrors `DimensionCache`'s pattern).
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
    /// Per-key admission record for the in-flight decode's `decodeSemaphore` waiter. Populated
    /// /cleared in lockstep with `inFlight` at every call site (`image()`, `preload()`,
    /// `prefetch()`). Lets a later, higher-priority joiner find the waiter's identity and elevate
    /// it via `AsyncSemaphore.elevate(id:to:)` — without this, a joiner would silently inherit
    /// the original (possibly lower) priority for the rest of the wait. `id` is generated at
    /// `inFlight` population time, not inside `AsyncSemaphore.wait()`, so it's stable and
    /// lookup-able through the network-fetch phase before decode reaches the semaphore.
    private var inFlightDecodes: [ImageCacheKey: (id: UUID, priority: DecodePriority)] = [:]
    private let session: URLSession
    /// `nonisolated` so RenderEnvironment can check identity (===) in its designated init.
    nonisolated let dimensionCache: DimensionCache

    /// - Parameters:
    ///   - session: Defaults to `.shared`; tests can inject a custom session.
    ///   - dimensionCache: Must be the same instance used by `classify()` (obtain from
    ///     `RenderEnvironment`, don't construct here) — separate instances break the hit contract.
    ///   - decodeScaleCeiling: Defaults to 2.0, see property docstring. Pass 3.0+ for full
    ///     display scale.
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
    /// `_testDecodeLock` makes writes safe across concurrent Task/queue threads (pattern
    /// matches `NodeTable._itemIDCounter` — `nonisolated(unsafe)` is the lesser violation).
    ///
    /// Assumes one `ImageActor` under test at a time with no concurrent suite sharing these
    /// counters — call `_testDecodeResetCounts()` before each reading test, or risk
    /// false-passing/under-counted results.
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

    /// Test-only interposer: when non-nil, `image()` suspends here before the cache-hit check.
    /// Doesn't check `Task.isCancelled` — callers control the resume point, letting tests hold
    /// a decode in-flight past a cross-item recycle to exercise `applyContent`'s privacy guard.
    /// Set only via `@testable import VelocityUI`; never set in production.
    var _testDecodeGateHook: (@Sendable () async -> Void)?

    /// Sets `_testDecodeGateHook` from test code. Actor-isolated setter so the assignment
    /// is safe across executor boundaries (tests call `await actor.set_testDecodeGateHook(...)`).
    func set_testDecodeGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testDecodeGateHook = hook
    }

    /// Test-only interposer in `preload()`, firing after the in-flight coalescing check and
    /// pre-launch cancellation guard, before the decode Task is created. Cancelling the outer
    /// task here doesn't affect the inner decode Task (unstructured, no cancellation
    /// inheritance) — use to observe `inFlight` boundary state, not slot-release under
    /// cancellation (see VelocityUI-bw1's `_decode()` hook for that). Test-only, never set in
    /// production.
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

    /// Test-only interposer in `_decode()`, after `decodeSemaphore.wait()` returns (slot
    /// already held) and before `withCheckedContinuation`. Cancel the inner Task here, signal,
    /// then verify the slot released (subsequent `wait()` succeeds). Gates `image()`,
    /// `preload()`, and `prefetch()` — all funnel through `_decode()`. Test-only, never set in
    /// production.
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

    /// Test seam: the `priority` argument each cold-path `prefetch()` call carried, paired
    /// with its URL and appended in the same order as `_testPrefetchedURLs`. Lets tests
    /// verify per-call admission tier (e.g. RenderPipeline's ahead/behind classification)
    /// without threading a fake ImageActor through RenderPipeline.
    private(set) var _testPrefetchedPriorities: [(url: URL, priority: DecodePriority)] = []

    func _testGetPrefetchedPriorities() -> [(url: URL, priority: DecodePriority)] { _testPrefetchedPriorities }
    func _testResetPrefetchedPriorities() { _testPrefetchedPriorities.removeAll() }

    /// Test-only: number of decode-gate waiters queued at `priority` on `decodeSemaphore`.
    /// Forwards to `AsyncSemaphore._waiterCount(priority:)` so tests get a deterministic
    /// "this decode has reached the gate and is queued, not yet holding a slot" anchor to
    /// poll on instead of sleeping a fixed duration.
    func _testDecodeSemaphoreWaiterCount(priority: DecodePriority) async -> Int {
        await decodeSemaphore._waiterCount(priority: priority)
    }

    /// Test-only: the admission priority currently recorded in `inFlightDecodes` for the key
    /// identified by these parameters, or `nil` if there is no in-flight decode for that key.
    /// `ImageCacheKey` is file-private, so tests cannot construct one directly — this hook
    /// takes the same parameters `image()`/`preload()`/`prefetch()` do and builds the key
    /// internally. Lets a test observe a `VelocityUI-8nz` elevation (`.behind`/`.ahead` →
    /// `.visible`) directly, independent of `AsyncSemaphore`'s own waiter-tier bookkeeping.
    func _testInFlightDecodePriority(
        url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) -> DecodePriority? {
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: min(scale, decodeScaleCeiling))
        return inFlightDecodes[key]?.priority
    }
    #endif

    // MARK: - Public API

    /// Fetch and decode an image for `url`.
    ///
    /// - Parameters:
    ///   - url: Source URL (file:// and https:// supported).
    ///   - targetSize: Desired render size in points (not pixels).
    ///   - cornerRadius: Rounding radius in points, applied at decode time via CGContext clip.
    ///     Pass 0 for no rounding.
    ///   - scale: Screen scale (points → pixels). Must be captured from UIScreen at the
    ///     @MainActor call site — `UIScreen.main` is not safe off main.
    /// - Returns: BGRA8888 premultiplied CGImage, or nil on error or pre-launch cancellation. If
    ///   an in-flight task for this key is already running, returns its result regardless of the
    ///   calling task's cancellation state (shared work isn't killed for one caller).
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
        //    second network fetch + decode — creator handles cache store. A .visible
        //    caller joining a lower-tier (prefetch-started) decode elevates it first —
        //    "prefetch started it, now it's on screen" (VelocityUI-8nz).
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

    /// Decodes pre-loaded `Data` and primes the image cache at the given layout dimensions — the
    /// decode + cache-store path of `image(for:targetSize:cornerRadius:scale:)` without the
    /// network fetch. Shares the same 3-slot decode pool as `image()` (FIFO — a preload burst can
    /// delay a concurrent `image()` call), so use only for one-shot warm-up before the feed
    /// starts fetching. `url`/`targetSize`/`cornerRadius`/`scale` must match what `image(for:…)`
    /// will pass later, or the cache key misses. Concurrent calls for the same key join the
    /// in-flight decode.
    ///
    /// Bad data (nil `CGImageSource` or thumbnail failure) silently skips the cache store —
    /// verify warm-up succeeded by probing `image(for:…)` afterward.
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

    /// Network-fetch, decode, and cache an image at lower scheduling priority. Cache hit returns
    /// immediately; in-flight hit joins the existing Task via the shared `inFlight` map (creator
    /// stores, joiners await); cold path runs the same pipeline as `image()`
    /// (`_networkFetchAndDecode` → normalise + round → cache store + `DimensionCache.store()`) but
    /// discards the return value.
    ///
    /// The inner Task runs at `.utility` so the cooperative scheduler deprioritises prefetch waits
    /// relative to `.userInitiated` `image()` callers — QoS differentiation only bites at the
    /// cooperative scheduler layer, not TCP/TLS or server-side ordering. It's unstructured:
    /// cancelling `prefetch()`'s caller does NOT cancel it or any concurrent `image()` awaiting
    /// the same `inFlight` entry.
    ///
    /// - Parameters:
    ///   - targetSize/cornerRadius/scale: must match the paired `image(for:…)` call so the cache
    ///     key aligns.
    ///   - priority: decode-gate admission tier (`DecodePriority`) — no default, every call site
    ///     states intent. Only affects slot hand-out order among waiters, never preempts a
    ///     decode that already holds a slot.
    ///   - isCurrent: optional generation guard, checked with no await before spawning the inner
    ///     decode Task. `false` means a newer `onIndexBoundary` superseded this batch — the fetch
    ///     is abandoned before any network work starts. `nil` skips the guard.
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

        #if canImport(XCTest)
        if let hook = _testPrefetchGateHook { await hook() }
        #endif

        // Generation guard: check immediately before spawning — no await between check
        // and Task creation ensures the check-and-spawn pair is effectively atomic.
        if let isCurrent, !isCurrent() { return }

        #if canImport(XCTest)
        _testPrefetchedURLs.append(url)
        _testPrefetchedPriorities.append((url, priority))
        #endif

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

    /// Cancel the in-flight decode Task for each URL+dimensions combination, if any.
    ///
    /// Called by `RenderPipeline` when a new `onIndexBoundary` supersedes the previous batch —
    /// stops network fetches for abandoned URLs past the generation-guard check with a running
    /// inner decode Task. No-op if no active `inFlight` entry. Cancellation is cooperative:
    /// `session.data(from:)` respects task cancellation, and a held decode-semaphore slot is
    /// released by `_decode()`'s `guard !Task.isCancelled` path.
    ///
    /// Caution: `inFlight` is shared with `image()`/`preload()` — a concurrent `image()` joined
    /// to the same key gets `nil` when the Task is cancelled. Safe in the typical discrete-jump
    /// case (abandoned cells recycle before the cancel fires), but two edge windows exist: (a)
    /// jump-then-jump-back — `boundary(500)` cancels prefetch for [0,10), user scrolls straight
    /// back, `image()` for cells 0-9 may join the still-cancelling Task before `inFlight[key]`
    /// clears, getting `nil` (possible gray flash on remount); (b) `visibleCount > prefetchAhead`
    /// — a visible cell outside the stale filter's range can have its prefetch cancelled while a
    /// concurrent `image()` is in-flight for the same key, also getting `nil`. Assumes the cell
    /// mount path retries on `nil`; verify before widening deep-cancel to larger windows.
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
    /// recorded strictly lower; no-op if already at/above it or no in-flight record exists.
    /// Used by `image()` when a `.visible` caller joins a decode a lower-priority prefetch
    /// already started — "prefetch started it, now it's on screen" (VelocityUI-8nz).
    /// `preload()`/`prefetch()` joiners never call this — only a `.visible` `image()` join does.
    private func elevateInFlightDecode(key: ImageCacheKey, to newPriority: DecodePriority) async {
        guard let admission = inFlightDecodes[key], admission.priority > newPriority else { return }
        inFlightDecodes[key]?.priority = newPriority
        await decodeSemaphore.elevate(id: admission.id, to: newPriority)
    }

    /// Acquires a decode slot, runs `CGImageSource` decode on `decodeQueue`, releases the slot,
    /// and returns the result. Owns semaphore acquire/release + continuation so callers share one
    /// implementation. Never throws — cancellation and decode failure both fold into a
    /// `nil`-fielded `DecodeResult`.
    ///
    /// - Parameter key: read from `inFlightDecodes[key]` immediately before
    ///   `decodeSemaphore.wait()`, so a priority elevation applied during the (potentially long)
    ///   network-fetch phase — before this decode reached the semaphore — still takes effect on
    ///   first admission.
    private func _decode(
        key: ImageCacheKey,
        data: Data,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat,
        priority: DecodePriority
    ) async -> DecodeResult {
        // Cancellation exercised by `cancelInFlightPrefetches` via `inFlight[key]?.cancel()`:
        // the `catch` below fires if cancelled while blocked on `wait()`; the post-acquire guard
        // fires if cancelled after the slot is consumed. Both release the slot.
        //
        // Read the admission record with no `await` before `wait()` so it reflects any elevation
        // applied since the decode Task was created (e.g. during network-fetch, before this
        // function ran). Falls back to a fresh id/the call's own `priority` when there's no record.
        //
        // Residual micro-race (benign, not closed): a `.visible` join landing in the gap between
        // this read and `wait()` enqueuing the waiter finds nothing to elevate and admits one
        // cycle later at its original tier — a momentary priority inversion, never a slot leak.
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
    ///
    /// - Parameter key: Threaded through to `_decode` unchanged — see that method's doc for why.
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

    /// Synchronous cache probe, callable from any isolation context including `@MainActor`.
    /// Returns `nil` on a cache miss OR an in-flight hit (checking `inFlight` needs actor
    /// isolation, intentionally omitted here) — callers must fall back to `await image(for:…)`
    /// on `nil`. `NSCache` guarantees thread-safe concurrent reads; `cache` is `let`, so
    /// `nonisolated` access on this actor is Sendable-safe.
    ///
    /// Parameters match `image(for:…)` exactly, so entries from `image()`, `preload()`, and
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

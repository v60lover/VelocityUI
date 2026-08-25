// ImageActor+TestHooks.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Stored test-only observability state for `ImageActor` that must stay actor-isolated: gate hooks
/// tests use to suspend a specific await point, and prefetch-call tracking arrays. A plain
/// (non-actor) class rather than an `extension ImageActor` member — extensions forbid stored
/// instance properties, but a fresh type declared in this file can hold them, and `ImageActor` then
/// holds exactly one reference to it (`_testHooks`). Safe without its own isolation or `Sendable`
/// conformance: every touch happens from one of `ImageActor`'s own actor-isolated methods (`image()`,
/// `preload()`, `prefetch()`, `_decode()`, and the accessors below) — the box reference never crosses
/// an isolation boundary on its own.
///
/// Not `#if`-gated: `ImageActor`'s production code references this type directly with no
/// `#if canImport(XCTest)` guard, so the declaration must always compile. The only XCTest-gated part
/// of this test-hook pair is the `extension ImageActor` below, which re-exposes these fields under
/// their historical test-facing names/methods.
final class ImageActorTestHooks {
    /// Test-only interposer: when non-nil, `image()` suspends here before the cache-hit check, letting
    /// tests hold a decode in-flight past a cross-item recycle. Not cancellation-aware.
    var decodeGateHook: (@Sendable () async -> Void)?

    /// Test-only interposer in `preload()`, firing before the decode Task is created. Cancelling the
    /// outer task here doesn't cancel the inner decode Task (unstructured).
    var preloadGateHook: (@Sendable () async -> Void)?

    /// Test-only interposer in `prefetch()`, firing before the inner decode Task is created — use to
    /// observe actor state at the inFlight boundary.
    var prefetchGateHook: (@Sendable () async -> Void)?

    /// Test-only interposer in `_decode()`, after the decode slot is acquired — cancel the inner Task
    /// here to verify slot release. Gates `image()`, `preload()`, and `prefetch()` (all funnel through
    /// `_decode()`).
    var decodeBodyGateHook: (@Sendable () async -> Void)?

    /// URLs that reached the cold-path inside `prefetch()`, after the inFlight/cache checks pass.
    var prefetchedURLs: [URL] = []

    /// The `priority` argument each cold-path `prefetch()` call carried, paired with its URL, in the
    /// same order as `prefetchedURLs`. Lets tests verify per-call admission tier without threading a
    /// fake ImageActor through RenderPipeline.
    var prefetchedPriorities: [(url: URL, priority: DecodePriority)] = []
}

// MARK: - Decode-queue affinity check (nonisolated, off-actor)

/// Counts decode closures that ran on velocityui.image.decode (expected) vs other queues. Static —
/// not part of `ImageActorTestHooks` — because `_decode()`'s decode closure runs on the raw
/// `decodeQueue`, off the actor, and can't await a hop back to read/write actor-isolated storage.
/// Assumes one `ImageActor` under test at a time — call `_testDecodeResetCounts()` before each
/// reading test, or risk false-passing/under-counted results. Always present (no XCTest guard) —
/// the decode closure calls `_testDecodeRecord(onQueue:)` unconditionally.
extension ImageActor {
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
}

#if canImport(XCTest)
extension ImageActor {
    /// Sets `_testHooks.decodeGateHook` from test code; actor-isolated so the assignment is safe
    /// across executor boundaries.
    func set_testDecodeGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testHooks.decodeGateHook = hook
    }

    func set_testPreloadGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testHooks.preloadGateHook = hook
    }

    func set_testPrefetchGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testHooks.prefetchGateHook = hook
    }

    func set_testDecodeBodyGateHook(_ hook: (@Sendable () async -> Void)?) {
        _testHooks.decodeBodyGateHook = hook
    }

    /// Actor-isolated; access with `await actor._testGetPrefetchedURLs()`.
    func _testGetPrefetchedURLs() -> [URL] { _testHooks.prefetchedURLs }
    func _testResetPrefetchedURLs() { _testHooks.prefetchedURLs.removeAll() }

    func _testGetPrefetchedPriorities() -> [(url: URL, priority: DecodePriority)] { _testHooks.prefetchedPriorities }
    func _testResetPrefetchedPriorities() { _testHooks.prefetchedPriorities.removeAll() }

    /// Test-only: number of decode-gate waiters queued at `priority` on `decodeSemaphore` — a
    /// deterministic anchor tests can poll on instead of sleeping a fixed duration.
    func _testDecodeSemaphoreWaiterCount(priority: DecodePriority) async -> Int {
        await decodeSemaphore._waiterCount(priority: priority)
    }

    /// Test-only: the admission priority currently recorded in `inFlightDecodes` for the key built
    /// from these parameters. Lets a test observe a priority elevation directly, independent of
    /// `AsyncSemaphore`'s bookkeeping.
    func _testInFlightDecodePriority(
        url: URL,
        targetSize: CGSize,
        cornerRadius: CGFloat,
        scale: CGFloat
    ) -> DecodePriority? {
        let key = ImageCacheKey(url: url, targetSize: targetSize, cornerRadius: cornerRadius, scale: min(scale, decodeScaleCeiling))
        return inFlightDecodes[key]?.priority
    }
}
#endif
#endif

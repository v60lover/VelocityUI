// LayoutCache.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

/// Cache key for LayoutCache: combines the item's layout hash with the
/// available width. Width is part of the key because all measurement is
/// width-relative — a rotation or window resize produces a different width
/// and must not reuse a prior entry.
///
/// Width contract: pass an exact, source-of-truth width (e.g. `bounds.width`),
/// not a value derived through arithmetic. CGFloat equality is exact for
/// integer-valued floats, but `containerWidth - 2 * padding * scale / scale`
/// can silently produce a near-miss key and a cache miss.
public struct CacheKey: Hashable, Sendable {
    public let layoutHash: Int
    public let width: CGFloat

    public init(layoutHash: Int, width: CGFloat) {
        self.layoutHash = layoutHash
        self.width = width
    }
}

/// NSCache requires a class key — `CacheKey` is a Hashable struct, so this
/// boxes it for the nonisolated read-mirror. Forwards isEqual/hash to the
/// wrapped `CacheKey`, mirroring `ImageCacheKey` in ImageActor.swift.
private final class CacheKeyBox: NSObject {
    let key: CacheKey

    init(_ key: CacheKey) { self.key = key }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CacheKeyBox else { return false }
        return key == other.key
    }

    override var hash: Int { key.hashValue }
}

/// NSCache requires a class value — `CellEntry` is a Sendable struct, so this
/// boxes it for the nonisolated read-mirror. Mirrors `CachedImage` in
/// ImageActor.swift.
private final class CachedEntryBox {
    let entry: CellEntry
    init(_ entry: CellEntry) { self.entry = entry }
}

/// Actor-isolated cache of layout + fragment pairs for the prefetch pipeline.
///
/// Only `RenderPipeline`'s TaskGroup writes via `set()`. `get()` (also
/// actor-isolated) is likewise only used by the pipeline. The synchronous
/// scroll path (FeedScrollView.updateVisibleCells / refineKnownFrames) reads
/// via `cachedEntry(for:)` instead — see that method's docstring for why a
/// nonisolated read is safe here.
///
/// Eviction: FIFO count cap. When `capacity` is reached the oldest-inserted
/// entry is evicted. FIFO is appropriate for feed prefetch: items are measured
/// in scroll order, so the oldest entry is least likely to be revisited before
/// the working range has grown further past it. LRU would require O(n)
/// move-to-front on every `get()` — FIFO keeps reads O(1).
///
/// No in-flight coalescing: `measureNode` is a pure function of its inputs, so
/// a concurrent double-measure on the same key produces identical results and
/// costs a few µs of CPU — far cheaper than the network round-trip that
/// justifies coalescing in DimensionCache. The second store is a no-op update.
///
/// Storage note: the authoritative store is a Dictionary + insertion-order
/// array (below), NOT NSCache — NSCache's eviction is opportunistic /
/// unspecified-order, which would break this type's deterministic FIFO
/// eviction contract (see `testFIFOEvictsOldestEntry`). A separate NSCache
/// mirror (`readMirror`) is kept in lockstep purely to support the
/// nonisolated `cachedEntry(for:)` peek; it never governs eviction or count.
public actor LayoutCache {
    private let capacity: Int
    private var store: [CacheKey: CellEntry]
    private var insertionOrder: [CacheKey]

    // nonisolated(unsafe): NSCache guarantees thread-safe concurrent reads and writes.
    // The reference itself never rebinds (let), and all mutating paths run on the actor
    // executor, so data-race safety holds without an additional lock. This mirror is
    // read-through only for cachedEntry(for:) — the Dictionary above remains the sole
    // source of truth for get()/set()/invalidate()/invalidateAll()/count.
    nonisolated(unsafe) private let readMirror = NSCache<CacheKeyBox, CachedEntryBox>()

    public init(capacity: Int = 500) {
        self.capacity = capacity
        self.store = Dictionary(minimumCapacity: min(capacity, 64))
        self.insertionOrder = []
    }

    // MARK: - Public interface

    /// Returns the cached entry for `key`, or nil on a miss.
    public func get(_ key: CacheKey) -> CellEntry? {
        store[key]
    }

    /// Stores `entry` for `key`.
    ///
    /// If `key` already exists the value is updated in-place without changing
    /// eviction order (two tasks racing on the same key produce identical output;
    /// keeping the original insertion position is correct).
    /// If the cap is reached, the oldest-inserted entry is evicted first.
    public func set(_ entry: CellEntry, for key: CacheKey) {
        if store[key] != nil {
            store[key] = entry
            readMirror.setObject(CachedEntryBox(entry), forKey: CacheKeyBox(key))
            return
        }
        // Eviction is O(capacity) — Array.removeFirst() shifts the tail. Acceptable at
        // capacity 500 off-main. If capacity grows materially, switch insertionOrder to
        // a Deque (swift-collections) or a head-index ring for O(1) amortized eviction.
        if store.count >= capacity, let oldest = insertionOrder.first {
            store.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
            readMirror.removeObject(forKey: CacheKeyBox(oldest))
        }
        store[key] = entry
        insertionOrder.append(key)
        readMirror.setObject(CachedEntryBox(entry), forKey: CacheKeyBox(key))
    }

    /// Removes the single entry for `key`, if present.
    ///
    /// O(capacity) on the insertionOrder linear scan — intentional. Single-key
    /// invalidation is not a hot path; rotation/replacement uses invalidateAll().
    public func invalidate(_ key: CacheKey) {
        guard store.removeValue(forKey: key) != nil else { return }
        if let idx = insertionOrder.firstIndex(of: key) {
            insertionOrder.remove(at: idx)
        }
        readMirror.removeObject(forKey: CacheKeyBox(key))
    }

    /// Clears all entries. Call on device rotation (width change) or when the
    /// item set is replaced entirely.
    public func invalidateAll() {
        store.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        readMirror.removeAllObjects()
    }

    // MARK: - Synchronous peek (scroll path)

    /// Synchronous cache probe — callable from any isolation context, including
    /// `@MainActor`, with zero `await`.
    ///
    /// Returns the entry if already present in the read-mirror, or `nil` on a
    /// miss (not yet measured, evicted, or written with a different `width`/
    /// `layoutHash`). Callers on the scroll path must treat `nil` as "fall back
    /// to the existing WorkingRange-miss path" — this method never triggers work.
    ///
    /// Why this is safe to call `nonisolated`: `LayoutCache`'s actor isolation
    /// exists to serialize `set()` against concurrent `measureNode` results
    /// racing on the same key (see `set(_:for:)`'s in-place-update note) — it is
    /// a write-ordering guarantee, not a read-safety requirement. `NSCache`
    /// itself already guarantees thread-safe concurrent `object(forKey:)`, and
    /// `readMirror` is a `let` (never rebound), satisfying Swift 6's Sendable
    /// requirement for `nonisolated` access to an actor stored property. Reads
    /// here can race a concurrent `set()`/`invalidate()` write; the outcome is
    /// either the old or new value, never a torn one — acceptable for a
    /// best-effort scroll-path peek that always has a synchronous fallback.
    ///
    /// Mirrors `ImageActor.cachedImage(url:targetSize:cornerRadius:scale:)`.
    public nonisolated func cachedEntry(for key: CacheKey) -> CellEntry? {
        readMirror.object(forKey: CacheKeyBox(key))?.entry
    }

    // MARK: - Internal test hook

    /// Number of entries currently in the cache.
    var count: Int { store.count }
}
#endif

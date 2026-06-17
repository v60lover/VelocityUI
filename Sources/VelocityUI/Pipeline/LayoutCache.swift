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

/// Actor-isolated cache of layout + fragment pairs for the prefetch pipeline.
///
/// Only `RenderPipeline`'s TaskGroup writes to and reads from this cache.
/// The synchronous scroll path (WorkingRange) never touches it — actor
/// isolation enforces this at the language level (all methods require `await`).
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
public actor LayoutCache {
    private let capacity: Int
    private var store: [CacheKey: CellEntry]
    private var insertionOrder: [CacheKey]

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
            return
        }
        // Eviction is O(capacity) — Array.removeFirst() shifts the tail. Acceptable at
        // capacity 500 off-main. If capacity grows materially, switch insertionOrder to
        // a Deque (swift-collections) or a head-index ring for O(1) amortized eviction.
        if store.count >= capacity, let oldest = insertionOrder.first {
            store.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
        store[key] = entry
        insertionOrder.append(key)
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
    }

    /// Clears all entries. Call on device rotation (width change) or when the
    /// item set is replaced entirely.
    public func invalidateAll() {
        store.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }

    // MARK: - Internal test hook

    /// Number of entries currently in the cache.
    var count: Int { store.count }
}
#endif

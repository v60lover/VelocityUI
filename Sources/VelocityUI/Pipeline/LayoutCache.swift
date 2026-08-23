// LayoutCache.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

/// Cache key for LayoutCache: layout hash + available width (measurement is
/// width-relative). Pass an exact, source-of-truth width, not one derived through
/// arithmetic — CGFloat equality is exact and a near-miss silently misses the cache.
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
/// FIFO eviction (not LRU) — items measure in scroll order, so the oldest entry is
/// least likely to be revisited, and FIFO keeps reads O(1). `readMirror` (NSCache) is
/// a lockstep read-only mirror for the nonisolated `cachedEntry(for:)` peek; the
/// Dictionary + insertion-order array above is the sole source of truth for eviction.
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

    /// Stores `entry` for `key`. An existing key updates in place without changing
    /// eviction order; at capacity, the oldest-inserted entry is evicted first.
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

    /// Removes the single entry for `key`, if present. O(capacity) — fine since
    /// single-key invalidation isn't a hot path.
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

    /// Synchronous, zero-`await` cache probe for the scroll path. Safe `nonisolated`:
    /// `NSCache` guarantees thread-safe concurrent reads, so a read can race a `set()`/
    /// `invalidate()` write and see old or new, but never torn. Treat `nil` as a miss —
    /// fall back to the WorkingRange-miss path; this never triggers work itself.
    public nonisolated func cachedEntry(for key: CacheKey) -> CellEntry? {
        readMirror.object(forKey: CacheKeyBox(key))?.entry
    }

    // MARK: - Internal test hook

    /// Number of entries currently in the cache.
    var count: Int { store.count }
}
#endif

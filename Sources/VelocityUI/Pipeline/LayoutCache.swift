// LayoutCache.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

/// Cache key for LayoutCache: layout hash + available width. Width is keyed because
/// measurement is width-relative — rotation/resize must not reuse a prior entry.
///
/// Pass an exact, source-of-truth width (e.g. `bounds.width`), not one derived through
/// arithmetic — CGFloat equality is exact, but `containerWidth - 2 * padding * scale / scale`
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
/// - Only `RenderPipeline`'s TaskGroup writes via `set()`/reads via `get()`. The synchronous
///   scroll path reads via `cachedEntry(for:)` instead (see its docstring for why a nonisolated
///   read is safe).
/// - Eviction: FIFO count cap. Appropriate for feed prefetch — items measure in scroll order,
///   so the oldest entry is least likely to be revisited soon. LRU would need O(n)
///   move-to-front per `get()`; FIFO keeps reads O(1).
/// - No in-flight coalescing: `measureNode` is pure, so a concurrent double-measure costs a few
///   µs CPU (unlike DimensionCache's network round-trip); the second store is a no-op update.
/// - Authoritative store is Dictionary + insertion-order array, not NSCache — NSCache's eviction
///   order is unspecified, which would break the deterministic FIFO contract
///   (`testFIFOEvictsOldestEntry`). `readMirror` (NSCache) is a lockstep mirror purely for the
///   nonisolated `cachedEntry(for:)` peek; it never governs eviction or count.
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

    /// Synchronous cache probe — callable from any isolation context, including `@MainActor`,
    /// with zero `await`.
    ///
    /// Returns the entry if present in the read-mirror, or `nil` on a miss (not yet measured,
    /// evicted, or written with a different `width`/`layoutHash`). Callers on the scroll path
    /// must treat `nil` as "fall back to the WorkingRange-miss path" — this never triggers work.
    ///
    /// Safe `nonisolated`: `LayoutCache`'s actor isolation serializes `set()` against concurrent
    /// `measureNode` writes on the same key — a write-ordering guarantee, not a read-safety one.
    /// `NSCache` already guarantees thread-safe concurrent reads, and `readMirror` is a `let`
    /// (satisfies Swift 6 Sendable for nonisolated access). A read can race a
    /// `set()`/`invalidate()` write and see old or new, never torn — fine for a best-effort peek
    /// with a synchronous fallback. Mirrors `ImageActor.cachedImage(url:targetSize:cornerRadius:scale:)`.
    public nonisolated func cachedEntry(for key: CacheKey) -> CellEntry? {
        readMirror.object(forKey: CacheKeyBox(key))?.entry
    }

    // MARK: - Internal test hook

    /// Number of entries currently in the cache.
    var count: Int { store.count }
}
#endif

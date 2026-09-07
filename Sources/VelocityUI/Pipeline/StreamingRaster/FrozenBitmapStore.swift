// FrozenBitmapStore.swift

import Foundation
import CoreGraphics
import os

struct CodeBodyRasterIdentity: Sendable, Equatable {
    let themeGeneration: Int
    let scale: CGFloat
}

/// Immutable snapshot of one cached bitmap. `CGImage` is safe to share because callers never
/// mutate its backing storage; cache membership and LRU links remain lock-protected.
struct StoredBitmapArtifact: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
    let cost: Int
    let codeBodyIdentity: CodeBodyRasterIdentity?
}

/// LRU-bounded cache of frozen block bitmaps, keyed by `BlockKey`, so peak memory
/// stays proportional to the visible window rather than chat length.
///
/// A plain `Sendable` class, not an actor, so `bitmap(for:)` stays synchronous for
/// the MainActor scroll path — state is guarded by `OSAllocatedUnfairLock`.
public final class FrozenBitmapStore: Sendable {

    /// LRU list node. `@unchecked Sendable`: it carries a non-`Sendable` `CGImage`,
    /// but every access happens under `state.withLock`.
    final class Node: @unchecked Sendable {
        let key: BlockKey
        var bitmap: CGImage
        var size: CGSize
        var cost: Int
        /// Present only for code-body rasters, whose pixels depend on theme and display scale.
        var codeBodyIdentity: CodeBodyRasterIdentity?
        weak var prev: Node?
        weak var next: Node?

        init(
            key: BlockKey,
            bitmap: CGImage,
            size: CGSize,
            cost: Int,
            codeBodyIdentity: CodeBodyRasterIdentity?
        ) {
            self.key = key
            self.bitmap = bitmap
            self.size = size
            self.cost = cost
            self.codeBodyIdentity = codeBodyIdentity
        }
    }

    struct State {
        /// Sole strong owner of every `Node`.
        var entries: [BlockKey: Node] = [:]
        /// Oldest = next eviction victim.
        weak var head: Node?
        /// Most-recently-used.
        weak var tail: Node?
        var currentByteTotal: Int = 0
        /// Most recently declared working-range window; drives `handleMemoryPressure()`.
        var window: Set<BlockKey> = []
        var byteBudget: Int
        var rasterDiagnosticsObserver: RasterDiagnosticsObserver?
    }

    let state: OSAllocatedUnfairLock<State>

    /// LRU eviction budget in bytes. Default 16 MB (~0.5 MB per text bitmap at 2x scale).
    public var byteBudget: Int {
        state.withLock { $0.byteBudget }
    }

    public init(byteBudget: Int = 16 * 1024 * 1024) {
        self.state = OSAllocatedUnfairLock(initialState: State(byteBudget: byteBudget))
    }

    /// Sizes `byteBudget` from the real working-range footprint instead of the 16 MB
    /// default, so a still-visible block never gets evicted and force a re-freeze.
    public convenience init(windowCount: Int, perBitmapCost: Int = FrozenBitmapStore.defaultPerBitmapCost, headroom: Double = 1.5) {
        self.init(byteBudget: Self.budget(forWindowCount: windowCount, perBitmapCost: perBitmapCost, headroom: headroom))
    }

    /// Measured ~0.5 MB per text-block bitmap at 2x scale on device.
    public static let defaultPerBitmapCost: Int = 512 * 1024

    /// `windowCount` bitmaps at `perBitmapCost` bytes, times `headroom` slack — a
    /// hot-tail re-freeze briefly holds two bitmaps for the same key, so the raw
    /// footprint alone isn't safe.
    public static func budget(forWindowCount windowCount: Int, perBitmapCost: Int = defaultPerBitmapCost, headroom: Double = 1.5) -> Int {
        guard windowCount > 0, perBitmapCost > 0, headroom > 0 else { return 0 }
        return Int((Double(windowCount) * Double(perBitmapCost) * headroom).rounded(.up))
    }

    /// Grow-only: raises `byteBudget` once the real working-range size is known, never
    /// lowers it — a smaller `windowCount` would otherwise evict still-live blocks.
    public func sizeBudget(forWindowCount windowCount: Int, perBitmapCost: Int = defaultPerBitmapCost, headroom: Double = 1.5) {
        let newBudget = Self.budget(forWindowCount: windowCount, perBitmapCost: perBitmapCost, headroom: headroom)
        state.withLock { st in
            st.byteBudget = max(newBudget, st.byteBudget)
        }
    }

    // MARK: - Synchronous read (scroll/bind path)

    /// Synchronous — safe on the `@MainActor` scroll path. A hit bumps `key` to
    /// most-recently-used.
    public func bitmap(for key: BlockKey) -> CGImage? {
        state.withLock { st in
            guard let node = st.entries[key] else { return nil }
            Self.touch(&st, node)
            return node.bitmap
        }
    }

    /// Returns the cached size for `key`, or `nil` on a miss. Does NOT bump recency by
    /// itself — call `bitmap(for:)` too if you need that.
    public func size(for key: BlockKey) -> CGSize? {
        state.withLock { $0.entries[key]?.size }
    }

    /// Returns a code-body raster only when every raster-only input still matches.
    func codeBodyRaster(
        for key: BlockKey,
        identity: CodeBodyRasterIdentity
    ) -> (image: CGImage, size: CGSize)? {
        state.withLock { st in
            guard let node = st.entries[key], node.codeBodyIdentity == identity else { return nil }
            Self.touch(&st, node)
            return (node.bitmap, node.size)
        }
    }

    /// Reads bitmap pixels and transfer metadata atomically, while bumping LRU recency.
    func artifact(for key: BlockKey) -> StoredBitmapArtifact? {
        state.withLock { st in
            guard let node = st.entries[key] else { return nil }
            Self.touch(&st, node)
            return StoredBitmapArtifact(
                image: node.bitmap,
                size: node.size,
                cost: node.cost,
                codeBodyIdentity: node.codeBodyIdentity
            )
        }
    }

    /// Current total bytes held across all cached entries. Never exceeds `byteBudget`
    /// immediately after any `store(...)` call.
    public var currentByteTotal: Int {
        state.withLock { $0.currentByteTotal }
    }

    func setRasterDiagnosticsObserver(_ observer: RasterDiagnosticsObserver?) {
        state.withLock { $0.rasterDiagnosticsObserver = observer }
    }

    // MARK: - Insert

    /// Caches `bitmap` under `key` and evicts LRU entries until back within
    /// `byteBudget`. Never rejects the insert itself, even if `cost` alone exceeds
    /// the whole budget — it just evicts everything else to make room.
    public func store(_ bitmap: CGImage, size: CGSize, cost: Int, for key: BlockKey) {
        store(bitmap, size: size, cost: cost, for: key, codeBodyIdentity: nil)
    }

    /// Internal overload used when a code-body raster must retain its complete cache identity.
    func store(
        _ bitmap: CGImage,
        size: CGSize,
        cost: Int,
        for key: BlockKey,
        codeBodyIdentity: CodeBodyRasterIdentity?
    ) {
        let emissions = state.withLock { st -> (RasterDiagnosticsObserver, [RasterDiagnosticsEvent])? in
            if let existing = st.entries[key] {
                st.currentByteTotal -= existing.cost
                existing.bitmap = bitmap
                existing.size = size
                existing.cost = cost
                existing.codeBodyIdentity = codeBodyIdentity
                st.currentByteTotal += cost
                Self.touch(&st, existing)
            } else {
                let node = Node(
                    key: key,
                    bitmap: bitmap,
                    size: size,
                    cost: cost,
                    codeBodyIdentity: codeBodyIdentity
                )
                st.entries[key] = node
                st.currentByteTotal += cost
                Self.appendAtTail(&st, node)
            }
            guard let observer = st.rasterDiagnosticsObserver else {
                Self.evictLRUUntilWithinBudget(&st, budget: st.byteBudget, protecting: key)
                return nil
            }
            let evictions = Self.evictLRUUntilWithinBudgetReporting(
                &st, budget: st.byteBudget, protecting: key
            )
            return (observer, evictions)
        }
        if let emissions {
            for event in emissions.1 {
                emissions.0.emit(event)
            }
        }
    }

    // MARK: - Working-range window

    /// Widens the tracked window (union) and bumps recency for any key already cached.
    /// Does NOT store bitmaps — an admitted key with no entry stays a miss until `store(...)`.
    public func admit(_ keys: Set<BlockKey>) {
        guard !keys.isEmpty else { return }
        state.withLock { st in
            st.window.formUnion(keys)
            for key in keys {
                if let node = st.entries[key] {
                    Self.touch(&st, node)
                }
            }
        }
    }

    /// Replaces the tracked window with `keys` and drops every cached bitmap outside it.
    public func evict(outside keys: Set<BlockKey>) {
        state.withLock { st in
            st.window = keys
            let toRemove = st.entries.keys.filter { !keys.contains($0) }
            for key in toRemove {
                Self.remove(&st, key)
            }
        }
    }

    /// O(k) removal of exactly `keysThatLeft` — the per-frame fast path for scroll-driven
    /// eviction, instead of `evict(outside:)`'s O(count) sweep.
    public func evict(_ keysThatLeft: Set<BlockKey>) {
        guard !keysThatLeft.isEmpty else { return }
        state.withLock { st in
            st.window.subtract(keysThatLeft)
            for key in keysThatLeft {
                Self.remove(&st, key)
            }
        }
    }

    // MARK: - Memory pressure

    /// Drops every cached bitmap outside the most recently declared working-range window.
    /// If no window has ever been declared, this drops everything.
    public func handleMemoryPressure() {
        state.withLock { st in
            let toRemove = st.entries.keys.filter { !st.window.contains($0) }
            for key in toRemove {
                Self.remove(&st, key)
            }
        }
    }

    // MARK: - Private (all operate under the lock — never call outside `state.withLock`)

    /// Unlinks `node` from the list without touching `entries` or `currentByteTotal`.
    private static func unlink(_ st: inout State, _ node: Node) {
        let prev = node.prev
        let next = node.next
        if let prev {
            prev.next = next
        } else {
            st.head = next
        }
        if let next {
            next.prev = prev
        } else {
            st.tail = prev
        }
        node.prev = nil
        node.next = nil
    }

    /// Appends `node` at the tail (most-recently-used end). `node` must already be detached.
    private static func appendAtTail(_ st: inout State, _ node: Node) {
        node.prev = st.tail
        node.next = nil
        if let oldTail = st.tail {
            oldTail.next = node
        } else {
            st.head = node
        }
        st.tail = node
    }

    /// Moves `node` to the tail (most-recently-used end) — a hit or a re-`store`.
    private static func touch(_ st: inout State, _ node: Node) {
        unlink(&st, node)
        appendAtTail(&st, node)
    }

    private static func remove(_ st: inout State, _ key: BlockKey) {
        guard let node = st.entries.removeValue(forKey: key) else { return }
        st.currentByteTotal -= node.cost
        unlink(&st, node)
    }

    /// `protecting` is the key just stored this call — never evicted, even if it alone
    /// exceeds `budget`.
    private static func evictLRUUntilWithinBudget(
        _ st: inout State, budget: Int, protecting: BlockKey
    ) {
        while st.currentByteTotal > budget {
            guard let victim = st.head, victim.key != protecting else { break }
            remove(&st, victim.key)
        }
    }

    private static func evictLRUUntilWithinBudgetReporting(
        _ st: inout State, budget: Int, protecting: BlockKey
    ) -> [RasterDiagnosticsEvent] {
        var events: [RasterDiagnosticsEvent] = []
        while st.currentByteTotal > budget {
            guard let victim = st.head, victim.key != protecting else { break }
            let key = victim.key
            let cost = victim.cost
            remove(&st, victim.key)
            events.append(.frozenBitmapEvicted(
                key: key,
                cost: cost,
                currentByteTotal: st.currentByteTotal,
                byteBudget: budget
            ))
        }
        return events
    }
}

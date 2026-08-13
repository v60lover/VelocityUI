// FrozenBitmapStore.swift

import Foundation
import CoreGraphics
import os

/// The working-range / LRU-bounded cache for frozen block bitmaps (VelocityUI-qc7 phase B,
/// spike VelocityUI-6qd LB5). `freeze(_:)` (FreezeState.swift) measures + rasterizes a text
/// block exactly once; this store is where the resulting `CGImage` LIVES afterward, bounded so
/// peak memory stays O(window) as a chat grows, not O(chat length).
///
/// This is a CACHE, not a keep-forever store: eviction (byte-budget LRU, working-range sweep,
/// or memory pressure) drops only the bitmap. The caller's `Block`/`BlockKey` descriptor lives
/// entirely outside this type — the store never held it — so a re-entry just calls `freeze(_:)`
/// again cheaply (a fresh measure/rasterize) and re-`store`s the result.
///
/// `final class ... : Sendable`, NOT an actor: the MainActor bind/scroll path is synchronous
/// (CLAUDE.md invariant — scroll path never awaits), so `bitmap(for:)` must be callable and
/// return `CGImage?` without any `await`. Mutable state (the entry map, LRU intrusive list, the
/// running byte total, and the last-declared working-range window) is guarded by an
/// `OSAllocatedUnfairLock`, mirroring `DimensionCache`'s lock-based pattern (DimensionCache.swift)
/// rather than `LayoutCache`'s actor isolation — actor isolation would force every read through
/// an `await`, which the scroll path cannot afford.
///
/// Owned by `RenderEnvironment`, one instance per `AsyncFeed`. On env deinit, ARC releases this
/// store, which releases every retained `CGImage` — no separate teardown call is required.
public final class FrozenBitmapStore: Sendable {

    /// Intrusive doubly-linked-list node: both the cached entry AND a link in the LRU order,
    /// so a `bitmap(for:)` hit or a `store(...)` can relink in O(1) instead of scanning an array.
    ///
    /// `entries` (below) is the SOLE strong owner of every live node — `prev`/`next` (and
    /// `State.head`/`State.tail`) are `weak`. Two strong link directions would form a retain
    /// cycle between adjacent nodes (A.next retains B, B.prev retains A) that ARC cannot break
    /// on its own, silently violating this file's own promise that "ARC releases this store...
    /// releases every retained CGImage, no separate teardown call required." Weak links avoid
    /// that: once `entries` releases a node, it deallocates immediately regardless of who else
    /// was pointing at it.
    ///
    /// `@unchecked Sendable`: carries a `CGImage`, which CoreGraphics does not mark `Sendable`
    /// in this SDK — same pattern as `FreezeState.frozen` and `ImageActor.DecodeResult`. Safety
    /// holds because every `Node` is only ever created, read, or mutated while holding `state`'s
    /// lock (`state.withLock`); it never escapes that protected section — `bitmap(for:)` copies
    /// the `CGImage` reference OUT while locked and returns it, but the `Node` itself is never
    /// handed to a caller or shared across isolation domains.
    private final class Node: @unchecked Sendable {
        let key: BlockKey
        var bitmap: CGImage
        var size: CGSize
        var cost: Int
        weak var prev: Node?
        weak var next: Node?

        init(key: BlockKey, bitmap: CGImage, size: CGSize, cost: Int) {
            self.key = key
            self.bitmap = bitmap
            self.size = size
            self.cost = cost
        }
    }

    private struct State {
        /// O(1) lookup, and the sole strong owner of every `Node` (see `Node`'s doc comment).
        var entries: [BlockKey: Node] = [:]
        /// `head` = oldest = next eviction victim. `weak` — ownership lives in `entries`.
        weak var head: Node?    
        /// `tail` = most-recently-used. `weak` — ownership lives in `entries`.
        weak var tail: Node?
        var currentByteTotal: Int = 0
        /// The most recently declared working-range window — set by `evict(outside:)` and
        /// widened by `admit(_:)`. `handleMemoryPressure()` reads this to decide what survives
        /// a memory-pressure sweep when no explicit window is passed at the call site.
        var window: Set<BlockKey> = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Byte budget for the LRU eviction triggered by every `store(...)` call.
    ///
    /// Default sized from VelocityUI-6qd LB3 (measured on device): a text-block bitmap at 2x
    /// scale costs ~0.5 MB, and LB5's working-range simulation observed a flat ~6 MB live-bitmap
    /// footprint across a 50->500 message chat. 16 MB (~32 text blocks worth) gives ~2.5x
    /// headroom above that observed footprint while still being a bounded, multi-MB default —
    /// callers with a tighter or looser memory budget should pass their own.
    public let byteBudget: Int

    public init(byteBudget: Int = 16 * 1024 * 1024) {
        self.byteBudget = byteBudget
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Sizes `byteBudget` from the real working-range footprint (`windowCount` bitmaps at
    /// `perBitmapCost` bytes, plus `headroom` slack) instead of the fixed 16 MB default. See
    /// `budget(forWindowCount:perBitmapCost:headroom:)` — a budget smaller than the visible
    /// window's own bitmap footprint would evict a still-visible block and force a re-freeze
    /// (jank), which is exactly the failure mode this initializer exists to avoid. Pass the
    /// caller's own working-range size (e.g. `prefetchBehind + visible + prefetchAhead`) as
    /// `windowCount` — the driver, not this store, knows the real window shape.
    public convenience init(windowCount: Int, perBitmapCost: Int = FrozenBitmapStore.defaultPerBitmapCost, headroom: Double = 1.5) {
        self.init(byteBudget: Self.budget(forWindowCount: windowCount, perBitmapCost: perBitmapCost, headroom: headroom))
    }

    /// Default per-bitmap byte cost for `budget(forWindowCount:)` — VelocityUI-6qd LB3 measured
    /// ~0.5 MB per text-block bitmap at 2x scale on device.
    public static let defaultPerBitmapCost: Int = 512 * 1024

    /// Computes a byte budget sized from the real working-range footprint: `windowCount`
    /// bitmaps at `perBitmapCost` bytes each, times `headroom` for slack.
    ///
    /// `headroom` exists because the window's OWN footprint is not a safe budget by itself: a
    /// hot-tail re-freeze briefly holds both the old and new bitmap for the same key before the
    /// old one is evicted (`store(...)`'s re-store path subtracts the old cost first, but the
    /// caller's `freeze(_:)` call that PRODUCES the new bitmap happens before `store` sees it),
    /// and LRU churn at the window boundary (a key admitted just before another is evicted) can
    /// transiently exceed the raw window total. A budget with `headroom <= 1.0` can evict an
    /// in-window block the instant that happens — this bead's design section calls that out as
    /// the re-freeze/jank failure mode to avoid. Default `1.5` gives 50% slack above the raw
    /// window footprint.
    ///
    /// Returns `0` for a non-positive `windowCount` or `perBitmapCost` (nothing to size a
    /// working-range budget from) — callers passing `0` before the working range is known get a
    /// budget that evicts everything, never a negative or nonsensical value.
    public static func budget(forWindowCount windowCount: Int, perBitmapCost: Int = defaultPerBitmapCost, headroom: Double = 1.5) -> Int {
        guard windowCount > 0, perBitmapCost > 0, headroom > 0 else { return 0 }
        return Int((Double(windowCount) * Double(perBitmapCost) * headroom).rounded(.up))
    }

    // MARK: - Synchronous read (scroll/bind path)

    /// Returns the cached bitmap for `key`, or `nil` on a miss (never stored, evicted by the
    /// byte-budget LRU, evicted by a working-range sweep, or dropped by memory pressure).
    ///
    /// SYNCHRONOUS — no `await`, callable from any isolation context including a non-async
    /// `@MainActor` scroll-path function. A hit bumps `key` to the back of the LRU order,
    /// rescuing it from being the next eviction victim.
    public func bitmap(for key: BlockKey) -> CGImage? {
        state.withLock { st in
            guard let node = st.entries[key] else { return nil }
            Self.touch(&st, node)
            return node.bitmap
        }
    }

    /// Returns the cached size for `key` alongside the bitmap lookup, or `nil` on a miss. Does
    /// NOT bump recency by itself — pair with `bitmap(for:)` when both are needed so a single
    /// lookup governs recency, or call this first and `bitmap(for:)` second.
    public func size(for key: BlockKey) -> CGSize? {
        state.withLock { $0.entries[key]?.size }
    }

    /// Current total bytes held across all cached entries. For tests and the regression budget
    /// (VelocityUI-6qd LB5) — never exceeds `byteBudget` immediately after any `store(...)`.
    public var currentByteTotal: Int {
        state.withLock { $0.currentByteTotal }
    }

    // MARK: - Insert

    /// Caches `bitmap` under `key`. `cost` is the caller-computed byte cost — BGRA8888 at
    /// `pixelWidth * pixelHeight * 4`, matching VelocityUI-6qd LB5's live-bitmap accounting
    /// (the caller derives `pixelWidth`/`pixelHeight` as `width * scale`, `height * scale`).
    ///
    /// Re-storing an existing key updates its entry in place (old cost is first subtracted) and
    /// refreshes its recency. If the resulting total exceeds `byteBudget`, evicts least-recently
    /// -used entries — oldest first — until back within budget. `currentByteTotal` never exceeds
    /// `byteBudget` immediately after this call returns (a single entry costing more than the
    /// whole budget is still stored — this store never rejects a caller's insert, it only evicts
    /// everything ELSE to make room).
    public func store(_ bitmap: CGImage, size: CGSize, cost: Int, for key: BlockKey) {
        state.withLock { st in
            if let existing = st.entries[key] {
                st.currentByteTotal -= existing.cost
                existing.bitmap = bitmap
                existing.size = size
                existing.cost = cost
                st.currentByteTotal += cost
                Self.touch(&st, existing)
            } else {
                let node = Node(key: key, bitmap: bitmap, size: size, cost: cost)
                st.entries[key] = node
                st.currentByteTotal += cost
                Self.appendAtTail(&st, node)
            }
            Self.evictLRUUntilWithinBudget(&st, budget: byteBudget, protecting: key)
        }
    }

    // MARK: - Working-range window

    /// Declares that `keys` are (still, or newly) inside the working range. Widens the tracked
    /// window (union, never replaces) and, for any key already cached, bumps its recency so
    /// window membership itself is a defense against LRU churn — a block just scrolled back into
    /// view should not be the next byte-budget eviction victim.
    ///
    /// Does NOT store bitmaps — a key admitted here that has no cached entry stays a miss until
    /// the caller calls `store(...)` for it (typically after re-`freeze`-ing it).
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

    /// Drops the bitmap for every currently cached key NOT in `keys`, and declares `keys` as the
    /// new authoritative working-range window (replaces, not unions — `keys` is the caller's
    /// full current window, not an incremental addition; use `admit(_:)` for incremental entries).
    ///
    /// Dropping an entry removes only its bitmap; the caller's `Block`/`BlockKey` descriptor is
    /// untouched (this store never held it), so the entry can be cheaply re-`freeze`d and
    /// re-`store`d if the key scrolls back into range. `currentByteTotal` drops by exactly the
    /// evicted entries' summed cost.
    public func evict(outside keys: Set<BlockKey>) {
        state.withLock { st in
            st.window = keys
            let toRemove = st.entries.keys.filter { !keys.contains($0) }
            for key in toRemove {
                Self.remove(&st, key)
            }
        }
    }

    /// Removes exactly the entries for `keysThatLeft`, in O(k) via the store's existing O(1)
    /// intrusive-list `remove` — the per-frame fast path a scroll-driven eviction should use
    /// instead of `evict(outside:)`'s O(count) full sweep. This is the RecyclerView "you are
    /// told what left, you don't scan" model: the caller (the scroll/bind driver) already knows
    /// precisely which keys fell out of the working range this frame — no need to test every
    /// cached key against a window `Set` to rediscover that.
    ///
    /// Unlike `evict(outside:)`, this does NOT touch the tracked `window` — it is a pure,
    /// incremental removal of the named keys, not a declaration of the new authoritative window.
    /// Pair with `admit(_:)` (which the driver already calls to declare entering keys) to keep
    /// `window` in sync with what's actually still in-range; call `evict(outside:)` instead of
    /// this when the caller wants to both replace the window wholesale AND sweep everything
    /// outside it (e.g. a width change or a full-list invalidation).
    ///
    /// A key with no cached entry is silently ignored (nothing to remove). `currentByteTotal`
    /// drops by exactly the summed cost of the keys that WERE cached among `keysThatLeft`.
    public func evict(_ keysThatLeft: Set<BlockKey>) {
        guard !keysThatLeft.isEmpty else { return }
        state.withLock { st in
            for key in keysThatLeft {
                Self.remove(&st, key)
            }
        }
    }

    // MARK: - Memory pressure

    /// Drops every cached bitmap outside the most recently declared working-range window (the
    /// union of every `admit(_:)` call and the last `evict(outside:)` window). If no window has
    /// ever been declared, the window is empty and this drops every cached bitmap.
    ///
    /// After this call, `currentByteTotal` equals the in-window total (or `0` if no window was
    /// ever declared), and `bitmap(for:)` returns `nil` for every dropped key.
    public func handleMemoryPressure() {
        state.withLock { st in
            let toRemove = st.entries.keys.filter { !st.window.contains($0) }
            for key in toRemove {
                Self.remove(&st, key)
            }
        }
    }

    // MARK: - Private (all operate under the lock — never call outside `state.withLock`)
    //
    // `evict(outside:)` and `handleMemoryPressure()` above stay O(count): they inherently need
    // to test every cached key against a window `Set`, so there's no avoiding a full sweep. The
    // list primitives below are the O(1) win — `touch`/`appendAtTail`/`remove` never scan.

    /// Unlinks `node` from wherever it currently sits in the list — head, tail, a middle
    /// position, or the sole node — without touching `entries` or `currentByteTotal`. Leaves
    /// `node.prev`/`node.next` `nil` (detached) on return.
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

    /// Appends `node` at the tail (most-recently-used end). `node` must already be detached
    /// (fresh, or just `unlink`ed).
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

    /// `protecting` is the key that was just stored this call — never evicts it even if, on its
    /// own, it exceeds `budget` (see `store(...)`'s doc: a single oversized entry is still kept).
    /// `protecting` is always at the tail by the time this runs (`store(...)` just appended or
    /// touched it), so the only way `head` can equal it is when it is the sole entry.
    private static func evictLRUUntilWithinBudget(_ st: inout State, budget: Int, protecting: BlockKey) {
        while st.currentByteTotal > budget {
            guard let victim = st.head, victim.key != protecting else { break }
            remove(&st, victim.key)
        }
    }
}

#if canImport(XCTest)
extension FrozenBitmapStore {
    /// Test-only internal-consistency check for the intrusive linked list. Walks head -> tail
    /// and verifies every invariant a broken unlink/relink could violate:
    /// - the walk terminates cleanly at both ends (`head.prev == nil` is implied by starting the
    ///   walk from `head`; explicitly checks the walk's last node IS `tail`)
    /// - every `prev` pointer agrees with the node walked immediately before it
    /// - the walked key set is EXACTLY `entries.keys` (no orphaned nodes, no missing ones)
    /// - the summed cost of walked nodes equals `currentByteTotal`
    ///
    /// Gated on `canImport(XCTest)`, NOT `#if DEBUG` — a Debug-configuration QA/TestFlight build
    /// must not ship this. Used by `FrozenBitmapStoreTests` stress coverage.
    func debugValidateListInvariants() -> Bool {
        state.withLock { st in
            var walked: Set<BlockKey> = []
            var summedCost = 0
            var previous: FrozenBitmapStore.Node?
            var current = st.head
            while let node = current {
                guard node.prev === previous else { return false }
                walked.insert(node.key)
                summedCost += node.cost
                previous = node
                current = node.next
            }
            guard previous === st.tail else { return false }
            guard summedCost == st.currentByteTotal else { return false }
            guard walked == Set(st.entries.keys) else { return false }
            guard walked.count == st.entries.count else { return false }
            return true
        }
    }
}
#endif

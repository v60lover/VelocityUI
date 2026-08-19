// FrozenBitmapStore.swift

import Foundation
import CoreGraphics
import os

/// Working-range / LRU-bounded cache for frozen block bitmaps (VelocityUI-qc7 phase B, spike
/// VelocityUI-6qd LB5). `freeze(_:)` (FreezeState.swift) rasterizes a text block once; this
/// store holds the resulting `CGImage` afterward, bounded so peak memory stays O(window) as a
/// chat grows, not O(chat length).
///
/// - CACHE, not keep-forever: eviction drops only the bitmap. The caller's `Block`/`BlockKey`
///   lives outside this type, so a re-entry just re-`freeze`s and re-`store`s cheaply.
/// - `final class ... : Sendable`, not an actor: `bitmap(for:)` must be synchronous (no
///   `await`) for the MainActor scroll path — state is guarded by `OSAllocatedUnfairLock`
///   (like `DimensionCache`) instead of actor isolation.
/// - Owned by `RenderEnvironment`, one per `AsyncFeed`. ARC releases every retained `CGImage`
///   on env deinit — no separate teardown.
public final class FrozenBitmapStore: Sendable {

    /// Intrusive doubly-linked-list node — both the cache entry and an LRU-order link, so a hit
    /// or store relinks in O(1) instead of scanning an array.
    ///
    /// - `entries` is the sole strong owner of every node; `prev`/`next`/`State.head`/`.tail` are
    ///   `weak` — two strong directions would form an A<->B retain cycle ARC can't break, which
    ///   would break this store's "deinit releases every CGImage" guarantee.
    /// - `@unchecked Sendable`: carries a `CGImage` (not `Sendable` in this SDK), same pattern as
    ///   `FreezeState.frozen`/`ImageActor.DecodeResult`. Safe because every `Node` is only touched
    ///   under `state.withLock` and never escapes that section — `bitmap(for:)` copies the `CGImage`
    ///   reference out while locked, the `Node` itself is never exposed.
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
        /// Byte budget for the LRU eviction triggered by every `store(...)` call. Lives in
        /// `State` (not a `let` on the outer type) because only the DRIVER (`FeedScrollView`)
        /// discovers the real working-range item count, and only after first layout — the
        /// composition root builds this store before the feed exists, so the initial value is
        /// necessarily a placeholder that `sizeBudget(forWindowCount:)` replaces once the real
        /// window is known. Mutating it under the same lock as every other read/write keeps
        /// `store(...)`'s eviction pass and a driver-triggered resize from racing each other.
        var byteBudget: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Current byte budget for the LRU eviction triggered by every `store(...)` call.
    ///
    /// Default 16 MB from VelocityUI-6qd LB3: ~0.5 MB per text-block bitmap at 2x scale, LB5
    /// observed a flat ~6 MB live footprint across a 50->500 message chat, so 16 MB gives ~2.5x
    /// headroom. Pass a tighter/looser budget explicitly, or let the driver call
    /// `sizeBudget(forWindowCount:)` once the real working range is known.
    public var byteBudget: Int {
        state.withLock { $0.byteBudget }
    }

    public init(byteBudget: Int = 16 * 1024 * 1024) {
        self.state = OSAllocatedUnfairLock(initialState: State(byteBudget: byteBudget))
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

    /// Computes a byte budget from the real working-range footprint: `windowCount` bitmaps at
    /// `perBitmapCost` bytes each, times `headroom` for slack.
    ///
    /// `headroom` exists because the raw window footprint isn't a safe budget on its own: a
    /// hot-tail re-freeze briefly holds both old and new bitmaps for the same key, and LRU churn
    /// at the window boundary can transiently exceed the raw total — `headroom <= 1.0` risks
    /// evicting an in-window block the instant that happens (the re-freeze/jank failure mode).
    /// Default `1.5` gives 50% slack. Returns `0` for a non-positive `windowCount`/
    /// `perBitmapCost` — callers passing `0` before the working range is known get an
    /// evict-everything budget, never a negative one.
    public static func budget(forWindowCount windowCount: Int, perBitmapCost: Int = defaultPerBitmapCost, headroom: Double = 1.5) -> Int {
        guard windowCount > 0, perBitmapCost > 0, headroom > 0 else { return 0 }
        return Int((Double(windowCount) * Double(perBitmapCost) * headroom).rounded(.up))
    }

    /// Re-sizes the byte budget from the real working-range footprint, discovered by the DRIVER
    /// at runtime (this store can't know the window shape at construction — env is built before
    /// the feed). GROW-ONLY: the constructed budget is a FLOOR this may only raise, never lower —
    /// `windowCount` counts ITEMS, but one long streaming message holds MANY frozen BLOCKS, so
    /// item count systematically underestimates the real footprint; sizing from a small
    /// `windowCount` would evict still-live blocks mid-stream. Since the budget never decreases,
    /// `currentByteTotal` stays within it automatically — a call whose computed budget is below
    /// the current floor is a safe no-op.
    public func sizeBudget(forWindowCount windowCount: Int, perBitmapCost: Int = defaultPerBitmapCost, headroom: Double = 1.5) {
        let newBudget = Self.budget(forWindowCount: windowCount, perBitmapCost: perBitmapCost, headroom: headroom)
        state.withLock { st in
            st.byteBudget = max(newBudget, st.byteBudget)
        }
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
    /// `pixelWidth * pixelHeight * 4` (caller derives those as `width/height * scale`).
    ///
    /// Re-storing an existing key updates in place (old cost subtracted first) and refreshes
    /// recency. Evicts least-recently-used entries, oldest first, until back within
    /// `byteBudget` — never rejects the insert itself, even one entry costing more than the
    /// whole budget; it only evicts everything else to make room.
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
            Self.evictLRUUntilWithinBudget(&st, budget: st.byteBudget, protecting: key)
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

    /// Drops the bitmap for every cached key NOT in `keys`, and REPLACES the tracked window with
    /// `keys` (the caller's full current window — use `admit(_:)` for incremental entries).
    ///
    /// Dropping only removes the bitmap; the caller's `Block`/`BlockKey` is untouched, so a
    /// dropped key can be cheaply re-`freeze`d if it scrolls back into range.
    public func evict(outside keys: Set<BlockKey>) {
        state.withLock { st in
            st.window = keys
            let toRemove = st.entries.keys.filter { !keys.contains($0) }
            for key in toRemove {
                Self.remove(&st, key)
            }
        }
    }

    /// Removes exactly the entries for `keysThatLeft`, in O(k) via the intrusive-list `remove` —
    /// the per-frame fast path a scroll-driven eviction should use instead of `evict(outside:)`'s
    /// O(count) sweep. RecyclerView model: the driver already knows what left, no need to test
    /// every cached key against a window `Set`.
    ///
    /// Also subtracts `keysThatLeft` from `window` — `admit(_:)` (union, entering) and this
    /// (subtract, leaving) are a symmetric incremental pair, unlike `evict(outside:)` which
    /// replaces `window` wholesale. Without the subtraction, `window` would grow forever under
    /// admit/evict-only usage and `handleMemoryPressure()` would become a no-op once `window`
    /// supersets every cached key.
    ///
    /// A key with no cached entry is silently ignored but still subtracted from `window`.
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
    /// Test-only consistency check for the intrusive linked list. Walks head -> tail and
    /// verifies: the walk ends exactly at `tail`, every `prev` agrees with its predecessor, the
    /// walked key set exactly matches `entries.keys`, and summed cost equals `currentByteTotal`.
    ///
    /// Gated on `canImport(XCTest)`, not `#if DEBUG` — must not ship in a Debug QA/TestFlight
    /// build. Used by `FrozenBitmapStoreTests` stress coverage.
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

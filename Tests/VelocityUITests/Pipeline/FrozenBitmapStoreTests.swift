// FrozenBitmapStoreTests.swift

import XCTest
import Foundation
import CoreGraphics
import os
@testable import VelocityUI

/// Deterministic PRNG (splitmix64-style) for the stress test below — fixed seed means the exact
/// same operation sequence runs every time, so a failure is reproducible instead of flaky.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Independent reference oracle for the stress test below: an array-based reimplementation of
/// the O(count) recency-array algorithm `FrozenBitmapStore` used BEFORE its intrusive
/// doubly-linked-list rewrite (VelocityUI-ry1v phase B). The rewrite must stay byte-for-byte
/// behaviorally identical, so this model is a trustworthy cross-check: a broken unlink/relink in
/// the new linked-list code shows up as a divergence from this old, structurally-simple version
/// rather than silently passing.
private struct ReferenceLRU {
    private var costs: [BlockKey: Int] = [:]
    private var recency: [BlockKey] = [] // oldest first
    private(set) var currentTotal = 0
    let budget: Int

    init(budget: Int) { self.budget = budget }

    mutating func store(_ key: BlockKey, cost: Int) {
        if let old = costs[key] {
            currentTotal -= old
            recency.removeAll { $0 == key }
        }
        costs[key] = cost
        currentTotal += cost
        recency.append(key)
        while currentTotal > budget, let victim = recency.first(where: { $0 != key }) {
            currentTotal -= costs[victim]!
            costs.removeValue(forKey: victim)
            recency.removeAll { $0 == victim }
        }
    }

    mutating func read(_ key: BlockKey) -> Bool {
        guard costs[key] != nil else { return false }
        recency.removeAll { $0 == key }
        recency.append(key)
        return true
    }

    mutating func evict(outside keys: Set<BlockKey>) {
        for key in Array(costs.keys) where !keys.contains(key) {
            currentTotal -= costs[key]!
            costs.removeValue(forKey: key)
            recency.removeAll { $0 == key }
        }
    }

    func contains(_ key: BlockKey) -> Bool { costs[key] != nil }
}

/// Covers VelocityUI-ry1v (hybrid reuse phase B): the working-range / LRU-bounded
/// `FrozenBitmapStore`. Needs no UIKit (only `CGImage`/`CGSize`/`BlockKey`), so every test
/// except the `RenderEnvironment` ownership section runs on plain `swift test`.
///
/// Acceptance-criterion -> test mapping (VelocityUI-ry1v):
/// - bitmap(for:) is SYNCHRONOUS, callable from a non-async context
///     -> testBitmapFor_IsSynchronouslyCallable_HitReturnsSameInstance_MissReturnsNil
/// - Byte budget + LRU: store exceeding byteBudget evicts LRU until within budget;
///   currentByteTotal never exceeds byteBudget after a store
///     -> testStore_ExceedingBudget_EvictsLeastRecentlyUsedUntilWithinBudget
/// - bitmap(for:) hit bumps recency, rescuing an entry from the next eviction
///     -> testBitmapFor_HitBumpsRecency_RescuesEntryFromNextEviction
/// - Working-range O(window) ceiling (LB5): peak currentByteTotal stays ~flat as chat grows
///   50 -> 500 messages, not with chat length
///     -> testSlidingWindow_PeakByteTotalStaysFlat_AsChatGrows50To500Messages
/// - evict drops only the bitmap, not the caller's descriptor; byteTotal drops by evicted cost
///     -> testEvict_DropsBitmapOnly_DescriptorUntouched_ByteTotalDropsByEvictedCost
/// - handleMemoryPressure() drops out-of-window bitmaps (collapses to in-window total, or 0);
///   a dropped key's bitmap(for:) returns nil
///     -> testHandleMemoryPressure_DropsOutOfWindowBitmaps_CollapsesToInWindowTotal
///     -> testHandleMemoryPressure_NoWindowEverAdmitted_DropsEverything
/// - RenderEnvironment owns it, no singleton, releases all bitmaps on env deinit
///     -> RenderEnvironment ownership section below (`#if canImport(UIKit)`)
///
/// Acceptance-criterion -> test mapping (VelocityUI-socg phase C1):
/// - evict(_ keysThatLeft:) removes exactly the named keys in O(k); byteTotal drops by their
///   cost; other entries untouched
///     -> testEvictKeysThatLeft_RemovesExactlyNamedKeys_OtherEntriesUntouched
///     -> testEvictKeysThatLeft_KeyNotCached_IsSilentlyIgnored
///     -> testEvictKeysThatLeft_EmptySet_IsNoOp
///     -> testEvictKeysThatLeft_LargeCache_OnlyNamedKeysRemoved
/// - budget-from-window sizing does not evict an in-window block
///     -> testBudgetForWindowCount_SizedBudget_DoesNotEvictAFullInWindowBudget
///     -> testBudgetForWindowCount_PureFunction_MatchesWindowCountTimesCostTimesHeadroom
///     -> testBudgetForWindowCount_UsesMeasuredDefaultPerBitmapCost
///     -> testBudgetForWindowCount_NonPositiveInputs_ReturnZero
///     -> testWindowCountConvenienceInit_ProducesSameBudgetAsStaticHelper
///
/// Acceptance-criterion -> test mapping (VelocityUI-socg finding #2 — driver-sized budget,
/// GROW-ONLY; see `sizeBudget`'s docstring for why item count underestimates a streaming
/// message's real block-count footprint):
/// - sizeBudget(forWindowCount:) raises byteBudget above the constructed floor when the real
///   footprint exceeds it
///     -> testSizeBudget_SetsByteBudget_MatchesStaticHelper
///     -> testSizeBudget_GrowingBudget_EvictsNothing
/// - sizeBudget(forWindowCount:) never lowers byteBudget below the floor, never evicts for a
///   smaller budget — a small windowCount is a safe no-op
///     -> testSizeBudget_SmallerWindow_IsNoOp_FloorHolds
///
/// Acceptance-criterion -> test mapping (VelocityUI-socg finding #1 — window stays bounded):
/// - evict(_ keysThatLeft:) subtracts departed keys from the tracked window, so admit (union) /
///   evict (subtract) form a symmetric pair and handleMemoryPressure() can still drop
///   out-of-window entries after a long scroll — window never grows unbounded
///     -> testEvictKeysThatLeft_RemovesFromWindow_SoMemoryPressureCanDropThem
final class FrozenBitmapStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// Renders a real CGImage without UIKit (pure CoreGraphics) — same technique as
    /// `BlockReuseTests.makeFakeCGImage`.
    private func makeFakeCGImage(width: Int, height: Int) -> CGImage {
        let w = max(1, width), h = max(1, height)
        let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func key(_ index: Int, itemID: String = "msg") -> BlockKey {
        BlockKey(itemID: itemID, index: index)
    }

    /// cost = pixelWidth * pixelHeight * 4 (BGRA8888), per VelocityUI-ry1v's spec — mirrors
    /// VelocityUI-6qd LB5's live-bitmap accounting.
    private func cost(width: Int, height: Int) -> Int { width * height * 4 }

    // MARK: - Acceptance 1: bitmap(for:) is synchronous

    func testBitmapFor_IsSynchronouslyCallable_HitReturnsSameInstance_MissReturnsNil() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let k = key(0)

        // No `await` anywhere in this test method (it is not even `async`) — bitmap(for:) type
        // -checks and runs here, proving it is callable from a synchronous context, exactly like
        // the MainActor bind/scroll path requires.
        XCTAssertNil(store.bitmap(for: k), "Miss on an empty store must return nil")

        let image = makeFakeCGImage(width: 10, height: 10)
        store.store(image, size: CGSize(width: 10, height: 10), cost: cost(width: 10, height: 10), for: k)

        let hit = store.bitmap(for: k)
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit === image, "A hit must return the SAME CGImage instance that was stored")
    }

    func testSizeFor_ReturnsStoredSize() {
        let store = FrozenBitmapStore()
        let k = key(0)
        XCTAssertNil(store.size(for: k))

        let size = CGSize(width: 42, height: 17)
        store.store(makeFakeCGImage(width: 42, height: 17), size: size, cost: cost(width: 42, height: 17), for: k)
        XCTAssertEqual(store.size(for: k), size)
    }

    // MARK: - Acceptance 2: byte budget + LRU eviction

    func testStore_ExceedingBudget_EvictsLeastRecentlyUsedUntilWithinBudget() {
        // Each entry costs 100 bytes; budget fits exactly 3.
        let store = FrozenBitmapStore(byteBudget: 300)
        let a = key(0), b = key(1), c = key(2), d = key(3)

        store.store(makeFakeCGImage(width: 5, height: 5), size: CGSize(width: 5, height: 5), cost: 100, for: a)
        store.store(makeFakeCGImage(width: 5, height: 5), size: CGSize(width: 5, height: 5), cost: 100, for: b)
        store.store(makeFakeCGImage(width: 5, height: 5), size: CGSize(width: 5, height: 5), cost: 100, for: c)
        XCTAssertEqual(store.currentByteTotal, 300, "Three 100-byte entries exactly fill a 300-byte budget")

        // Insertion order (no intervening reads) means `a` is the least-recently-used entry.
        store.store(makeFakeCGImage(width: 5, height: 5), size: CGSize(width: 5, height: 5), cost: 100, for: d)

        XCTAssertLessThanOrEqual(store.currentByteTotal, 300, "currentByteTotal must never exceed byteBudget after a store")
        XCTAssertNil(store.bitmap(for: a), "The least-recently-used entry (a) must be evicted to make room for d")
        XCTAssertNotNil(store.bitmap(for: b))
        XCTAssertNotNil(store.bitmap(for: c))
        XCTAssertNotNil(store.bitmap(for: d))
    }

    func testStore_ExceedingBudget_EmitsFrozenBitmapEvictionDiagnostics() {
        let events = OSAllocatedUnfairLock(initialState: [RasterDiagnosticsEvent]())
        let observer = RasterDiagnosticsObserver { event in
            events.withLock { $0.append(event) }
        }
        let store = FrozenBitmapStore(byteBudget: 300)
        store.setRasterDiagnosticsObserver(observer)

        let a = key(0)
        let b = key(1)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 200, for: a)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 200, for: b)

        let recorded = events.withLock { $0 }
        XCTAssertEqual(recorded.count, 1, "Exactly one bitmap should be evicted")
        guard recorded.count == 1 else { return }
        guard case .frozenBitmapEvicted(
            let evictedKey,
            let cost,
            let currentByteTotal,
            let byteBudget
        ) = recorded[0] else {
            return XCTFail("Expected a frozen bitmap eviction event")
        }
        XCTAssertEqual(evictedKey, a)
        XCTAssertEqual(cost, 200)
        XCTAssertEqual(currentByteTotal, 200)
        XCTAssertEqual(byteBudget, 300)
    }

    func testStore_SingleEntryLargerThanBudget_IsStillStored_NeverRejected() {
        // The store never rejects a caller's insert — it evicts everything ELSE to make room,
        // even if the new entry alone still exceeds budget.
        let store = FrozenBitmapStore(byteBudget: 50)
        let a = key(0)
        store.store(makeFakeCGImage(width: 5, height: 5), size: CGSize(width: 5, height: 5), cost: 200, for: a)
        XCTAssertNotNil(store.bitmap(for: a))
        XCTAssertEqual(store.currentByteTotal, 200)
    }

    func testStore_ReStoringSameKey_ReplacesCostWithoutDoubleCounting() {
        let store = FrozenBitmapStore(byteBudget: 1_000)
        let a = key(0)
        store.store(makeFakeCGImage(width: 5, height: 5), size: CGSize(width: 5, height: 5), cost: 100, for: a)
        XCTAssertEqual(store.currentByteTotal, 100)
        store.store(makeFakeCGImage(width: 6, height: 6), size: CGSize(width: 6, height: 6), cost: 150, for: a)
        XCTAssertEqual(store.currentByteTotal, 150, "Re-storing the same key must replace, not add to, its cost")
    }

    // MARK: - Acceptance 2b: LRU-recency-rescue

    func testBitmapFor_HitBumpsRecency_RescuesEntryFromNextEviction() {
        let store = FrozenBitmapStore(byteBudget: 300)
        let a = key(0), b = key(1), c = key(2), d = key(3)

        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: a)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: b)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: c)
        // Without a rescue, `a` (oldest) would be the next eviction victim. Touch it so `b`
        // becomes the new least-recently-used entry instead.
        XCTAssertNotNil(store.bitmap(for: a), "Hit rescues `a` — bumps it to most-recently-used")

        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: d)

        XCTAssertNotNil(store.bitmap(for: a), "`a` was rescued by the hit — must survive the eviction that follows")
        XCTAssertNil(store.bitmap(for: b), "`b` is now the least-recently-used entry — must be the eviction victim")
        XCTAssertNotNil(store.bitmap(for: c))
        XCTAssertNotNil(store.bitmap(for: d))
    }

    // MARK: - Acceptance 3: working-range O(window) memory ceiling (VelocityUI-6qd LB5)

    /// Simulates a sliding block window over a synthetic chat growing from 50 to 500 messages,
    /// one block per message. At each message, the window is the trailing `windowSize` blocks:
    /// entering keys are `store`d (with `admit` marking them in-window), keys that fell outside
    /// the window are dropped via `evict(outside:)`. Asserts peak `currentByteTotal` across the
    /// tail of the simulation (once the window is full) does not grow with message count — it
    /// stays bounded by `windowSize`, proving O(window) not O(chat length).
    func testSlidingWindow_PeakByteTotalStaysFlat_AsChatGrows50To500Messages() {
        let store = FrozenBitmapStore(byteBudget: 64 * 1024 * 1024) // budget large enough that
        // only the working-range sweep (not the byte-budget LRU) governs eviction in this test.
        let windowSize = 20
        let perBlockCost = cost(width: 300, height: 40) // one text-block-shaped bitmap

        var peakAfterWindowFull = 0
        var peakAt50: Int?
        var peakAt500: Int?

        for message in 1...500 {
            let k = key(message)
            let image = makeFakeCGImage(width: 1, height: 1) // cheap to allocate; cost is caller-declared
            store.store(image, size: CGSize(width: 300, height: 40), cost: perBlockCost, for: k)

            let windowStart = max(1, message - windowSize + 1)
            let window = Set((windowStart...message).map { key($0) })
            store.admit(window)
            store.evict(outside: window)

            if message >= windowSize {
                peakAfterWindowFull = max(peakAfterWindowFull, store.currentByteTotal)
            }
            if message == 50 { peakAt50 = store.currentByteTotal }
            if message == 500 { peakAt500 = store.currentByteTotal }
        }

        let expectedFlatCeiling = windowSize * perBlockCost
        XCTAssertLessThanOrEqual(peakAfterWindowFull, expectedFlatCeiling,
            "Peak byte total must stay bounded by window size * per-block cost, not grow with chat length")
        XCTAssertEqual(peakAt50, peakAt500,
            "currentByteTotal at message 50 and message 500 must be IDENTICAL (both fully saturate the same fixed window) — O(window), not O(chat length)")
        XCTAssertEqual(peakAt500, expectedFlatCeiling)
    }

    // MARK: - Acceptance 4: evict drops the bitmap, not the caller's descriptor

    func testEvict_DropsBitmapOnly_DescriptorUntouched_ByteTotalDropsByEvictedCost() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let evictedKey = key(0)
        let survivorKey = key(1)

        // The "descriptor" is the caller's own Block value — FrozenBitmapStore never stores it;
        // it is a plain external struct the test (standing in for the phase-C driver) keeps.
        let descriptor = Block(
            key: evictedKey,
            fragment: Fragment(id: 0, content: .geometry, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            layout: .placeholder
        )

        store.store(makeFakeCGImage(width: 10, height: 10), size: CGSize(width: 10, height: 10), cost: 400, for: evictedKey)
        store.store(makeFakeCGImage(width: 10, height: 10), size: CGSize(width: 10, height: 10), cost: 400, for: survivorKey)
        XCTAssertEqual(store.currentByteTotal, 800)

        store.evict(outside: [survivorKey])

        XCTAssertNil(store.bitmap(for: evictedKey), "Evicted key must miss on bitmap(for:)")
        XCTAssertNotNil(store.bitmap(for: survivorKey), "evict(outside:) must not touch keys inside the passed set")
        XCTAssertEqual(store.currentByteTotal, 400, "currentByteTotal must drop by exactly the evicted entry's cost")

        // The descriptor is completely untouched — it is the SAME key/fragment/layout it always
        // was; the store never held a reference to it, so eviction cannot have mutated it.
        XCTAssertEqual(descriptor.key, evictedKey)
        guard case .geometry = descriptor.fragment.content else {
            return XCTFail("Descriptor content must be unaffected by the store's eviction")
        }

        // The dropped key can be cheaply re-stored (standing in for a re-`freeze`) — proving
        // the descriptor survives well enough to re-enter the cache.
        store.store(makeFakeCGImage(width: 10, height: 10), size: CGSize(width: 10, height: 10), cost: 400, for: evictedKey)
        XCTAssertNotNil(store.bitmap(for: evictedKey))
    }

    // MARK: - Acceptance 5: handleMemoryPressure()

    func testHandleMemoryPressure_DropsOutOfWindowBitmaps_CollapsesToInWindowTotal() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let inWindow = key(0)
        let outOfWindow = key(1)

        store.store(makeFakeCGImage(width: 10, height: 10), size: .zero, cost: 300, for: inWindow)
        store.store(makeFakeCGImage(width: 10, height: 10), size: .zero, cost: 500, for: outOfWindow)
        XCTAssertEqual(store.currentByteTotal, 800)

        // Declare the working-range window WITHOUT evicting yet (admit only widens the tracked
        // window; it never drops bitmaps by itself).
        store.admit([inWindow])
        XCTAssertNotNil(store.bitmap(for: outOfWindow), "admit(_:) alone must not evict anything")

        store.handleMemoryPressure()

        XCTAssertEqual(store.currentByteTotal, 300, "After memory pressure, total must collapse to exactly the in-window total")
        XCTAssertNotNil(store.bitmap(for: inWindow))
        XCTAssertNil(store.bitmap(for: outOfWindow), "A dropped key must miss on a subsequent bitmap(for:)")
    }

    func testHandleMemoryPressure_NoWindowEverAdmitted_DropsEverything() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        store.store(makeFakeCGImage(width: 10, height: 10), size: .zero, cost: 300, for: key(0))
        store.store(makeFakeCGImage(width: 10, height: 10), size: .zero, cost: 300, for: key(1))
        XCTAssertEqual(store.currentByteTotal, 600)

        // No admit(_:) / evict(outside:) call has ever declared a window.
        store.handleMemoryPressure()

        XCTAssertEqual(store.currentByteTotal, 0, "With no window ever declared, memory pressure must drop everything")
        XCTAssertNil(store.bitmap(for: key(0)))
        XCTAssertNil(store.bitmap(for: key(1)))
    }

    func testEvict_UpdatesWindow_SoSubsequentMemoryPressureUsesTheNewWindow() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let a = key(0), b = key(1)
        store.store(makeFakeCGImage(width: 10, height: 10), size: .zero, cost: 100, for: a)
        store.store(makeFakeCGImage(width: 10, height: 10), size: .zero, cost: 100, for: b)

        // evict(outside:) both drops out-of-window entries AND declares its argument as the new
        // authoritative window (replacing whatever admit(_:) had accumulated).
        store.evict(outside: [a])
        XCTAssertNil(store.bitmap(for: b))

        store.handleMemoryPressure()
        XCTAssertNotNil(store.bitmap(for: a), "handleMemoryPressure() must use the window evict(outside:) just declared")
        XCTAssertEqual(store.currentByteTotal, 100)
    }

    // MARK: - Acceptance (VelocityUI-socg C1): evict(_ keysThatLeft:) delta eviction

    /// Covers the C1 acceptance criterion verbatim: removes exactly the named keys and drops
    /// `currentByteTotal` by their summed cost, leaving every OTHER entry untouched. Also
    /// subtracts the named keys from the tracked `window` (see `evict(_:)`'s docstring) — a
    /// separate test (`testEvictKeysThatLeft_RemovesFromWindow_SoMemoryPressureCanDropThem`)
    /// exercises that half of the contract directly; this test only asserts on cached
    /// entries/byte total, which `window` membership does not affect for keys never re-stored.
    func testEvictKeysThatLeft_RemovesExactlyNamedKeys_OtherEntriesUntouched() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let a = key(0), b = key(1), c = key(2), survivor = key(3)

        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: a)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: b)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: c)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: survivor)

        // Declare a working-range window that includes every key above.
        let window: Set<BlockKey> = [a, b, c, survivor]
        store.admit(window)
        XCTAssertEqual(store.currentByteTotal, 400)

        store.evict([a, b])

        XCTAssertNil(store.bitmap(for: a), "a must be evicted — it was named in keysThatLeft")
        XCTAssertNil(store.bitmap(for: b), "b must be evicted — it was named in keysThatLeft")
        XCTAssertNotNil(store.bitmap(for: c), "c was NOT named — must survive untouched")
        XCTAssertNotNil(store.bitmap(for: survivor), "survivor was NOT named — must survive untouched")
        XCTAssertEqual(store.currentByteTotal, 200, "currentByteTotal must drop by exactly the evicted keys' summed cost")
        XCTAssertTrue(store.debugValidateListInvariants())

        // c and survivor were never named in keysThatLeft, so evict(_:)'s window subtraction
        // (a, b only) leaves them in `window` — handleMemoryPressure() (which sweeps everything
        // OUTSIDE the tracked window) must still spare both.
        store.handleMemoryPressure()
        XCTAssertNotNil(store.bitmap(for: c), "c was never named in keysThatLeft — must still be in window, spared by memory pressure")
        XCTAssertNotNil(store.bitmap(for: survivor), "survivor was never named in keysThatLeft — must still be in window, spared by memory pressure")
    }

    func testEvictKeysThatLeft_KeyNotCached_IsSilentlyIgnored() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let cached = key(0)
        let neverStored = key(99)

        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: cached)
        XCTAssertEqual(store.currentByteTotal, 100)

        store.evict([neverStored])

        XCTAssertEqual(store.currentByteTotal, 100, "Evicting a key that was never cached must not change currentByteTotal")
        XCTAssertNotNil(store.bitmap(for: cached), "An unrelated cached key must survive a miss-only evict(_:) call")
        XCTAssertTrue(store.debugValidateListInvariants())
    }

    /// Regression guard for review finding #1: without `evict(_:)` subtracting from `window`,
    /// `admit`(union-only) and `evict(_:)`(never touching window) let `window` grow forever and
    /// eventually become a superset of every cached key, which makes `handleMemoryPressure()`
    /// silently drop nothing. Proves the fix by re-admitting a key that left, then WITHOUT
    /// re-`admit`-ing it, running `handleMemoryPressure()` and observing it gets dropped anyway
    /// (because `evict(_:)` already removed it from `window`) — the exact failure mode that
    /// would NOT reproduce if `window` had stayed a stale superset.
    func testEvictKeysThatLeft_RemovesFromWindow_SoMemoryPressureCanDropThem() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let a = key(0), b = key(1), c = key(2)

        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: a)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: b)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: c)
        store.admit([a, b, c]) // all three declared in-window

        // a "leaves the working range" — the driver's per-frame evict(_:) call.
        store.evict([a])
        XCTAssertNil(store.bitmap(for: a), "Sanity: a's bitmap is gone immediately after evict(_:)")

        // a re-enters the cache (e.g. scrolled back into view briefly and got re-frozen) WITHOUT
        // a matching admit(_:) call — standing in for the gap between a cache re-store and the
        // driver's next per-frame admit/evict pass.
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: a)
        XCTAssertNotNil(store.bitmap(for: a), "Sanity: a is cached again before the memory-pressure sweep")

        store.handleMemoryPressure()

        // With the fix, evict([a]) already subtracted a from `window`, so a is NOT in-window —
        // handleMemoryPressure() (which drops everything outside `window`) drops it. Without the
        // fix, `window` would still contain a (never subtracted), so a would incorrectly survive.
        XCTAssertNil(store.bitmap(for: a), "a must be dropped — evict(_:) removed it from window, so memory pressure treats it as out-of-window")
        XCTAssertNotNil(store.bitmap(for: b), "b was never evicted — must still be in window, spared by memory pressure")
        XCTAssertNotNil(store.bitmap(for: c), "c was never evicted — must still be in window, spared by memory pressure")
    }

    func testEvictKeysThatLeft_EmptySet_IsNoOp() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000)
        let a = key(0)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: a)

        store.evict([])

        XCTAssertEqual(store.currentByteTotal, 100)
        XCTAssertNotNil(store.bitmap(for: a))
    }

    /// O(k) contract: removing `k` named keys out of a much larger cache must not degrade to an
    /// O(count) sweep. Doesn't assert wall-clock complexity (flaky under load) — asserts the
    /// observable contract that only the named keys are affected, which an accidental "scan
    /// everything" bug (e.g. iterating `entries` instead of `keysThatLeft`) would violate.
    /// `debugValidateListInvariants()` catches any list corruption such a rewrite might introduce.
    func testEvictKeysThatLeft_LargeCache_OnlyNamedKeysRemoved() {
        let store = FrozenBitmapStore(byteBudget: 100_000_000)
        let allKeys = (0..<500).map { key($0) }
        for k in allKeys {
            store.store(makeFakeCGImage(width: 2, height: 2), size: .zero, cost: 100, for: k)
        }
        XCTAssertEqual(store.currentByteTotal, 500 * 100)

        let leaving = Set(allKeys.prefix(7)) // first 7 keys "left the window"
        store.evict(leaving)

        XCTAssertEqual(store.currentByteTotal, (500 - 7) * 100)
        for k in leaving {
            XCTAssertNil(store.bitmap(for: k))
        }
        for k in allKeys.dropFirst(7) {
            XCTAssertNotNil(store.bitmap(for: k))
        }
        XCTAssertTrue(store.debugValidateListInvariants())
    }

    // MARK: - Acceptance (VelocityUI-socg C1): budget-from-window sizing

    func testBudgetForWindowCount_PureFunction_MatchesWindowCountTimesCostTimesHeadroom() {
        let budget = FrozenBitmapStore.budget(forWindowCount: 20, perBitmapCost: 500_000, headroom: 1.5)
        XCTAssertEqual(budget, Int((20.0 * 500_000.0 * 1.5).rounded(.up)))
    }

    func testBudgetForWindowCount_UsesMeasuredDefaultPerBitmapCost() {
        let budget = FrozenBitmapStore.budget(forWindowCount: 10)
        XCTAssertEqual(budget, Int((10.0 * Double(FrozenBitmapStore.defaultPerBitmapCost) * 1.5).rounded(.up)))
    }

    func testBudgetForWindowCount_NonPositiveInputs_ReturnZero() {
        XCTAssertEqual(FrozenBitmapStore.budget(forWindowCount: 0), 0)
        XCTAssertEqual(FrozenBitmapStore.budget(forWindowCount: -5), 0)
        XCTAssertEqual(FrozenBitmapStore.budget(forWindowCount: 10, perBitmapCost: 0), 0)
    }

    func testWindowCountConvenienceInit_ProducesSameBudgetAsStaticHelper() {
        let expected = FrozenBitmapStore.budget(forWindowCount: 16, perBitmapCost: 400_000, headroom: 2.0)
        let store = FrozenBitmapStore(windowCount: 16, perBitmapCost: 400_000, headroom: 2.0)
        XCTAssertEqual(store.byteBudget, expected)
    }

    /// The actual failure mode `budget(forWindowCount:)` exists to prevent: a budget sized
    /// straight from the working-range window (no headroom) must not evict a block that is
    /// still inside that same window. Sizes a store's budget from a 20-block window, fills the
    /// store with exactly those 20 blocks at the assumed per-bitmap cost, and asserts every one
    /// survives — none were evicted to make room for a later one in the same window.
    func testBudgetForWindowCount_SizedBudget_DoesNotEvictAFullInWindowBudget() {
        let windowCount = 20
        let perBitmapCost = 500_000 // ~0.5 MB, matches the measured default
        let store = FrozenBitmapStore(windowCount: windowCount, perBitmapCost: perBitmapCost)

        let windowKeys = (0..<windowCount).map { key($0) }
        for k in windowKeys {
            store.store(makeFakeCGImage(width: 2, height: 2), size: .zero, cost: perBitmapCost, for: k)
        }

        for k in windowKeys {
            XCTAssertNotNil(store.bitmap(for: k), "A budget sized from the real window must not self-evict an in-window block")
        }
        XCTAssertEqual(store.currentByteTotal, windowCount * perBitmapCost)
    }

    // MARK: - Acceptance (VelocityUI-socg C4): sizeBudget(forWindowCount:) driver-triggered resize
    //
    // GROW-ONLY (device-regression follow-up): `windowCount` counts ITEMS, but one streaming
    // message is ONE item holding MANY frozen BLOCKS, so item count underestimates the real
    // footprint. `sizeBudget` therefore only ever RAISES `byteBudget` above the constructed floor
    // (16 MB default) — never lowers it, never evicts.

    /// `sizeBudget(forWindowCount:)` is the seam `FeedScrollView.updateVisibleCells` calls once
    /// the real working-range item count is known (the store itself is constructed before the
    /// feed exists, so it cannot know this at `init`). Constructs with a TINY floor so the
    /// computed window budget clearly exceeds it, proving the raise actually took effect (not
    /// just "stayed at the floor," which a no-op implementation could also satisfy).
    func testSizeBudget_SetsByteBudget_MatchesStaticHelper() {
        let store = FrozenBitmapStore(byteBudget: 1) // floor far below any real window budget

        store.sizeBudget(forWindowCount: 16, perBitmapCost: 400_000, headroom: 2.0)

        let expected = FrozenBitmapStore.budget(forWindowCount: 16, perBitmapCost: 400_000, headroom: 2.0)
        XCTAssertEqual(store.byteBudget, expected, "The raise must win over the tiny floor")
    }

    /// The device-regression this test guards against: a small `windowCount` (e.g. the flagship's
    /// one-item streaming-message window) computes a budget BELOW the constructed floor. That must
    /// be a safe no-op — `byteBudget` stays at the floor, and NOTHING already cached is evicted to
    /// chase a smaller ceiling. Without this floor, `sizeBudget(forWindowCount: 1)` would starve a
    /// single tall message's frozen blocks as it grows past a couple of them.
    func testSizeBudget_SmallerWindow_IsNoOp_FloorHolds() {
        let store = FrozenBitmapStore(byteBudget: 1_000_000) // the floor
        let a = key(0), b = key(1), c = key(2), d = key(3)

        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: a)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: b)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: c)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: d)
        XCTAssertEqual(store.currentByteTotal, 400)

        // A small window (e.g. windowCount == 1, mirroring the flagship's one-item streaming
        // window) computes a budget far below the 1,000,000-byte floor.
        let smallWindowBudget = FrozenBitmapStore.budget(forWindowCount: 1, perBitmapCost: 100, headroom: 1.0)
        XCTAssertLessThan(smallWindowBudget, 1_000_000, "Precondition: the small-window budget must actually be below the floor")

        store.sizeBudget(forWindowCount: 1, perBitmapCost: 100, headroom: 1.0)

        XCTAssertEqual(store.byteBudget, 1_000_000, "byteBudget must stay at the constructed floor — a smaller window must never lower it")
        XCTAssertEqual(store.currentByteTotal, 400, "Nothing must be evicted just because a smaller window was reported")
        XCTAssertNotNil(store.bitmap(for: a))
        XCTAssertNotNil(store.bitmap(for: b))
        XCTAssertNotNil(store.bitmap(for: c))
        XCTAssertNotNil(store.bitmap(for: d))
        XCTAssertTrue(store.debugValidateListInvariants())
    }

    /// Growing the budget (the only direction the live driver ever calls this in — see
    /// `FeedScrollView._frozenBudgetWindowCount`'s monotonic-up guard) must never evict anything.
    func testSizeBudget_GrowingBudget_EvictsNothing() {
        let store = FrozenBitmapStore(windowCount: 2, perBitmapCost: 100, headroom: 1.0) // budget == 200
        let a = key(0), b = key(1)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: a)
        store.store(makeFakeCGImage(width: 5, height: 5), size: .zero, cost: 100, for: b)
        XCTAssertEqual(store.currentByteTotal, 200)

        store.sizeBudget(forWindowCount: 10, perBitmapCost: 100, headroom: 1.0) // budget == 1000

        XCTAssertEqual(store.byteBudget, 1000)
        XCTAssertNotNil(store.bitmap(for: a))
        XCTAssertNotNil(store.bitmap(for: b))
        XCTAssertEqual(store.currentByteTotal, 200, "Growing the budget must not evict — nothing was over it to begin with")
    }

    // MARK: - Stress: intrusive-list invariants under randomized interleaving

    /// Regression guard for the intrusive doubly-linked-list rewrite (VelocityUI-ry1v phase B):
    /// interleaves 2000 store/bitmap(for:)/evict(outside:) calls across a 6-key universe with a
    /// budget that fits only 3, so eviction fires constantly — forcing every unlink edge case
    /// (empty list, single node, unlink head/tail/middle, evict-all via empty window) many times.
    ///
    /// Cross-checks every step against `ReferenceLRU` (the old array-based algorithm): a broken
    /// unlink/relink shows up as `currentByteTotal` drift, a hit/miss disagreement, or
    /// `debugValidateListInvariants()` catching a corrupted node directly. Seeded PRNG — same
    /// sequence every run, so failures reproduce.
    func testStressInterleavedOps_StaysConsistentWithReferenceLRU_AndListInvariantsHold() {
        let budget = 300 // fits exactly 3 of the 6 keys below -> eviction fires constantly
        let store = FrozenBitmapStore(byteBudget: budget)
        var oracle = ReferenceLRU(budget: budget)
        var rng = SeededGenerator(seed: 0xC0FFEE)

        let universe = (0..<6).map { key($0) }
        let perKeyCost = 100 // budget / perKeyCost == 3, matches ReferenceLRU's fixed-cost math

        for step in 0..<2_000 {
            let k = universe[Int.random(in: 0..<universe.count, using: &rng)]
            let roll = Double.random(in: 0..<1, using: &rng)

            if roll < 0.5 {
                let image = makeFakeCGImage(width: 5, height: 5)
                store.store(image, size: CGSize(width: 5, height: 5), cost: perKeyCost, for: k)
                oracle.store(k, cost: perKeyCost)
            } else if roll < 0.9 {
                let realHit = store.bitmap(for: k) != nil
                let oracleHit = oracle.read(k)
                XCTAssertEqual(realHit, oracleHit, "Step \(step): bitmap(for:) hit/miss must match the reference model for key \(k)")
            } else {
                // Random window subset (0-3 keys, occasionally empty -> evicts everything).
                let windowCount = Int.random(in: 0...3, using: &rng)
                let window = Set(universe.shuffled(using: &rng).prefix(windowCount))
                store.evict(outside: window)
                oracle.evict(outside: window)
            }

            XCTAssertEqual(store.currentByteTotal, oracle.currentTotal, "Step \(step): currentByteTotal diverged from the reference model")
            XCTAssertTrue(store.debugValidateListInvariants(), "Step \(step): intrusive list invariants broken (dangling/orphaned node or corrupted prev/next)")
        }

        // Final full cross-check across the whole key universe.
        for k in universe {
            XCTAssertEqual(store.bitmap(for: k) != nil, oracle.contains(k), "Final state diverged from the reference model for key \(k)")
        }
        XCTAssertEqual(store.currentByteTotal, oracle.currentTotal)
    }

    // MARK: - Regression guard: weak prev/next avoids a Node retain cycle (no UIKit required)

    /// Guards the weak-link decision on `FrozenBitmapStore.Node`: `entries` is the sole strong
    /// owner of every `Node`; `prev`/`next` are `weak` so two adjacent nodes never form an
    /// `A.next <-> B.prev` retain cycle. The UIKit-gated store-teardown test only proves the
    /// STORE is released, not that nodes don't retain each other — this closes that gap on plain
    /// `swift test` by observing a bitmap held by a node with BOTH a live prev and next link, and
    /// asserting it's released once the store goes away. If `Node.prev`/`next` were ever changed
    /// to a strong `var`, this would FAIL: the cycle would keep the middle node (and its bitmap)
    /// alive after `entries`, and the store, is gone.
    func testDroppingStore_ReleasesNodesAndBitmaps_NoStrongLinkRetainCycle() {
        // Bulletproof dealloc observation: a CGDataProvider release callback fires exactly when
        // the CGImage built from it (and thus the provider) is deallocated. This is preferred
        // over `weak var image: CGImage?` because CF-bridged types are not guaranteed to zero a
        // Swift weak reference on dealloc in every SDK -- the callback has no such assumption.
        let released = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        released.initialize(to: false)
        defer { released.deallocate() }

        do {
            let store = FrozenBitmapStore(byteBudget: 1_000_000)
            let a = key(0), b = key(1), c = key(2)

            let width = 4, height = 4
            let bytesPerRow = width * 4
            let byteCount = bytesPerRow * height
            let pixelData = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
            pixelData.initialize(repeating: 0, count: byteCount)

            let provider = CGDataProvider(
                dataInfo: UnsafeMutableRawPointer(released),
                data: pixelData,
                size: byteCount,
                releaseData: { info, data, _ in
                    info?.assumingMemoryBound(to: Bool.self).pointee = true
                    UnsafeMutableRawPointer(mutating: data).deallocate()
                }
            )!

            let middleImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!

            // Store three keys so `b` (the observed one) ends up with BOTH a live prev (`a`) and
            // next (`c`) link -- the exact configuration a strong-link cycle would leak.
            store.store(makeFakeCGImage(width: 4, height: 4), size: CGSize(width: 4, height: 4), cost: 64, for: a)
            store.store(middleImage, size: CGSize(width: width, height: height), cost: 64, for: b)
            store.store(makeFakeCGImage(width: 4, height: 4), size: CGSize(width: 4, height: 4), cost: 64, for: c)

            XCTAssertNotNil(store.bitmap(for: b), "Sanity: the middle bitmap must be live while the store holds it")
            XCTAssertFalse(released.pointee, "Bitmap must not be released while the store still retains its node")

            // The test holds no strong reference to `middleImage` beyond this point -- `store`
            // (via `entries`) is the SOLE strong owner. Dropping `store` at the end of this
            // `do` block must release it.
        }

        XCTAssertTrue(released.pointee, "Dropping the store must release the middle node's bitmap -- a strong prev/next link would form an A.next<->B.prev cycle keeping it (and the node) alive after `entries`, and thus the store, is gone")
    }
}

// MARK: - Acceptance 6: RenderEnvironment ownership + no leaked bitmaps after teardown

#if canImport(UIKit)
extension FrozenBitmapStoreTests {

    @MainActor
    private func makeEnvironment(store: FrozenBitmapStore) -> RenderEnvironment {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: store,
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            hotCodeStreamStore: HotCodeStreamStore()
        )
    }

    @MainActor
    func testRenderEnvironment_OwnsInjectedFrozenBitmapStore_SameInstance() {
        let store = FrozenBitmapStore()
        let env = makeEnvironment(store: store)
        XCTAssertTrue(env.frozenBitmapStore === store, "RenderEnvironment must expose the SAME instance it was injected with")
    }

    @MainActor
    func testRenderEnvironment_ConvenienceInit_DefaultConstructsAWorkingStore() {
        let env = RenderEnvironment()
        let k = BlockKey(itemID: "msg", index: 0)
        XCTAssertNil(env.frozenBitmapStore.bitmap(for: k))
        XCTAssertEqual(env.frozenBitmapStore.currentByteTotal, 0)
    }

    @MainActor
    func testRenderEnvironment_Teardown_ReleasesFrozenBitmapStore_NoLeak() {
        weak var weakStore: FrozenBitmapStore?
        var env: RenderEnvironment?

        do {
            let store = FrozenBitmapStore()
            weakStore = store
            let k = BlockKey(itemID: "msg", index: 0)
            let image = { () -> CGImage in
                let ctx = CGContext(
                    data: nil, width: 4, height: 4,
                    bitsPerComponent: 8, bytesPerRow: 16,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                return ctx.makeImage()!
            }()
            store.store(image, size: CGSize(width: 4, height: 4), cost: 64, for: k)
            env = makeEnvironment(store: store)
            XCTAssertNotNil(weakStore)
        }

        XCTAssertNotNil(weakStore, "The store must still be alive — RenderEnvironment (env) retains it")
        env = nil
        XCTAssertNil(weakStore, "Once RenderEnvironment deinits, its FrozenBitmapStore (and every bitmap it held) must be released — no leak")
    }
}
#endif

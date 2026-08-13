// FrozenBitmapStoreTests.swift

import XCTest
import Foundation
import CoreGraphics
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
/// `FrozenBitmapStore`. Mirrors `BlockReuseTests`' approach — the store itself needs no UIKit
/// (only `CGImage`/`CGSize`/`BlockKey`), so every test below except the `RenderEnvironment`
/// ownership section runs on plain `swift test`, no DeviceTestHost required. `makeFakeCGImage`
/// below is pure CoreGraphics, the same technique `BlockReuseTests.makeFakeCGImage` uses.
///
/// Acceptance-criterion -> test mapping (VelocityUI-ry1v):
/// - "bitmap(for:) returns CGImage? SYNCHRONOUSLY, callable from a non-async context"
///     -> testBitmapFor_IsSynchronouslyCallable_HitReturnsSameInstance_MissReturnsNil
/// - "Byte budget + LRU: storing entries whose total cost exceeds byteBudget evicts LRU until
///    within budget; currentByteTotal never exceeds byteBudget after a store"
///     -> testStore_ExceedingBudget_EvictsLeastRecentlyUsedUntilWithinBudget
/// - "bitmap(for:) hit bumps recency (a hit rescues an entry from being the next eviction victim)"
///     -> testBitmapFor_HitBumpsRecency_RescuesEntryFromNextEviction
/// - "Working-range O(window) memory ceiling (LB5): peak currentByteTotal stays ~flat as chat
///    grows from 50 -> 500 messages, NOT growing with chat length"
///     -> testSlidingWindow_PeakByteTotalStaysFlat_AsChatGrows50To500Messages
/// - "Evict drops the bitmap but not the caller's descriptor; currentByteTotal drops by the
///    evicted cost"
///     -> testEvict_DropsBitmapOnly_DescriptorUntouched_ByteTotalDropsByEvictedCost
/// - "handleMemoryPressure() drops out-of-window bitmaps (collapses to in-window total, or 0 if
///    none admitted); a subsequent bitmap(for:) for a dropped key returns nil"
///     -> testHandleMemoryPressure_DropsOutOfWindowBitmaps_CollapsesToInWindowTotal
///     -> testHandleMemoryPressure_NoWindowEverAdmitted_DropsEverything
/// - "RenderEnvironment owns it ... no singleton ... releases all bitmaps on env deinit"
///     -> RenderEnvironment ownership section below (`#if canImport(UIKit)`, needs the
///        UIKit-gated RenderEnvironment/VideoController/ImageActor types).
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

    // MARK: - Stress: intrusive-list invariants under randomized interleaving

    /// Regression guard for the intrusive doubly-linked-list rewrite (VelocityUI-ry1v phase B):
    /// interleaves 2000 store/bitmap(for:)/evict(outside:) calls across a 6-key universe, with a
    /// budget that fits only 3 of them so eviction fires constantly. That forces every unlink
    /// edge case — empty list, single node, unlinking the head, unlinking the tail, unlinking a
    /// middle node, and evicting the entire list via an empty window — to happen many times over.
    ///
    /// Cross-checks every step against `ReferenceLRU` (the old, structurally-simple array-based
    /// algorithm this store used before the rewrite): a broken unlink/relink shows up either as
    /// `currentByteTotal` drifting from the oracle, a hit/miss disagreeing with the oracle, or
    /// `debugValidateListInvariants()` catching a dangling/orphaned node or corrupted prev/next
    /// directly. Seeded PRNG — same sequence every run, so a failure reproduces.
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

    /// Guards the weak-link decision documented on `FrozenBitmapStore.Node` (FrozenBitmapStore.swift):
    /// `entries` is the SOLE strong owner of every `Node`; `prev`/`next` (and `State.head`/`tail`)
    /// are `weak` specifically so two adjacent nodes never form an `A.next <-> B.prev` retain
    /// cycle. `testRenderEnvironment_Teardown_ReleasesFrozenBitmapStore_NoLeak` (below, UIKit
    /// -gated) only proves the STORE itself is released -- it can't detect a cycle between NODES,
    /// because the store deallocates regardless of whether its nodes retain each other. This test
    /// closes that gap on plain `swift test`: it observes a bitmap held by a node with BOTH a live
    /// prev and next link (the exact shape a strong-link cycle would leak) and asserts it is
    /// actually released once the store goes away. If `Node.prev`/`Node.next` were ever changed
    /// from `weak var` to a strong `var`, this test would FAIL -- the release flag would stay
    /// `false` because the cycle keeps the middle node (and its bitmap) alive after `entries`,
    /// and thus the store, is gone.
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
            frozenBitmapStore: store
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

// LayoutCacheTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

final class LayoutCacheTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(height: CGFloat = 100) -> CellEntry {
        CellEntry(
            layout: ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 375, height: height)),
            fragments: []
        )
    }

    // MARK: - Basic semantics

    func testGetMissReturnsNil() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 42, width: 375)
        let result = await cache.get(key)
        XCTAssertNil(result)
    }

    func testSetAndGet() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 42, width: 375)
        await cache.set(makeEntry(height: 200), for: key)
        let result = await cache.get(key)
        XCTAssertEqual(result?.layout.totalFrame.height, 200)
    }

    func testDifferentWidthProducesDifferentKey() async {
        let cache = LayoutCache()
        let key375 = CacheKey(layoutHash: 1, width: 375)
        let key428 = CacheKey(layoutHash: 1, width: 428)
        await cache.set(makeEntry(height: 100), for: key375)
        let result428 = await cache.get(key428)
        XCTAssertNil(result428, "Different width must not share a cache entry")
    }

    func testDifferentLayoutHashProducesDifferentKey() async {
        let cache = LayoutCache()
        let key1 = CacheKey(layoutHash: 1, width: 375)
        let key2 = CacheKey(layoutHash: 2, width: 375)
        await cache.set(makeEntry(height: 100), for: key1)
        let result2 = await cache.get(key2)
        XCTAssertNil(result2, "Different layoutHash must not share a cache entry")
    }

    func testUpdateInPlaceDoesNotGrowCount() async {
        let cache = LayoutCache(capacity: 10)
        let key = CacheKey(layoutHash: 1, width: 375)
        await cache.set(makeEntry(height: 100), for: key)
        await cache.set(makeEntry(height: 200), for: key)
        let count = await cache.count
        XCTAssertEqual(count, 1, "Re-setting the same key must update in-place, not insert a second entry")
        let result = await cache.get(key)
        XCTAssertEqual(result?.layout.totalFrame.height, 200)
    }

    // MARK: - Invalidation

    func testInvalidateSingleEntry() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 1, width: 375)
        let otherKey = CacheKey(layoutHash: 2, width: 375)
        await cache.set(makeEntry(), for: key)
        await cache.set(makeEntry(), for: otherKey)
        await cache.invalidate(key)
        let afterInvalidate = await cache.get(key)
        let otherAfterInvalidate = await cache.get(otherKey)
        XCTAssertNil(afterInvalidate, "invalidate must remove the targeted entry")
        XCTAssertNotNil(otherAfterInvalidate, "invalidate must not remove other entries")
    }

    func testInvalidateMissingKeyIsNoop() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 99, width: 375)
        // Must not crash
        await cache.invalidate(key)
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidateAllClearsCache() async {
        let cache = LayoutCache()
        for i in 0..<10 {
            await cache.set(makeEntry(), for: CacheKey(layoutHash: i, width: 375))
        }
        await cache.invalidateAll()
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    func testSetAfterInvalidateAllWorks() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 1, width: 375)
        await cache.set(makeEntry(height: 50), for: key)
        await cache.invalidateAll()
        await cache.set(makeEntry(height: 80), for: key)
        let result = await cache.get(key)
        XCTAssertEqual(result?.layout.totalFrame.height, 80)
    }

    // MARK: - Eviction

    func testCapacityRespected() async {
        let cap = 5
        let cache = LayoutCache(capacity: cap)
        for i in 0..<(cap + 3) {
            await cache.set(makeEntry(height: CGFloat(i)), for: CacheKey(layoutHash: i, width: 375))
        }
        let count = await cache.count
        XCTAssertEqual(count, cap, "Count must never exceed capacity")
    }

    func testFIFOEvictsOldestEntry() async {
        let cap = 3
        let cache = LayoutCache(capacity: cap)
        let oldestKey = CacheKey(layoutHash: 0, width: 375)
        await cache.set(makeEntry(height: 10), for: oldestKey)
        await cache.set(makeEntry(height: 20), for: CacheKey(layoutHash: 1, width: 375))
        await cache.set(makeEntry(height: 30), for: CacheKey(layoutHash: 2, width: 375))
        // 4th insert triggers eviction of hash=0 (oldest)
        let newestKey = CacheKey(layoutHash: 3, width: 375)
        await cache.set(makeEntry(height: 40), for: newestKey)
        let oldest = await cache.get(oldestKey)
        let newest = await cache.get(newestKey)
        let countAfterEviction = await cache.count
        XCTAssertNil(oldest, "Oldest-inserted entry must be evicted when cap is reached")
        XCTAssertNotNil(newest, "Newest entry must survive eviction")
        XCTAssertEqual(countAfterEviction, cap)
    }

    // MARK: - cachedEntry (nonisolated peek, VelocityUI-1su.2)

    /// Invariant: `cachedEntry(for:)` returns the entry written by `set()`, callable with
    /// zero `await` from any isolation context (AC1).
    func testCachedEntrySynchronousPeekAfterSet() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 7, width: 375)
        await cache.set(makeEntry(height: 250), for: key)

        // No `await` here — this is the point of the test. If cachedEntry required
        // actor isolation this line would fail to compile.
        let result = cache.cachedEntry(for: key)
        XCTAssertEqual(result?.layout.totalFrame.height, 250)
    }

    /// Invariant: a miss (never set, or different key) returns nil rather than triggering work.
    func testCachedEntryMissReturnsNil() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 8, width: 375)
        XCTAssertNil(cache.cachedEntry(for: key))

        // Populate a sibling key — must not satisfy the miss key.
        await cache.set(makeEntry(), for: CacheKey(layoutHash: 9, width: 375))
        XCTAssertNil(cache.cachedEntry(for: key))
    }

    /// Invariant: the nonisolated read-mirror stays in lockstep with the authoritative store —
    /// `invalidate` and `invalidateAll` must be visible to `cachedEntry`, not just `get`.
    func testCachedEntryReflectsInvalidateAndInvalidateAll() async {
        let cache = LayoutCache()
        let key1 = CacheKey(layoutHash: 10, width: 375)
        let key2 = CacheKey(layoutHash: 11, width: 375)
        await cache.set(makeEntry(height: 40), for: key1)
        await cache.set(makeEntry(height: 60), for: key2)
        XCTAssertNotNil(cache.cachedEntry(for: key1))
        XCTAssertNotNil(cache.cachedEntry(for: key2))

        await cache.invalidate(key1)
        XCTAssertNil(cache.cachedEntry(for: key1), "invalidate must remove the entry from the read-mirror too")
        XCTAssertNotNil(cache.cachedEntry(for: key2), "invalidate must not affect other keys' mirror entries")

        await cache.invalidateAll()
        XCTAssertNil(cache.cachedEntry(for: key2), "invalidateAll must clear the read-mirror too")
    }

    /// Invariant: re-setting an existing key (in-place update path) updates the mirror, not
    /// just the authoritative store.
    func testCachedEntryReflectsInPlaceUpdate() async {
        let cache = LayoutCache()
        let key = CacheKey(layoutHash: 12, width: 375)
        await cache.set(makeEntry(height: 10), for: key)
        await cache.set(makeEntry(height: 20), for: key)
        XCTAssertEqual(cache.cachedEntry(for: key)?.layout.totalFrame.height, 20,
            "In-place update must be reflected in the nonisolated read-mirror")
    }

    /// Invariant: FIFO eviction from the authoritative store must also evict the entry from
    /// the read-mirror — otherwise cachedEntry would serve a stale hit for an evicted key.
    func testCachedEntryClearedOnFIFOEviction() async {
        let cap = 3
        let cache = LayoutCache(capacity: cap)
        let oldestKey = CacheKey(layoutHash: 0, width: 375)
        await cache.set(makeEntry(height: 10), for: oldestKey)
        await cache.set(makeEntry(height: 20), for: CacheKey(layoutHash: 1, width: 375))
        await cache.set(makeEntry(height: 30), for: CacheKey(layoutHash: 2, width: 375))
        await cache.set(makeEntry(height: 40), for: CacheKey(layoutHash: 3, width: 375))

        XCTAssertNil(cache.cachedEntry(for: oldestKey),
            "Evicted key must not be servable via cachedEntry — mirror must evict in lockstep")
    }

    // MARK: - Concurrent access

    func testConcurrentAccessIsRaceFree() async {
        // 20 tasks × 100 ops each. Actor isolation guarantees no data races;
        // this test verifies correctness holds under concurrent access.
        let cache = LayoutCache(capacity: 500)
        await withTaskGroup(of: Void.self) { group in
            for taskID in 0..<20 {
                group.addTask {
                    for op in 0..<100 {
                        let hash = (taskID * 100 + op) % 200
                        let key = CacheKey(layoutHash: hash, width: 375)
                        let entry = CellEntry(
                            layout: ResolvedLayout(
                                totalFrame: CGRect(x: 0, y: 0, width: 375, height: CGFloat(op))
                            ),
                            fragments: []
                        )
                        if op % 3 == 0 {
                            await cache.set(entry, for: key)
                        } else {
                            _ = await cache.get(key)
                        }
                    }
                }
            }
        }
        let count = await cache.count
        XCTAssertLessThanOrEqual(count, 500, "Count must not exceed capacity after concurrent access")
    }

    // MARK: - Framing (VelocityUI-rsg / VelocityUI-3a4)

    /// Pipeline-level guarantee: a `.frame()` edit must invalidate the cache rather than
    /// silently reusing a stale (differently-sized) measurement. `NodeTable.layoutHash`
    /// already folds framing in (VelocityUI-x8a/dv7, see `testFlatten_framing_foldsIntoLayoutHash`
    /// in FlattenTests) — this test exercises the consumer of that hash: `CacheKey` +
    /// `LayoutCache` built from two REAL flatten()-produced tables that differ only by `.frame()`.
    @MainActor
    func testFramingChangesLayoutHash_producesDistinctCacheKey_missOnLookup() async {
        let unframedTable = flatten(AsyncImageNode(url: nil, aspectRatio: 1.0), itemID: "cache-frame")
        let framedTable = flatten(AsyncImageNode(url: nil, aspectRatio: 1.0).frame(width: 200), itemID: "cache-frame")

        XCTAssertNotEqual(unframedTable.layoutHash, framedTable.layoutHash,
            "a .frame() change must produce a different layoutHash for otherwise-identical content")

        let cache = LayoutCache()
        let unframedKey = CacheKey(layoutHash: unframedTable.layoutHash, width: 375)
        let framedKey = CacheKey(layoutHash: framedTable.layoutHash, width: 375)

        await cache.set(makeEntry(height: 100), for: unframedKey)

        let hitOnFramedKey = await cache.get(framedKey)
        XCTAssertNil(hitOnFramedKey, "a .frame() change must miss the cache entry stored for the unframed table")

        let hitOnUnframedKey = await cache.get(unframedKey)
        XCTAssertNotNil(hitOnUnframedKey, "the original unframed entry must remain retrievable under its own key")
    }
}
#endif

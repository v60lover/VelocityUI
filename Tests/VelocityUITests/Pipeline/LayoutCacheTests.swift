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
        XCTAssertNil(await cache.get(key428), "Different width must not share a cache entry")
    }

    func testDifferentLayoutHashProducesDifferentKey() async {
        let cache = LayoutCache()
        let key1 = CacheKey(layoutHash: 1, width: 375)
        let key2 = CacheKey(layoutHash: 2, width: 375)
        await cache.set(makeEntry(height: 100), for: key1)
        XCTAssertNil(await cache.get(key2), "Different layoutHash must not share a cache entry")
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
        XCTAssertNil(await cache.get(key), "invalidate must remove the targeted entry")
        XCTAssertNotNil(await cache.get(otherKey), "invalidate must not remove other entries")
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
        XCTAssertNil(await cache.get(oldestKey), "Oldest-inserted entry must be evicted when cap is reached")
        XCTAssertNotNil(await cache.get(newestKey), "Newest entry must survive eviction")
        XCTAssertEqual(await cache.count, cap)
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
}
#endif

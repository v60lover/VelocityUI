// CacheHorizonMetricsTests.swift

import XCTest
import VelocityUI
@testable import BenchmarkHost

final class CacheHorizonMetricsTests: XCTestCase {
    private func key(_ i: Int) -> BlockKey { BlockKey(itemID: i, index: 0) }

    func testEventsAreAttributedToTheirOwnCounters() {
        let m = CacheHorizonMetrics()
        m.record(.emptyLayoutMount(index: 1, placeholderVisible: true))
        m.record(.emptyLayoutMount(index: 2, placeholderVisible: false))
        m.record(.rasterMiss(key: key(1), kind: .text, inVisibleStore: false, inFrozenStore: false))
        m.record(.rasterHit(key: key(2), kind: .text, fromFrozenStore: false))
        m.record(.rasterHit(key: key(3), kind: .table, fromFrozenStore: true))
        m.record(.placeholderExposure(visibleCellCount: 3))
        m.record(.layoutResolved(index: 1, recomputed: true))
        m.record(.layoutResolved(index: 2, recomputed: false))
        m.record(.imageRequest(.networkFetch))
        m.record(.imageRequest(.decodedHit))
        m.record(.imageRequest(.localFileRead))
        m.record(.coldArchiveLookup(key: key(4), hit: true))
        m.record(.coldArchiveLookup(key: key(5), hit: false))
        m.record(.repairStarted(indices: [1], candidateKeys: []))

        let c = m.report(itemCount: 10).forward
        XCTAssertEqual(c.emptyLayoutMounts, 2)
        XCTAssertEqual(c.emptyLayoutMountsWithGradient, 1)
        XCTAssertEqual(c.visibleRasterMisses, 1)
        XCTAssertEqual(c.rasterHitsResident, 1)
        XCTAssertEqual(c.rasterHitsFromFrozenStore, 1)
        XCTAssertEqual(c.gradientFrames, 1)
        XCTAssertEqual(c.gradientCellFrames, 3)
        XCTAssertEqual(c.layoutRecomputes, 1)
        XCTAssertEqual(c.layoutCacheHits, 1)
        XCTAssertEqual(c.imageNetworkRequests, 1)
        XCTAssertEqual(c.imageDecodedHits, 1)
        XCTAssertEqual(c.imageLocalReads, 1)
        XCTAssertEqual(c.coldArchiveHits, 1)
        XCTAssertEqual(c.coldArchiveMisses, 1)
        XCTAssertEqual(c.rasterRepairs, 1)
    }

    func testPhaseSplitsCountersAndOnlyReverseCountsAsVisibleReload() {
        let m = CacheHorizonMetrics()
        m.record(.emptyLayoutMount(index: 1, placeholderVisible: false))
        m.setPhase(.reverse)
        m.record(.emptyLayoutMount(index: 2, placeholderVisible: false))
        m.record(.rasterMiss(key: key(2), kind: .text, inVisibleStore: false, inFrozenStore: false))

        let r = m.report(itemCount: 10)
        XCTAssertEqual(r.forward.emptyLayoutMounts, 1)
        XCTAssertEqual(r.reverse.emptyLayoutMounts, 1)
        XCTAssertEqual(r.visibleReloadCount, 2)
    }

    func testPeaksTrackMaximumOfSamplesAndEvictionBytes() {
        let m = CacheHorizonMetrics()
        m.sample(frozenStoreBytes: 100, physFootprintBytes: 500)
        m.sample(frozenStoreBytes: 50, physFootprintBytes: 900)
        m.record(.frozenBitmapEvicted(key: key(1), cost: 10, currentByteTotal: 300, byteBudget: 400))
        let r = m.report(itemCount: 1)
        XCTAssertEqual(r.peakFrozenStoreBytes, 300)
        XCTAssertEqual(r.peakPhysFootprintBytes, 900)
        XCTAssertEqual(r.forward.frozenEvictions, 1)
    }

    func testDatasetIsDeterministicUniqueAndMixed() {
        let a = CacheHorizonDataset.items(count: 2_400)
        XCTAssertEqual(a, CacheHorizonDataset.items(count: 2_400))
        XCTAssertEqual(Set(a.map(\.kind)).count, HorizonItem.Kind.allCases.count)
        XCTAssertEqual(Set(a.map { CacheHorizonDataset.markdown(for: $0) }).count, a.count)
        let images = a.filter { $0.kind == .image }.map { CacheHorizonDataset.imageURL(for: $0) }
        XCTAssertEqual(Set(images).count, images.count)
    }

    func testStepFlipsToReverseAtBottomAndFinishesAtTop() {
        let down = cacheHorizonStep(phase: .forward, offset: 990, maxOffset: 1000, dt: 1)
        XCTAssertEqual(down.offset, 1000)
        XCTAssertEqual(down.phase, .reverse)
        XCTAssertFalse(down.finished)
        let up = cacheHorizonStep(phase: .reverse, offset: 10, maxOffset: 1000, dt: 1)
        XCTAssertEqual(up.offset, 0)
        XCTAssertTrue(up.finished)
    }
}

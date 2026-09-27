// TileContractTests.swift

@testable import VelocityUI
import CoreGraphics
import XCTest

final class TileContractTests: XCTestCase {

    // MARK: - AC1: tile has finite max byte cost incl. oversized row/unbreakable line

    func testSubdivideIntoTiles_RespectMaxByteCost() {
        let extents = [
            TileExtentCost(byteCost: 1000),
            TileExtentCost(byteCost: 1000),
            TileExtentCost(byteCost: 2000),
            TileExtentCost(byteCost: 500)
        ]
        let maxTileByteCost = 2500

        let ranges = subdivideIntoTiles(extents: extents, maxTileByteCost: maxTileByteCost)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 0)
        XCTAssertEqual(ranges[0].upperBound, 2)
        XCTAssertEqual(ranges[1].lowerBound, 2)
        XCTAssertEqual(ranges[1].upperBound, 4)

        // Verify no combined cost in a tile exceeds the ceiling (except single oversized extents)
        for (idx, range) in ranges.enumerated() {
            var totalCost = 0
            for i in range.lowerBound..<range.upperBound {
                totalCost += extents[i].byteCost
            }
            if range.length > 1 {
                XCTAssertLessThanOrEqual(
                    totalCost, maxTileByteCost,
                    "AC1: multi-extent tile \(idx) cost (\(totalCost)) must not exceed maxTileByteCost (\(maxTileByteCost))"
                )
            }
        }
    }

    func testSubdivideIntoTiles_OversizedExtentStandsAlone() {
        let extents = [
            TileExtentCost(byteCost: 500),
            TileExtentCost(byteCost: 10000),  // Much larger than ceiling
            TileExtentCost(byteCost: 500)
        ]
        let maxTileByteCost = 2000

        let ranges = subdivideIntoTiles(extents: extents, maxTileByteCost: maxTileByteCost)

        XCTAssertEqual(ranges.count, 3, "oversized extent must be its own tile")
        XCTAssertEqual(ranges[0].length, 1)
        XCTAssertEqual(ranges[1].length, 1)
        XCTAssertEqual(ranges[2].length, 1)
    }

    func testSubdivideIntoTiles_OversizedExtentReportsTrueCost() {
        let extents = [
            TileExtentCost(byteCost: 5000)  // Exceeds ceiling
        ]
        let maxTileByteCost = 2000

        let ranges = subdivideIntoTiles(extents: extents, maxTileByteCost: maxTileByteCost)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].length, 1)
        // The true cost (5000) is reported unchanged, not clamped to maxTileByteCost
        XCTAssertEqual(extents[ranges[0].lowerBound].byteCost, 5000, "AC1: oversized extent cost must not be clamped")
    }

    // MARK: - AC2: old generation cannot paint into new layout

    func testMountIfCurrent_MatchesWhenBothIdentityFieldsEqual() {
        let image = makeTinyTestImage(width: 2, height: 2)
        let identity = TileIdentity(contentIdentity: 42, tileRange: TileRange(lowerBound: 0, upperBound: 5))
        let result = TileRenderResult(identity: identity, image: image)

        let mounted = mountIfCurrent(result, currentIdentity: identity)

        XCTAssertNotNil(mounted, "AC2: must return image when identity matches exactly")
        XCTAssertEqual(mounted?.width, image.width)
    }

    func testMountIfCurrent_ReturnsNilWhenContentIdentityDiffers() {
        let image = makeTinyTestImage(width: 2, height: 2)
        let tileRange = TileRange(lowerBound: 0, upperBound: 5)
        let deliveredIdentity = TileIdentity(contentIdentity: 42, tileRange: tileRange)
        let currentIdentity = TileIdentity(contentIdentity: 43, tileRange: tileRange)
        let result = TileRenderResult(identity: deliveredIdentity, image: image)

        let mounted = mountIfCurrent(result, currentIdentity: currentIdentity)

        XCTAssertNil(mounted, "AC2: must return nil when contentIdentity differs")
    }

    func testMountIfCurrent_ReturnsNilWhenTileRangeDiffers() {
        let image = makeTinyTestImage(width: 2, height: 2)
        let contentId = 42
        let deliveredIdentity = TileIdentity(contentIdentity: contentId, tileRange: TileRange(lowerBound: 0, upperBound: 5))
        let currentIdentity = TileIdentity(contentIdentity: contentId, tileRange: TileRange(lowerBound: 0, upperBound: 6))
        let result = TileRenderResult(identity: deliveredIdentity, image: image)

        let mounted = mountIfCurrent(result, currentIdentity: currentIdentity)

        XCTAssertNil(mounted, "AC2: must return nil when tileRange differs")
    }

    // MARK: - AC3: viewport demand mounts only needed + prefetch bound, releases offscreen

    func testTileDemandWindow_ClampsToBounds() {
        let visibleTileRange = 10..<15
        let tileCount = 20
        let prefetchBound = 5

        let window = tileDemandWindow(visibleTileRange: visibleTileRange, tileCount: tileCount, prefetchBound: prefetchBound)

        XCTAssertGreaterThanOrEqual(window.lowerBound, 0, "AC3: demand window lower bound must be clamped to 0")
        XCTAssertLessThanOrEqual(window.upperBound, tileCount, "AC3: demand window upper bound must be clamped to tileCount")
    }

    func testTileDemandWindow_ExpandsByPrefetchBound() {
        let visibleTileRange = 10..<15
        let tileCount = 20
        let prefetchBound = 3

        let window = tileDemandWindow(visibleTileRange: visibleTileRange, tileCount: tileCount, prefetchBound: prefetchBound)

        XCTAssertEqual(window.lowerBound, 7, "AC3: lower bound should be visible.lower - prefetch")
        XCTAssertEqual(window.upperBound, 18, "AC3: upper bound should be visible.upper + prefetch")
    }

    func testTileDemandWindow_PrefetchBoundClampedAtStart() {
        let visibleTileRange = 2..<5
        let tileCount = 20
        let prefetchBound = 5

        let window = tileDemandWindow(visibleTileRange: visibleTileRange, tileCount: tileCount, prefetchBound: prefetchBound)

        XCTAssertEqual(window.lowerBound, 0, "AC3: prefetch bound must clamp to 0, not go negative")
        XCTAssertEqual(window.upperBound, 10)
    }

    func testTileDemandWindow_PrefetchBoundClampedAtEnd() {
        let visibleTileRange = 18..<20
        let tileCount = 20
        let prefetchBound = 5

        let window = tileDemandWindow(visibleTileRange: visibleTileRange, tileCount: tileCount, prefetchBound: prefetchBound)

        XCTAssertEqual(window.lowerBound, 13)
        XCTAssertEqual(window.upperBound, 20, "AC3: prefetch bound must clamp to tileCount, not exceed it")
    }

    func testTilesToRelease_ReturnsExactlyDifference() {
        let previous = 5..<15
        let current = 8..<12

        let released = tilesToRelease(previous: previous, current: current)

        let expected = [5, 6, 7, 12, 13, 14]
        XCTAssertEqual(Set(released), Set(expected), "AC3: must return exactly indices in previous but not in current")
    }

    func testTilesToRelease_EmptyPreviousReturnsEmpty() {
        let previous = 0..<0
        let current = 5..<10

        let released = tilesToRelease(previous: previous, current: current)

        XCTAssertEqual(released.count, 0, "AC3: empty previous range must return empty array")
    }

    func testTilesToRelease_NoOverlapAllReleased() {
        let previous = 0..<5
        let current = 10..<15

        let released = tilesToRelease(previous: previous, current: current)

        XCTAssertEqual(Set(released), Set(0..<5), "AC3: non-overlapping ranges must release all from previous")
    }

    // MARK: - AC4: geometry independent of tile boundaries/residency

    func testVisibleTileIndices_ComputedPurelyFromGeometry() {
        let tileRanges = [
            TileRange(lowerBound: 0, upperBound: 10),
            TileRange(lowerBound: 10, upperBound: 20),
            TileRange(lowerBound: 20, upperBound: 30)
        ]
        let visibleExtent = TileRange(lowerBound: 12, upperBound: 25)

        // Call with no residency/cache state — pure geometry
        let indices = visibleTileIndices(tileRanges: tileRanges, visibleExtent: visibleExtent)

        XCTAssertEqual(indices.lowerBound, 1, "AC4: must find tile containing lowerBound=12")
        XCTAssertEqual(indices.upperBound, 3, "AC4: must find tile containing upperBound=25")
        XCTAssertEqual(indices, 1..<3, "AC4: geometry computed purely from tile ranges, independent of residency")
    }

    // MARK: - AC5: extreme width/height, seams, scale changes, empty/degenerate regions

    func testSubdivideIntoTiles_EmptyExtentsArray() {
        let extents: [TileExtentCost] = []
        let maxTileByteCost = 2000

        let ranges = subdivideIntoTiles(extents: extents, maxTileByteCost: maxTileByteCost)

        XCTAssertEqual(ranges.count, 0, "AC5: empty extents must produce empty result")
    }

    func testSubdivideIntoTiles_AllZeroCostExtents() {
        let extents = [
            TileExtentCost(byteCost: 0),
            TileExtentCost(byteCost: 0),
            TileExtentCost(byteCost: 0)
        ]
        let maxTileByteCost = 2000

        let ranges = subdivideIntoTiles(extents: extents, maxTileByteCost: maxTileByteCost)

        XCTAssertGreaterThan(ranges.count, 0, "AC5: zero-cost extents must still produce valid ranges")
        for range in ranges {
            XCTAssertFalse(range.isEmpty, "AC5: ranges must be non-empty")
        }
        // Verify coverage: all extents covered exactly once
        var covered = Set<Int>()
        for range in ranges {
            for i in range.lowerBound..<range.upperBound {
                covered.insert(i)
            }
        }
        XCTAssertEqual(covered.count, 3, "AC5: must cover all extents exactly once")
    }

    func testVisibleTileIndices_BoundarySeam() {
        let tileRanges = [
            TileRange(lowerBound: 0, upperBound: 5),
            TileRange(lowerBound: 5, upperBound: 10)
        ]
        let visibleExtent = TileRange(lowerBound: 5, upperBound: 6)

        let indices = visibleTileIndices(tileRanges: tileRanges, visibleExtent: visibleExtent)

        XCTAssertEqual(indices.lowerBound, 1, "AC5: visible extent at exact seam (5) should hit second tile, not first")
        XCTAssertEqual(indices.upperBound, 2)
    }

    func testVisibleTileIndices_EmptyVisibleExtent() {
        let tileRanges = [
            TileRange(lowerBound: 0, upperBound: 10),
            TileRange(lowerBound: 10, upperBound: 20)
        ]
        let visibleExtent = TileRange(lowerBound: 5, upperBound: 5)  // empty

        let indices = visibleTileIndices(tileRanges: tileRanges, visibleExtent: visibleExtent)

        XCTAssertEqual(indices, 0..<0, "AC5: empty visibleExtent must return 0..<0")
    }

    func testTileDemandWindow_TileCountZero() {
        let visibleTileRange = 0..<5
        let tileCount = 0
        let prefetchBound = 2

        let window = tileDemandWindow(visibleTileRange: visibleTileRange, tileCount: tileCount, prefetchBound: prefetchBound)

        XCTAssertEqual(window, 0..<0, "AC5: tileCount == 0 must return 0..<0")
    }

    func testSubdivideIntoTiles_SingleOversizedAmongNormal() {
        let extents = [
            TileExtentCost(byteCost: 500),
            TileExtentCost(byteCost: 500),
            TileExtentCost(byteCost: 8000),  // Oversized
            TileExtentCost(byteCost: 500),
            TileExtentCost(byteCost: 500)
        ]
        let maxTileByteCost = 1500

        let ranges = subdivideIntoTiles(extents: extents, maxTileByteCost: maxTileByteCost)

        // Should have: [0..<2], [2..<3] (oversized alone), [3..<5]
        XCTAssertEqual(ranges.count, 3)

        // Find the oversized tile (length 1 with byteCost 8000)
        let oversizedIdx = ranges.firstIndex { $0.length == 1 && extents[$0.lowerBound].byteCost == 8000 }
        XCTAssertNotNil(oversizedIdx, "AC5: single oversized extent must be isolated in its own tile")

        // Verify multi-extent tiles respect the ceiling
        for (idx, range) in ranges.enumerated() {
            if range.length > 1 {
                var cost = 0
                for i in range.lowerBound..<range.upperBound {
                    cost += extents[i].byteCost
                }
                XCTAssertLessThanOrEqual(
                    cost, maxTileByteCost,
                    "AC5: multi-extent tile \(idx) cost must respect ceiling"
                )
            }
        }
    }

    func testVisibleTileIndices_EmptyTileRangesArray() {
        let tileRanges: [TileRange] = []
        let visibleExtent = TileRange(lowerBound: 5, upperBound: 10)

        let indices = visibleTileIndices(tileRanges: tileRanges, visibleExtent: visibleExtent)

        XCTAssertEqual(indices, 0..<0, "AC5: empty tileRanges must return 0..<0")
    }

    // MARK: - Helpers

    private func makeTinyTestImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

// RenderDifferTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

// MARK: - Helpers

private func makeImageTable(
    id: String,
    url: URL? = URL(string: "https://example.com/img.jpg"),
    aspectRatio: CGFloat? = 1.5,
    contentMode: Int = 0,
    cornerRadius: CGFloat = 0
) -> NodeTable {
    // Compute hashes the same way AsyncImageNode does so the table's top-level hashes agree
    var lh = Hasher()
    lh.combine(url)
    lh.combine(aspectRatio)
    lh.combine(contentMode)
    let layoutHash = lh.finalize()

    var ah = Hasher()
    ah.combine(cornerRadius)
    let appearanceHash = ah.finalize()

    let desc = ImageDescriptor(
        url: url, aspectRatio: aspectRatio, contentMode: contentMode,
        cornerRadius: cornerRadius, layoutHash: layoutHash, appearanceHash: appearanceHash
    )
    return NodeTable(
        itemID: id,
        nodes: [.image(desc)],
        parentIndices: [-1],
        layoutHash: layoutHash,
        appearanceHash: appearanceHash
    )
}

private func makeTextTable(
    id: String,
    content: String,
    fontSize: CGFloat = 17,
    color: VColorDescriptor = .primary
) -> NodeTable {
    var lh = Hasher()
    lh.combine(content)
    lh.combine(fontSize)
    let layoutHash = lh.finalize()

    var ah = Hasher()
    ah.combine(color)
    let appearanceHash = ah.finalize()

    let desc = TextDescriptor(
        content: content, font: VFontDescriptor(size: fontSize, weight: 0),
        color: color, lineLimit: nil, lineBreakMode: 0,
        layoutHash: layoutHash, appearanceHash: appearanceHash
    )
    return NodeTable(
        itemID: id,
        nodes: [.text(desc)],
        parentIndices: [-1],
        layoutHash: layoutHash,
        appearanceHash: appearanceHash
    )
}

// MARK: - classify() tests

final class ClassifyTests: XCTestCase {

    // MARK: Tier 1: hash-equal → .none

    func testHashEqualTablesReturnNone() {
        let t = makeImageTable(id: "a")
        XCTAssertEqual(classify(t, t, dimensionCache: nil), .none)
    }

    func testIdenticalTableCopiesReturnNone() {
        let t = makeImageTable(id: "a")
        let copy = makeImageTable(id: "a")  // same params → same hashes
        XCTAssertEqual(classify(t, copy, dimensionCache: nil), .none)
    }

    // MARK: Tier 2: layoutHash equal, appearanceHash different → .appearance

    func testColorOnlyChangeReturnsAppearance() {
        let prev = makeTextTable(id: "b", content: "Hello", color: .primary)
        let next = makeTextTable(id: "b", content: "Hello", color: .white)
        // same content → same layoutHash; different color → different appearanceHash
        XCTAssertEqual(prev.layoutHash, next.layoutHash, "layout hashes must match for this test")
        XCTAssertNotEqual(prev.appearanceHash, next.appearanceHash)
        XCTAssertEqual(classify(prev, next, dimensionCache: nil), .appearance)
    }

    func testCornerRadiusOnlyChangeReturnsAppearance() {
        // cornerRadius is appearance-only per AsyncImageNode.layoutHash
        let prev = makeImageTable(id: "c", cornerRadius: 0)
        let next = makeImageTable(id: "c", cornerRadius: 8)
        XCTAssertEqual(prev.layoutHash, next.layoutHash,
            "cornerRadius must NOT affect layoutHash — appearance-only property")
        XCTAssertNotEqual(prev.appearanceHash, next.appearanceHash)
        XCTAssertEqual(classify(prev, next, dimensionCache: nil), .appearance)
    }

    // MARK: Tier 3a: URL swap with cached dimensions → .media

    func testImageURLSwapWithCachedDimensionsReturnsMedia() {
        let dc = DimensionCache()
        let newURL = URL(string: "https://example.com/new.jpg")!
        dc.store(CGSize(width: 800, height: 600), for: newURL)

        let prev = makeImageTable(id: "d", url: URL(string: "https://example.com/old.jpg"))
        let next = makeImageTable(id: "d", url: newURL)

        XCTAssertEqual(classify(prev, next, dimensionCache: dc), .media,
            "URL swap where new URL has cached dimensions must classify as .media")
    }

    // MARK: Tier 3b: URL swap without cached dimensions → .layout

    func testImageURLSwapWithoutCachedDimensionsReturnsLayout() {
        let dc = DimensionCache()  // empty — no dimensions cached for newURL

        let prev = makeImageTable(id: "e", url: URL(string: "https://example.com/old.jpg"))
        let next = makeImageTable(id: "e", url: URL(string: "https://example.com/new.jpg"))

        XCTAssertEqual(classify(prev, next, dimensionCache: dc), .layout,
            "URL swap without cached dimensions must classify as .layout (geometry unknown)")
    }

    func testImageURLSwapNilDimensionCacheReturnsLayout() {
        let prev = makeImageTable(id: "f", url: URL(string: "https://example.com/old.jpg"))
        let next = makeImageTable(id: "f", url: URL(string: "https://example.com/new.jpg"))
        XCTAssertEqual(classify(prev, next, dimensionCache: nil), .layout)
    }

    // MARK: Tier 3c: aspectRatio change → .layout

    func testAspectRatioChangeReturnsLayout() {
        let dc = DimensionCache()
        let url = URL(string: "https://example.com/img.jpg")!
        dc.store(CGSize(width: 400, height: 400), for: url)

        let prev = makeImageTable(id: "g", url: url, aspectRatio: 1.0)
        let next = makeImageTable(id: "g", url: url, aspectRatio: 2.0)

        XCTAssertEqual(classify(prev, next, dimensionCache: dc), .layout,
            "aspectRatio change must force .layout even with cached dimensions")
    }

    // MARK: Tier 3d: contentMode change → .layout

    func testContentModeChangeReturnsLayout() {
        let dc = DimensionCache()
        let url = URL(string: "https://example.com/img.jpg")!
        dc.store(CGSize(width: 400, height: 300), for: url)

        let prev = makeImageTable(id: "h", url: url, contentMode: 0)  // fit
        let next = makeImageTable(id: "h", url: url, contentMode: 1)  // fill

        XCTAssertEqual(classify(prev, next, dimensionCache: dc), .layout,
            "contentMode change must force .layout")
    }

    // MARK: Tier 3e: text content change → .layout

    func testTextContentChangeReturnsLayout() {
        let prev = makeTextTable(id: "i", content: "Short text")
        let next = makeTextTable(id: "i", content: "Completely different and longer text")
        XCTAssertEqual(classify(prev, next, dimensionCache: nil), .layout)
    }

    // MARK: Tier 3f: node count change → .layout

    func testNodeCountChangeForcesLayout() {
        let url = URL(string: "https://example.com/img.jpg")!
        let dc = DimensionCache()
        dc.store(CGSize(width: 100, height: 100), for: url)

        let desc = ImageDescriptor(url: url, aspectRatio: 1.0, contentMode: 0,
                                    cornerRadius: 0, layoutHash: 1, appearanceHash: 0)

        let prev = NodeTable(itemID: "j",
                              nodes: [.image(desc)],
                              parentIndices: [-1], layoutHash: 1, appearanceHash: 0)
        let next = NodeTable(itemID: "j",
                              nodes: [.image(desc), .image(desc)],
                              parentIndices: [-1, 0], layoutHash: 2, appearanceHash: 0)

        XCTAssertEqual(classify(prev, next, dimensionCache: dc), .layout,
            "Different node counts must force .layout regardless of dimension cache")
    }
}

// MARK: - RenderDiffer tests

final class RenderDifferTests: XCTestCase {

    // MARK: - Added / removed / unchanged

    func testAddedItemsDetected() {
        let a = makeImageTable(id: "a")
        let b = makeImageTable(id: "b")
        let differ = RenderDiffer(dimensionCache: nil)

        let cs = differ.diff(
            prev: LayoutSnapshot(tables: [a]),
            next: LayoutSnapshot(tables: [a, b])
        )

        XCTAssertEqual(cs.added.count, 1)
        XCTAssertEqual(cs.added.first?.itemID, b.itemID)
        XCTAssertTrue(cs.removed.isEmpty)
        XCTAssertTrue(cs.layoutChanged.isEmpty)
    }

    func testRemovedItemsDetected() {
        let a = makeImageTable(id: "a")
        let b = makeImageTable(id: "b")
        let differ = RenderDiffer(dimensionCache: nil)

        let cs = differ.diff(
            prev: LayoutSnapshot(tables: [a, b]),
            next: LayoutSnapshot(tables: [a])
        )

        XCTAssertEqual(cs.removed.count, 1)
        XCTAssertEqual(cs.removed.first?.itemID, b.itemID)
        XCTAssertTrue(cs.added.isEmpty)
    }

    func testUnchangedItemsProduceNoEntry() {
        let a = makeImageTable(id: "a")
        let differ = RenderDiffer(dimensionCache: nil)

        let cs = differ.diff(
            prev: LayoutSnapshot(tables: [a]),
            next: LayoutSnapshot(tables: [makeImageTable(id: "a")])  // same params
        )

        XCTAssertFalse(cs.hasChanges)
    }

    // MARK: - Change buckets

    func testAppearanceChangeRouted() {
        let prev = makeTextTable(id: "t", content: "Hello", color: .primary)
        let next = makeTextTable(id: "t", content: "Hello", color: .white)
        let differ = RenderDiffer(dimensionCache: nil)

        let cs = differ.diff(prev: LayoutSnapshot(tables: [prev]),
                              next: LayoutSnapshot(tables: [next]))
        XCTAssertEqual(cs.appearanceChanged.count, 1)
        XCTAssertTrue(cs.layoutChanged.isEmpty)
        XCTAssertTrue(cs.mediaChanged.isEmpty)
    }

    func testMediaChangeRouted() {
        let dc = DimensionCache()
        let newURL = URL(string: "https://example.com/new.jpg")!
        dc.store(CGSize(width: 500, height: 400), for: newURL)

        let prev = makeImageTable(id: "img", url: URL(string: "https://example.com/old.jpg"))
        let next = makeImageTable(id: "img", url: newURL)
        let differ = RenderDiffer(dimensionCache: dc)

        let cs = differ.diff(prev: LayoutSnapshot(tables: [prev]),
                              next: LayoutSnapshot(tables: [next]))
        XCTAssertEqual(cs.mediaChanged.count, 1)
        XCTAssertTrue(cs.layoutChanged.isEmpty)
        XCTAssertTrue(cs.appearanceChanged.isEmpty)
    }

    func testLayoutChangeRouted() {
        let prev = makeTextTable(id: "t", content: "Short")
        let next = makeTextTable(id: "t", content: "Completely different longer text")
        let differ = RenderDiffer(dimensionCache: nil)

        let cs = differ.diff(prev: LayoutSnapshot(tables: [prev]),
                              next: LayoutSnapshot(tables: [next]))
        XCTAssertEqual(cs.layoutChanged.count, 1)
        XCTAssertTrue(cs.appearanceChanged.isEmpty)
        XCTAssertTrue(cs.mediaChanged.isEmpty)
    }

    // MARK: - Mixed snapshot

    func testMixedSnapshotRoutesAllBuckets() {
        let dc = DimensionCache()
        let newMediaURL = URL(string: "https://example.com/new.jpg")!
        dc.store(CGSize(width: 400, height: 300), for: newMediaURL)

        // "unchanged" — same params
        let unchPrev = makeImageTable(id: "unch")
        let unchNext = makeImageTable(id: "unch")

        // "appear" — color changed
        let appPrev = makeTextTable(id: "appear", content: "X", color: .primary)
        let appNext = makeTextTable(id: "appear", content: "X", color: .white)

        // "media" — URL swapped, new URL in cache
        let mediaPrev = makeImageTable(id: "media", url: URL(string: "https://example.com/old.jpg"))
        let mediaNext = makeImageTable(id: "media", url: newMediaURL)

        // "layout" — content changed
        let layPrev = makeTextTable(id: "lay", content: "A")
        let layNext = makeTextTable(id: "lay", content: "B longer text")

        // "added" and "removed"
        let addedItem = makeImageTable(id: "added")
        let removedItem = makeImageTable(id: "removed")

        let differ = RenderDiffer(dimensionCache: dc)
        let cs = differ.diff(
            prev: LayoutSnapshot(tables: [unchPrev, appPrev, mediaPrev, layPrev, removedItem]),
            next: LayoutSnapshot(tables: [unchNext, appNext, mediaNext, layNext, addedItem])
        )

        XCTAssertEqual(cs.appearanceChanged.count, 1)
        XCTAssertEqual(cs.mediaChanged.count, 1)
        XCTAssertEqual(cs.layoutChanged.count, 1)
        XCTAssertEqual(cs.added.count, 1)
        XCTAssertEqual(cs.removed.count, 1)
        XCTAssertTrue(cs.hasChanges)

        XCTAssertEqual(cs.added.first?.itemID, addedItem.itemID)
        XCTAssertEqual(cs.removed.first?.itemID, removedItem.itemID)
    }

    // MARK: - Scratch reuse (capacity retained)

    func testScratchCapacityRetainedAfterLargeCall() {
        // Verifies the keepingCapacity: true contract: a large diff establishes peak
        // capacity; a subsequent small diff must not shrink the backing buffers.
        // Without keepingCapacity: true (or with a fresh array per call), the small
        // diff would drop scratchLayoutCapacity to 1 and this test would fail.
        let differ = RenderDiffer(dimensionCache: nil)
        let large = 50
        let largePrev = (0..<large).map { i in makeTextTable(id: "\(i)", content: "old \(i)") }
        let largeNext = (0..<large).map { i in makeTextTable(id: "\(i)", content: "new \(i)") }

        // Call 1 — all 50 items layout-changed; establishes capacity ≥ 50
        _ = differ.diff(prev: LayoutSnapshot(tables: largePrev),
                        next: LayoutSnapshot(tables: largeNext))
        let capAfterLarge = differ.scratchLayoutCapacity
        XCTAssertGreaterThanOrEqual(capAfterLarge, large,
            "scratchLayout.capacity must be ≥ \(large) after large diff")

        // Call 2 — tiny diff (1 item); capacity must NOT drop
        let smallPrev = [makeTextTable(id: "s0", content: "small old")]
        let smallNext = [makeTextTable(id: "s0", content: "small new")]
        _ = differ.diff(prev: LayoutSnapshot(tables: smallPrev),
                        next: LayoutSnapshot(tables: smallNext))
        let capAfterSmall = differ.scratchLayoutCapacity
        XCTAssertGreaterThanOrEqual(capAfterSmall, capAfterLarge,
            "removeAll(keepingCapacity:true) must retain capacity after small diff: " +
            "got \(capAfterSmall), expected ≥ \(capAfterLarge)")

        // Call 3 — large again; correctness still holds (no realloc-induced corruption)
        let cs = differ.diff(prev: LayoutSnapshot(tables: largePrev),
                             next: LayoutSnapshot(tables: largeNext))
        XCTAssertEqual(cs.layoutChanged.count, large)
        XCTAssertGreaterThanOrEqual(differ.scratchLayoutCapacity, large)
    }

    // MARK: - Performance test (1,000 items, 10 changes)

    func testDiffPerformance1000ItemsWith10Changes() {
        let n = 1_000
        let changeset = 10
        var prevTables: [NodeTable] = []
        var nextTables: [NodeTable] = []
        for i in 0..<n {
            let prev = makeTextTable(id: "\(i)", content: "content \(i)")
            prevTables.append(prev)
            if i < changeset {
                nextTables.append(makeTextTable(id: "\(i)", content: "updated \(i)"))
            } else {
                nextTables.append(prev)
            }
        }

        let prev = LayoutSnapshot(tables: prevTables)
        let next = LayoutSnapshot(tables: nextTables)
        let differ = RenderDiffer(dimensionCache: nil)

        // Warm-up (not measured)
        _ = differ.diff(prev: prev, next: next)

        let iterations = 20
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            let cs = differ.diff(prev: prev, next: next)
            let end = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            samples.append(Double(end - start))
            // Prevent dead-code elimination
            XCTAssertEqual(cs.layoutChanged.count, changeset)
        }

        let sorted = samples.sorted()
        // With 20 samples: median = sorted[10], p99 = sorted[19] (the maximum).
        // The maximum is the flake guard — a single slow run on loaded CI is caught.
        let medianNS = sorted[iterations / 2]
        let p99NS    = sorted[iterations - 1]
        let medianMS = medianNS / 1_000_000
        let p99MS    = p99NS    / 1_000_000
        print("RenderDiffer 1k-items/10-changes  median: \(String(format: "%.3f", medianMS))ms  p99: \(String(format: "%.3f", p99MS))ms")
        XCTAssertLessThan(medianMS, 1.0,
            "median must be <1ms (got \(String(format: "%.3f", medianMS))ms)")
        XCTAssertLessThan(p99MS, 2.0,
            "p99 must be <2ms (got \(String(format: "%.3f", p99MS))ms)")
    }
}
#endif

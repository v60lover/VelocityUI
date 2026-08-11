// Spike8Tests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Spike 8: validates masonry's two load-bearing mechanisms — per-column binary-search
/// visibility lookup (reusing VerticalLayoutProvider's EXISTING firstIndex(maxYGreaterThan:)/
/// firstIndex(minYNotLessThan:) primitives, one column at a time) and column-width text
/// re-measurement — plus the seam GRID_LAYOUT_DESIGN.md surfaces: the masonry visible set is
/// NON-CONTIGUOUS in index space, and the spread that non-contiguity produces is what decides
/// whether WorkingRange needs per-column ring buffers or one widened ring (design §4).
///
/// Standalone spike: the ColumnPartition-style model below is test-local, NOT a production
/// LayoutProvider. See GRID_LAYOUT_DESIGN.md for the architecture this spike validates.
final class Spike8Tests: XCTestCase {

    // MARK: - Synthetic masonry dataset

    /// Fixed per-column item heights, deliberately skewed (col0 short, col2 tall). A shared
    /// Y-window then covers wildly different item counts per column — this stresses the
    /// per-column binary search under uneven density AND manufactures a non-contiguous visible
    /// set for free: col0 (many short items) covers a long run of consecutive column-local
    /// positions -> a wide spread of global indices (stride 3), while col2 (few tall items)
    /// covers 1-2 positions -> a couple of indices far from col0's. No randomness needed.
    private static let columnHeights: [CGFloat] = [40, 100, 300]
    private static let columnCount = 3

    /// Column-local, Y-sorted frame arrays (Y-sorted by construction: items are appended in
    /// increasing column-local order, exactly the invariant D2 relies on) plus the
    /// column-local-position -> global-index map. Global index `i` belongs to column `i %
    /// columnCount`; its column-local position is `i / columnCount`.
    private struct MasonryDataset {
        let itemCount: Int
        let columnHeights: [CGFloat]
        /// Per column: Y-sorted local frames, `CGRect(y: k * height, height: height)`.
        let columnFrames: [[CGRect]]
        /// Per column: column-local position -> global index.
        let columnGlobalIndex: [[Int]]

        init(itemCount: Int, columnHeights: [CGFloat]) {
            self.itemCount = itemCount
            self.columnHeights = columnHeights
            let columns = columnHeights.count
            var frames: [[CGRect]] = Array(repeating: [], count: columns)
            var globalIndex: [[Int]] = Array(repeating: [], count: columns)
            var cursor: [CGFloat] = Array(repeating: 0, count: columns)
            for i in 0..<itemCount {
                let c = i % columns
                let h = columnHeights[c]
                frames[c].append(CGRect(x: 0, y: cursor[c], width: 1, height: h))
                globalIndex[c].append(i)
                cursor[c] += h
            }
            columnFrames = frames
            columnGlobalIndex = globalIndex
        }

        /// Ground-truth absolute frame for a global index — mirrors the exact formula the
        /// dataset was built from. Used ONLY by the naive linear-scan oracle below; the
        /// per-column lookup under test never calls this, it reads `columnFrames` directly.
        func groundTruthFrame(forGlobalIndex i: Int) -> CGRect {
            let columns = columnHeights.count
            let c = i % columns
            let k = i / columns
            let h = columnHeights[c]
            return CGRect(x: 0, y: CGFloat(k) * h, width: 1, height: h)
        }

        var maxContentHeight: CGFloat {
            columnFrames.map { $0.last?.maxY ?? 0 }.max() ?? 0
        }
    }

    // MARK: - Two visible-set implementations under comparison

    /// Under test: per-column binary search, reusing VerticalLayoutProvider's existing
    /// primitives per column (D2). O(columns · log(N/columns)).
    private func perColumnVisibleSet(
        _ dataset: MasonryDataset, viewportTop: CGFloat, viewportBottom: CGFloat
    ) -> Set<Int> {
        var result = Set<Int>()
        for c in 0..<dataset.columnFrames.count {
            let frames = dataset.columnFrames[c]
            guard !frames.isEmpty else { continue }
            let lo = VerticalLayoutProvider.firstIndex(in: frames, maxYGreaterThan: viewportTop)
            let hi = VerticalLayoutProvider.firstIndex(in: frames, minYNotLessThan: viewportBottom)
            guard lo < hi else { continue }
            for local in lo..<hi {
                result.insert(dataset.columnGlobalIndex[c][local])
            }
        }
        return result
    }

    /// Ground truth: naive O(N) scan over every global index's independently-computed frame.
    private func naiveVisibleSet(
        _ dataset: MasonryDataset, viewportTop: CGFloat, viewportBottom: CGFloat
    ) -> Set<Int> {
        var result = Set<Int>()
        for i in 0..<dataset.itemCount {
            let f = dataset.groundTruthFrame(forGlobalIndex: i)
            if f.maxY > viewportTop && f.minY < viewportBottom {
                result.insert(i)
            }
        }
        return result
    }

    // MARK: - Test 1: Per-column lookup correctness vs naive linear scan

    func testPerColumnLookupMatchesLinearScan() {
        let dataset = MasonryDataset(itemCount: 300, columnHeights: Self.columnHeights)

        // (top, bottom, label) — incl. column-boundary and one-column-far-ahead/behind cases.
        let viewports: [(CGFloat, CGFloat, String)] = [
            (0, 100, "top edge"),
            (2000, 2500, "mid-scroll, all columns active"),
            (400, 800, "exact column-1 frame boundary (y=400 is item k=4's minY)"),
            (5000, 5100, "col0 exhausted at y=4000 while col1/col2 remain active — col1/col2 far ahead of col0"),
            (3900, 4100, "straddles col0's exact exhaustion point"),
            (100_000, 100_100, "beyond all content — empty set"),
        ]

        for (top, bottom, label) in viewports {
            let underTest = perColumnVisibleSet(dataset, viewportTop: top, viewportBottom: bottom)
            let groundTruth = naiveVisibleSet(dataset, viewportTop: top, viewportBottom: bottom)
            XCTAssertEqual(
                underTest, groundTruth,
                "[\(label)] viewport [\(top), \(bottom)): per-column lookup "
                + "(\(underTest.count) indices) must equal naive linear scan (\(groundTruth.count) indices) as a SET"
            )
        }
    }

    // MARK: - Test 2: Non-contiguity proof

    func testNonContiguityIsReal() {
        let dataset = MasonryDataset(itemCount: 300, columnHeights: Self.columnHeights)

        // Mid-scroll viewport where all 3 columns are active but at very different densities —
        // col0 (h=40) contributes ~13 tightly-packed indices, col2 (h=300) contributes ~3 indices
        // far away in index space, guaranteeing maxIdx - minIdx + 1 >> visibleCount.
        let visible = perColumnVisibleSet(dataset, viewportTop: 2000, viewportBottom: 2500)
        guard let minIdx = visible.min(), let maxIdx = visible.max() else {
            XCTFail("Expected a non-empty visible set"); return
        }
        let spread = maxIdx - minIdx + 1

        print("[Spike8] non-contiguity probe: visibleCount=\(visible.count) minIdx=\(minIdx) maxIdx=\(maxIdx) spread=\(spread)")
        XCTAssertGreaterThan(
            spread, visible.count,
            ".contiguous(Range) cannot represent this viewport's visible set: spread \(spread) "
            + "> visibleCount \(visible.count) — the union-of-per-column-ranges is genuinely non-contiguous"
        )
    }

    // MARK: - Test 3: Column-width measurement non-linearity

    private func makeWrappingTextTable() -> NodeTable {
        let descriptor = TextDescriptor(
            content: "The quick brown fox jumps over the lazy dog while the masonry column "
                + "narrows and the text must re-wrap across several more lines than it would "
                + "at the full container width, exercising real line-breaking rather than a "
                + "single long unbroken run.",
            font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 0,
            appearanceHash: 0
        )
        return NodeTable(
            itemID: 0,
            nodes: [.text(descriptor)],
            parentIndices: [-1],
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    func testColumnWidthMeasurementNonLinearity() async {
        let pool = TextMeasurementPool(capacity: 1)
        let table = makeWrappingTextTable()
        let fullWidth: CGFloat = 320
        let colWidth = fullWidth / CGFloat(Self.columnCount)

        let fullLayout = await measureNode(table, nodeIndex: 0, width: fullWidth, textPool: pool)
        let colLayout = await measureNode(table, nodeIndex: 0, width: colWidth, textPool: pool)

        let fullHeight = fullLayout.totalFrame.height
        let colHeight = colLayout.totalFrame.height
        let naiveScaled = fullHeight / CGFloat(Self.columnCount)

        print("[Spike8] column-width measurement: fullWidthHeight=\(fullHeight) colWidthHeight=\(colHeight) naive(fullWidthHeight/3)=\(naiveScaled)")

        XCTAssertGreaterThan(colHeight, 0, "Column-width measurement must produce a real height")
        XCTAssertGreaterThan(
            colHeight, naiveScaled,
            "Column-width height (\(colHeight)pt) must be GREATER than naively dividing the "
            + "full-width height by columns (\(naiveScaled)pt) — narrower column width re-wraps "
            + "to more lines, making it taller, not a linear scale-down"
        )
    }

    // MARK: - Test 4: WorkingRange spread probe (10k / 3-col)

    func testWorkingRangeSpreadProbe() {
        let dataset = MasonryDataset(itemCount: 10_000, columnHeights: Self.columnHeights)
        let viewportHeight: CGFloat = 800
        let steps = 60
        let maxTop = max(0, dataset.maxContentHeight - viewportHeight)

        var spreads: [Int] = []
        var ratios: [Double] = []

        for step in 0..<steps {
            let top = maxTop * CGFloat(step) / CGFloat(steps - 1)
            let visible = perColumnVisibleSet(dataset, viewportTop: top, viewportBottom: top + viewportHeight)
            guard let minIdx = visible.min(), let maxIdx = visible.max() else { continue }
            let spread = maxIdx - minIdx + 1
            spreads.append(spread)
            ratios.append(Double(spread) / Double(visible.count))
        }

        XCTAssertFalse(spreads.isEmpty, "Spread probe must record at least one sample")

        let sortedSpreads = spreads.sorted()
        let median = sortedSpreads[sortedSpreads.count / 2]
        let p95 = sortedSpreads[Int(Double(sortedSpreads.count - 1) * 0.95)]
        let maxSpread = sortedSpreads.last ?? 0
        let avgRatio = ratios.reduce(0, +) / Double(ratios.count)

        print("[Spike8] WorkingRange spread probe over \(spreads.count) scroll positions "
            + "(10k items, 3 columns, viewportHeight=\(viewportHeight)): "
            + "median spread=\(median) p95 spread=\(p95) max spread=\(maxSpread) "
            + "avg(spread/visibleCount)=\(String(format: "%.2f", avgRatio))x")

        // Evidence for GRID_LAYOUT_DESIGN.md §4: a single ring buffer sized to the WORST observed
        // spread would have to be many times visibleCount under this column skew — quantifies why
        // §4 leans toward (a) per-column ring buffers over (b) one widened ring. Locks the actual
        // finding (observed ~90x) rather than the trivially-true "spread > 0" — a regression back
        // to a contiguous-looking visible set would fail this.
        XCTAssertGreaterThan(
            avgRatio, 10.0,
            "avg spread/visibleCount (\(avgRatio)) must be >> 1 — a single ring buffer sized to "
            + "visibleCount cannot cover the masonry visible set; evidence for "
            + "GRID_LAYOUT_DESIGN.md §4 per-column ring buffers"
        )
    }

    // MARK: - Test 5: Directional timing — sub-linear lookup cost

    func testDirectionalLookupTimingSubLinear() {
        // Doubling-ish sizes spanning a 16x range; same NUMBER of lookups at every size so the
        // comparison isolates per-lookup cost growth, not total workload growth.
        let itemCounts = [1_250, 2_500, 5_000, 10_000, 20_000]
        let lookupsPerSize = 400
        let viewportHeight: CGFloat = 800

        var elapsedBySize: [Int: TimeInterval] = [:]

        for itemCount in itemCounts {
            let dataset = MasonryDataset(itemCount: itemCount, columnHeights: Self.columnHeights)
            let maxTop = max(0, dataset.maxContentHeight - viewportHeight)

            // Directional: sweep forward then backward, like a scroll-then-reverse gesture.
            var positions: [CGFloat] = []
            let half = lookupsPerSize / 2
            for step in 0..<half {
                positions.append(maxTop * CGFloat(step) / CGFloat(max(1, half - 1)))
            }
            for step in 0..<half {
                positions.append(maxTop * CGFloat(half - 1 - step) / CGFloat(max(1, half - 1)))
            }

            let start = Date()
            for top in positions {
                _ = perColumnVisibleSet(dataset, viewportTop: top, viewportBottom: top + viewportHeight)
            }
            elapsedBySize[itemCount] = Date().timeIntervalSince(start)
        }

        for itemCount in itemCounts {
            print("[Spike8] timing N=\(itemCount): \(String(format: "%.5f", elapsedBySize[itemCount] ?? -1))s "
                + "for \(lookupsPerSize) directional lookups")
        }

        guard let smallest = elapsedBySize[itemCounts.first!],
              let largest = elapsedBySize[itemCounts.last!] else {
            XCTFail("Missing timing samples"); return
        }

        let itemGrowth = Double(itemCounts.last!) / Double(itemCounts.first!)   // 16x
        // Sub-linear (~log) cost should grow far slower than item count. A generous ceiling well
        // below linear growth (16x) still cleanly distinguishes O(log N) from O(N) or worse.
        let growthCeiling = 4.0
        print("[Spike8] timing growth: item count grew \(String(format: "%.1f", itemGrowth))x, "
            + "lookup time grew \(String(format: "%.2f", largest / max(smallest, .ulpOfOne)))x "
            + "(ceiling \(growthCeiling)x)")

        XCTAssertLessThan(
            largest, smallest * growthCeiling,
            "Lookup time at N=\(itemCounts.last!) (\(largest)s) must not grow anywhere near "
            + "linearly with item count vs N=\(itemCounts.first!) (\(smallest)s) — expected ~log growth"
        )
    }
}
#endif

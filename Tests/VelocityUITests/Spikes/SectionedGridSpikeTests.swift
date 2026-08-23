// SectionedGridSpikeTests.swift

#if canImport(UIKit)
import XCTest
import Darwin
@testable import VelocityUI

/// Spike: validates the load-bearing mechanisms behind SECTIONED_GRID_DESIGN.md's two-level
/// section lookup (§3 D1/D3/D4, §8) BEFORE the public `.sections` surface exists. Standalone
/// spike, same technique as `Spike8Tests`: test-local model types that call PRODUCTION
/// primitives directly (`VerticalLayoutProvider`, `GridLayoutProvider` and their static
/// `firstIndex`/`visibleIndexRange` helpers) — no new production types, no UIScrollView, no DSL.
///
/// Level-1 reuse insight: the section table's own binary search is structurally the same
/// operation as `VerticalLayoutProvider`'s item search — "first index whose maxY > y" / "first
/// index whose minY >= y" — just applied to section bounds instead of item bounds. So this spike
/// represents the section table AS a `[CGRect]` (one full-width rect per section) and calls
/// `VerticalLayoutProvider.firstIndex(in:...)` directly for level 1, exactly as production would
/// for level 2 — a stronger validation than reimplementing a parallel binary search test-locally.
///
/// A `HorizontalLayoutProvider` does not exist in production yet (`SHELF_LAYOUT_DESIGN.md` is
/// design-only) — `.horizontal` sections are modeled test-locally, same reason `Spike8Tests`
/// stood up test-local masonry machinery.
final class SectionedGridSpikeTests: XCTestCase {

    // MARK: - Test-local section model (mirrors SECTIONED_GRID_DESIGN.md §7 — not production types)

    private enum SpikeSectionKind {
        case vertical(VerticalLayoutProvider)
        case grid(GridLayoutProvider)
        case horizontal(fixedHeight: CGFloat)
    }

    private struct SpikeSection {
        let kind: SpikeSectionKind
        let headerHeight: CGFloat
        /// Per-item heights for `.vertical`/`.grid` sections. Synthetic (no text re-measurement
        /// at column width) — out of scope for this spike, which validates index-lookup
        /// mechanics, not measurement (that's `GRID_LAYOUT_DESIGN.md`'s §5).
        let itemHeights: [CGFloat]
        /// Card count for `.horizontal` sections only.
        let cardCount: Int

        init(kind: SpikeSectionKind, headerHeight: CGFloat, itemHeights: [CGFloat] = [], cardCount: Int = 0) {
            self.kind = kind
            self.headerHeight = headerHeight
            self.itemHeights = itemHeights
            self.cardCount = cardCount
        }

        /// Global-index footprint. A `.horizontal` (shelf) section is a FIXED single opaque slot
        /// regardless of card count — derived from D3 (one flat global index, one `WorkingRange`)
        /// + D8/§4 (shelf owns its own inner horizontal ring, gated on outer visibility): the
        /// outer feed addresses "mount the shelf here" via one anchor index, while the shelf's
        /// cards are addressed by its own separate ring. This is what makes "outer visible range
        /// unchanged when cards are appended" (bead criterion 6) consistent with "WorkingRange
        /// stays one ring" (D3) — see `testShelfAppendLeavesOuterTableUntouched`.
        var itemCount: Int {
            switch kind {
            case .horizontal: return 1
            case .vertical, .grid: return itemHeights.count
            }
        }
    }

    private struct SpikeSectionTable {
        /// Full extent per section (header + items), absolute Y, one CGRect per section.
        let sectionFrames: [CGRect]
        /// Per-section item-local frames (header offset applied, section-top NOT applied).
        let sectionItemFrames: [[CGRect]]
        let sectionKinds: [SpikeSectionKind]
        /// Global index slice owned by each section.
        let itemRanges: [Range<Int>]
        /// Per-section shelf card frames (X-local), empty for non-`.horizontal` sections. Never
        /// read by `visibleGlobalRange` — exists only to prove the outer table is decoupled from it.
        let shelfCardFrames: [[CGRect]]
        let totalItemCount: Int

        static func build(sections: [SpikeSection], availableWidth: CGFloat) -> SpikeSectionTable {
            var sectionFrames: [CGRect] = []
            var sectionItemFrames: [[CGRect]] = []
            var kinds: [SpikeSectionKind] = []
            var itemRanges: [Range<Int>] = []
            var shelfCardFrames: [[CGRect]] = []
            var cursorY: CGFloat = 0
            var globalCursor = 0

            for section in sections {
                let itemFrames: [CGRect]
                let contentHeight: CGFloat
                var cardFrames: [CGRect] = []

                switch section.kind {
                case .vertical(let provider):
                    let layouts = section.itemHeights.map {
                        ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: availableWidth, height: $0))
                    }
                    let raw = provider.frames(for: layouts, availableWidth: availableWidth)
                    itemFrames = raw.map { $0.offsetBy(dx: 0, dy: section.headerHeight) }
                    contentHeight = section.headerHeight + (raw.last?.maxY ?? 0)

                case .grid(let provider):
                    let layouts = section.itemHeights.map {
                        ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: availableWidth, height: $0))
                    }
                    let raw = provider.frames(for: layouts, availableWidth: availableWidth)
                    itemFrames = raw.map { $0.offsetBy(dx: 0, dy: section.headerHeight) }
                    contentHeight = section.headerHeight
                        + GridLayoutProvider.contentHeight(for: raw, columns: provider.columns)

                case .horizontal(let fixedHeight):
                    itemFrames = []
                    contentHeight = section.headerHeight + fixedHeight
                    var xCursor: CGFloat = 0
                    let cardWidth: CGFloat = 140
                    let cardSpacing: CGFloat = 8
                    for _ in 0..<section.cardCount {
                        cardFrames.append(CGRect(x: xCursor, y: 0, width: cardWidth, height: fixedHeight))
                        xCursor += cardWidth + cardSpacing
                    }
                }

                let sectionTop = cursorY
                sectionFrames.append(CGRect(x: 0, y: sectionTop, width: availableWidth, height: contentHeight))
                sectionItemFrames.append(itemFrames)
                kinds.append(section.kind)
                itemRanges.append(globalCursor..<(globalCursor + section.itemCount))
                shelfCardFrames.append(cardFrames)

                cursorY += contentHeight
                globalCursor += section.itemCount
            }

            return SpikeSectionTable(
                sectionFrames: sectionFrames,
                sectionItemFrames: sectionItemFrames,
                sectionKinds: kinds,
                itemRanges: itemRanges,
                shelfCardFrames: shelfCardFrames,
                totalItemCount: globalCursor
            )
        }
    }

    // MARK: - Two-level visibility (mirrors §7's proposed `visibleGlobalRange`)

    /// Level 1: binary search over `sectionFrames` via the PRODUCTION `VerticalLayoutProvider`
    /// search primitives (see class doc). Level 2: dispatch to the touched section's own
    /// provider's static visibility helper, on its local item frames, translated into
    /// section-local Y. Union across touched sections — contiguous by construction for in-scope
    /// providers (D4), since each section's own level-2 range is itself contiguous.
    private func visibleGlobalRange(
        table: SpikeSectionTable,
        viewportTop: CGFloat,
        viewportBottom: CGFloat
    ) -> Range<Int> {
        guard !table.sectionFrames.isEmpty else { return 0..<0 }

        // Positionally-correct empty-range fallback (matches level-2 providers' count..<count /
        // 0..<0 convention instead of an arbitrary sentinel), so criterion 3's byte-identical
        // claim holds for boundary viewports (before all content / past all content) too.
        func emptyRangeAt(_ boundarySection: Int) -> Range<Int> {
            let idx = boundarySection < table.itemRanges.count
                ? table.itemRanges[boundarySection].lowerBound
                : table.totalItemCount
            return idx..<idx
        }

        let firstSection = VerticalLayoutProvider.firstIndex(in: table.sectionFrames, maxYGreaterThan: viewportTop)
        let lastSectionExclusive = VerticalLayoutProvider.firstIndex(in: table.sectionFrames, minYNotLessThan: viewportBottom)
        guard firstSection < lastSectionExclusive, firstSection < table.sectionFrames.count else {
            return emptyRangeAt(firstSection)
        }

        var globalStart: Int?
        var globalEnd = 0

        for s in firstSection..<min(lastSectionExclusive, table.sectionFrames.count) {
            let sectionTop = table.sectionFrames[s].minY
            let localTop = viewportTop - sectionTop
            let localBottom = viewportBottom - sectionTop
            let localRange: Range<Int>

            switch table.sectionKinds[s] {
            case .vertical:
                let frames = table.sectionItemFrames[s]
                guard !frames.isEmpty else { continue }
                localRange = VerticalLayoutProvider.visibleIndexRange(
                    in: frames, viewportTop: localTop, viewportBottom: localBottom)
            case .grid(let provider):
                let frames = table.sectionItemFrames[s]
                guard !frames.isEmpty else { continue }
                localRange = GridLayoutProvider.visibleIndexRange(
                    in: frames, columns: provider.columns, viewportTop: localTop, viewportBottom: localBottom)
            case .horizontal:
                // Level-1 already proved Y-overlap; the shelf's single opaque slot is visible
                // whole. Inner X visibility is a separate axis (D8/§4), out of scope here.
                localRange = 0..<1
            }

            guard !localRange.isEmpty else { continue }
            let gStart = table.itemRanges[s].lowerBound + localRange.lowerBound
            let gEnd = table.itemRanges[s].lowerBound + localRange.upperBound
            if globalStart == nil { globalStart = gStart }
            globalEnd = gEnd
        }

        guard let start = globalStart else { return emptyRangeAt(firstSection) }
        return start..<globalEnd
    }

    /// Ground truth: naive O(N) scan over every section's independently-offset item frames.
    /// Grid sections are scanned ROW-granular, matching `GridLayoutProviderTests`' own
    /// `naiveRowOverlapRange` oracle: `GridLayoutProvider.visibleIndexRange` is intentionally
    /// row-granular (its doc comment: "a short item above viewportTop whose row is visible IS
    /// included"), so a per-item overlap scan is NOT an equivalent ground truth for a grid
    /// section — it would under-report items whose row overlaps but whose own frame doesn't.
    private func naiveVisibleSet(
        table: SpikeSectionTable, viewportTop: CGFloat, viewportBottom: CGFloat
    ) -> Set<Int> {
        var result = Set<Int>()
        for s in 0..<table.sectionFrames.count {
            let sectionTop = table.sectionFrames[s].minY
            let range = table.itemRanges[s]
            switch table.sectionKinds[s] {
            case .vertical:
                for (local, frame) in table.sectionItemFrames[s].enumerated() {
                    let absFrame = frame.offsetBy(dx: 0, dy: sectionTop)
                    if absFrame.maxY > viewportTop && absFrame.minY < viewportBottom {
                        result.insert(range.lowerBound + local)
                    }
                }
            case .grid(let provider):
                let frames = table.sectionItemFrames[s]
                guard !frames.isEmpty else { continue }
                let columns = provider.columns
                let rowCount = (frames.count + columns - 1) / columns
                for row in 0..<rowCount {
                    let rowStart = row * columns
                    let rowEnd = min(rowStart + columns, frames.count)
                    var rowBottom = frames[rowStart].maxY
                    for i in (rowStart + 1)..<rowEnd { rowBottom = max(rowBottom, frames[i].maxY) }
                    let rowTop = frames[rowStart].minY   // top-aligned within a row
                    let absTop = rowTop + sectionTop
                    let absBottom = rowBottom + sectionTop
                    if absBottom > viewportTop && absTop < viewportBottom {
                        for i in rowStart..<rowEnd { result.insert(range.lowerBound + i) }
                    }
                }
            case .horizontal:
                let band = table.sectionFrames[s]
                if band.maxY > viewportTop && band.minY < viewportBottom {
                    result.insert(range.lowerBound)
                }
            }
        }
        return result
    }

    /// Debug contiguity guard (mirrors D4: "the two-level search asserts contiguity in debug").
    private func isContiguous(_ indices: Set<Int>) -> Bool {
        guard let mn = indices.min(), let mx = indices.max() else { return true }
        return mx - mn + 1 == indices.count
    }

    // MARK: - Shared dataset

    /// Mixed feed: list, grid, list — uneven section heights, per bead §8.1.
    private func makeMixedDataset() -> SpikeSectionTable {
        let listHeights1: [CGFloat] = (0..<12).map { i in [40, 90, 60, 120, 50, 75][i % 6] }
        let gridHeights: [CGFloat] = (0..<30).map { i in [80, 100, 60][i % 3] }
        let listHeights2: [CGFloat] = (0..<8).map { i in [55, 95, 35, 110][i % 4] }

        let sections = [
            SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 8)), headerHeight: 44, itemHeights: listHeights1),
            SpikeSection(kind: .grid(GridLayoutProvider(columns: 3, spacing: 6)), headerHeight: 36, itemHeights: gridHeights),
            SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 8)), headerHeight: 0, itemHeights: listHeights2),
        ]
        return SpikeSectionTable.build(sections: sections, availableWidth: 320)
    }

    // MARK: - Test 1: Two-level lookup correctness vs naive linear scan

    func testTwoLevelLookupMatchesLinearScan() {
        let table = makeMixedDataset()
        let totalHeight = table.sectionFrames.last!.maxY

        var viewports: [(CGFloat, CGFloat, String)] = [
            (0, 100, "top edge, inside section-0 header+first items"),
            (table.sectionFrames[0].maxY - 10, table.sectionFrames[0].maxY + 50, "straddles section 0/1 boundary"),
            (table.sectionFrames[1].minY, table.sectionFrames[1].minY + 40, "exact start of section 1 (grid header)"),
            (table.sectionFrames[1].maxY - 20, table.sectionFrames[1].maxY + 60, "straddles section 1/2 boundary"),
            (totalHeight - 30, totalHeight + 100, "past end of content — partial + empty"),
            (100_000, 100_100, "far beyond all content — empty set"),
        ]
        // Systematic sweep with a stride that doesn't align with section/row boundaries.
        let viewportHeight: CGFloat = 250
        var top: CGFloat = -50
        while top < totalHeight + 50 {
            viewports.append((top, top + viewportHeight, "sweep top=\(top)"))
            top += 37
        }

        for (t, b, label) in viewports {
            let twoLevel = visibleGlobalRange(table: table, viewportTop: t, viewportBottom: b)
            let naive = naiveVisibleSet(table: table, viewportTop: t, viewportBottom: b)
            XCTAssertEqual(
                Set(twoLevel), naive,
                "[\(label)] viewport [\(t), \(b)) mismatch: two-level=\(Set(twoLevel).sorted()) naive=\(naive.sorted())"
            )
        }
    }

    // MARK: - Test 2: Contiguity holds; masonry guard fires

    func testContiguityHoldsAndMasonryGuardFires() {
        let table = makeMixedDataset()
        let totalHeight = table.sectionFrames.last!.maxY

        var top: CGFloat = 0
        while top < totalHeight {
            let range = visibleGlobalRange(table: table, viewportTop: top, viewportBottom: top + 250)
            if !range.isEmpty {
                XCTAssertTrue(
                    isContiguous(Set(range)),
                    "Visible set at top=\(top) must be contiguous for in-scope providers: \(Set(range).sorted())"
                )
            }
            top += 53
        }

        // Masonry-shaped scattered indices (Spike8-style: 3 columns, items interleaved out of Y
        // order) proves isContiguous is not a tautology — it must FIRE (return false) here,
        // proving the out-of-scope boundary (D4) is enforced, not silently wrong.
        let columnHeights: [CGFloat] = [40, 100, 300]
        var columnCursor: [CGFloat] = [0, 0, 0]
        var absFrames: [Int: CGRect] = [:]
        for i in 0..<60 {
            let c = i % 3
            absFrames[i] = CGRect(x: 0, y: columnCursor[c], width: 1, height: columnHeights[c])
            columnCursor[c] += columnHeights[c]
        }
        let vt: CGFloat = 2000, vb: CGFloat = 2500
        var masonrySet = Set<Int>()
        for (i, frame) in absFrames where frame.maxY > vt && frame.minY < vb {
            masonrySet.insert(i)
        }
        XCTAssertFalse(masonrySet.isEmpty, "Sanity: masonry viewport probe must hit something")
        XCTAssertFalse(
            isContiguous(masonrySet),
            "Masonry-shaped scattered indices \(masonrySet.sorted()) must trip the contiguity guard"
        )
    }

    // MARK: - Test 3: One implicit section is free

    func testSingleSectionIsByteIdenticalToVerticalProvider() {
        let heights: [CGFloat] = (0..<40).map { i in [50, 80, 65, 120, 45][i % 5] }
        let provider = VerticalLayoutProvider(spacing: 8)
        let sections = [SpikeSection(kind: .vertical(provider), headerHeight: 0, itemHeights: heights)]
        let table = SpikeSectionTable.build(sections: sections, availableWidth: 320)

        let layouts = heights.map { ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 320, height: $0)) }
        let directFrames = provider.frames(for: layouts, availableWidth: 320)

        XCTAssertEqual(
            table.sectionItemFrames[0], directFrames,
            "Single implicit section's item frames must be byte-identical to calling VerticalLayoutProvider directly"
        )
        XCTAssertEqual(
            table.sectionFrames[0],
            CGRect(x: 0, y: 0, width: 320, height: directFrames.last?.maxY ?? 0)
        )

        let totalHeight = directFrames.last?.maxY ?? 0
        var top: CGFloat = -20
        while top < totalHeight + 50 {
            let twoLevel = visibleGlobalRange(table: table, viewportTop: top, viewportBottom: top + 200)
            let direct = VerticalLayoutProvider.visibleIndexRange(in: directFrames, viewportTop: top, viewportBottom: top + 200)
            XCTAssertEqual(twoLevel, direct, "top=\(top): two-level range must equal VerticalLayoutProvider.visibleIndexRange directly")
            top += 31
        }
    }

    // MARK: - Test 4: Localized relayout

    func testLocalizedRelayout() {
        let heightsA: [CGFloat] = (0..<10).map { i in [60, 40, 90][i % 3] }
        let heightsB: [CGFloat] = (0..<10).map { i in [70, 50][i % 2] }
        let heightsC: [CGFloat] = (0..<10).map { i in [55, 85, 65][i % 3] }

        func makeSections(middleHeights: [CGFloat], lastHeights: [CGFloat]) -> [SpikeSection] {
            [
                SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 6)), headerHeight: 0, itemHeights: heightsA),
                SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 6)), headerHeight: 0, itemHeights: middleHeights),
                SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 6)), headerHeight: 0, itemHeights: lastHeights),
            ]
        }

        // --- Grow a MIDDLE-section item ---
        let before = SpikeSectionTable.build(
            sections: makeSections(middleHeights: heightsB, lastHeights: heightsC), availableWidth: 320)
        var grownB = heightsB
        grownB[3] += 200
        let after = SpikeSectionTable.build(
            sections: makeSections(middleHeights: grownB, lastHeights: heightsC), availableWidth: 320)

        XCTAssertEqual(before.sectionFrames[0], after.sectionFrames[0], "Section above the change must be byte-identical")
        XCTAssertEqual(before.sectionItemFrames[0], after.sectionItemFrames[0], "Section above the change's item frames must be byte-identical")

        XCTAssertEqual(before.sectionFrames[1].minY, after.sectionFrames[1].minY, "Changed section's own top is unaffected by its own growth")
        XCTAssertNotEqual(before.sectionItemFrames[1], after.sectionItemFrames[1], "Changed section's item frames must reflect the grown item")
        let delta = after.sectionFrames[1].height - before.sectionFrames[1].height
        XCTAssertEqual(delta, 200, accuracy: 0.001, "Section height delta must equal the item's growth")

        XCTAssertEqual(
            after.sectionFrames[2].minY - before.sectionFrames[2].minY, delta, accuracy: 0.001,
            "Section below the change (table suffix) must shift by exactly the height delta"
        )
        XCTAssertEqual(
            before.sectionItemFrames[2], after.sectionItemFrames[2],
            "Section below the change's LOCAL item frames must be untouched — only its outer top moved"
        )

        // --- Grow the LAST section: nothing outside it changes ---
        let beforeLast = SpikeSectionTable.build(
            sections: makeSections(middleHeights: heightsB, lastHeights: heightsC), availableWidth: 320)
        var grownC = heightsC
        grownC[7] += 150
        let afterLast = SpikeSectionTable.build(
            sections: makeSections(middleHeights: heightsB, lastHeights: grownC), availableWidth: 320)

        XCTAssertEqual(beforeLast.sectionFrames[0], afterLast.sectionFrames[0], "Section 0 unaffected by growing the last section")
        XCTAssertEqual(beforeLast.sectionItemFrames[0], afterLast.sectionItemFrames[0])
        XCTAssertEqual(beforeLast.sectionFrames[1], afterLast.sectionFrames[1], "Section 1 unaffected by growing the last section")
        XCTAssertEqual(beforeLast.sectionItemFrames[1], afterLast.sectionItemFrames[1])
        XCTAssertEqual(beforeLast.sectionFrames[2].minY, afterLast.sectionFrames[2].minY, "Last section's own top unaffected by its own growth")
        XCTAssertNotEqual(beforeLast.sectionItemFrames[2], afterLast.sectionItemFrames[2])
    }

    // MARK: - Test 5: Sticky header reposition — one alloc-free layer op

    /// Pure, synchronous, no `await`/`Task` — the reposition IS the sticky mechanism (D7).
    private func stickyHeaderFrame(
        sectionTop: CGFloat, headerHeight: CGFloat, sectionBottom: CGFloat, viewportTop: CGFloat, width: CGFloat
    ) -> CGRect {
        // Clamp between the header's natural position and the section's own bottom — never push
        // the header past its own section's body (D7: "while its body stays visible").
        let clampedY = min(max(sectionTop, viewportTop), sectionBottom - headerHeight)
        return CGRect(x: 0, y: clampedY, width: width, height: headerHeight)
    }

    func testStickyHeaderReposition() {
        let sectionTop: CGFloat = 500
        let headerHeight: CGFloat = 44
        let sectionBottom: CGFloat = 2000
        let width: CGFloat = 320

        let natural = stickyHeaderFrame(sectionTop: sectionTop, headerHeight: headerHeight, sectionBottom: sectionBottom, viewportTop: 300, width: width)
        XCTAssertEqual(natural.minY, sectionTop, "Header must sit at its natural position before scrolling past it")

        let clamped = stickyHeaderFrame(sectionTop: sectionTop, headerHeight: headerHeight, sectionBottom: sectionBottom, viewportTop: 900, width: width)
        XCTAssertEqual(clamped.minY, 900, "Sticky header must clamp to viewportTop once scrolled past")
        XCTAssertEqual(clamped.height, headerHeight, "Sticky reposition changes origin only, not size")

        // Alloc-free: malloc_zone_statistics before/after N reposition calls (Spike2Tests pattern).
        var before = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)

        var lastY: CGFloat = 0
        for i in 0..<10_000 {
            let vt = CGFloat(300 + (i % 700))
            let f = stickyHeaderFrame(sectionTop: sectionTop, headerHeight: headerHeight, sectionBottom: sectionBottom, viewportTop: vt, width: width)
            lastY = f.minY
        }

        var after = malloc_statistics_t()
        malloc_zone_statistics(nil, &after)
        let allocDelta = Int(after.blocks_in_use) - Int(before.blocks_in_use)

        print("[SectionedGridSpike] sticky reposition alloc delta over 10k calls: \(allocDelta) blocks, lastY=\(lastY)")
        // Threshold matches Spike2Tests: tolerates device-noise background allocation while ruling
        // out per-call allocation (would be 10,000+).
        XCTAssertLessThanOrEqual(allocDelta, 200, "Sticky header reposition must not allocate — the one-layer-op, zero-Task path (D7)")
    }

    // MARK: - Test 6: Shelf-as-section append leaves the outer table untouched

    func testShelfAppendLeavesOuterTableUntouched() {
        let listA: [CGFloat] = (0..<8).map { i in [50, 90, 60][i % 3] }
        let listB: [CGFloat] = (0..<8).map { i in [70, 40, 100][i % 3] }

        func makeSections(cardCount: Int) -> [SpikeSection] {
            [
                SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 8)), headerHeight: 0, itemHeights: listA),
                SpikeSection(kind: .horizontal(fixedHeight: 220), headerHeight: 20, cardCount: cardCount),
                SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 8)), headerHeight: 0, itemHeights: listB),
            ]
        }

        let before = SpikeSectionTable.build(sections: makeSections(cardCount: 5), availableWidth: 320)
        let after = SpikeSectionTable.build(sections: makeSections(cardCount: 50), availableWidth: 320)

        // The thing that DID change: the shelf's own inner card list.
        XCTAssertEqual(before.shelfCardFrames[1].count, 5)
        XCTAssertEqual(after.shelfCardFrames[1].count, 50)
        XCTAssertNotEqual(before.shelfCardFrames[1], after.shelfCardFrames[1])

        // The thing that must NOT change: the outer section table (D8, bead criterion 6).
        XCTAssertEqual(before.sectionFrames, after.sectionFrames, "sectionTops must be byte-identical after shelf card append (fixed height, D8)")
        XCTAssertEqual(before.itemRanges, after.itemRanges, "Global item ranges below the shelf must be unaffected by its card count")

        let viewportTop = before.sectionFrames[1].minY - 50
        let viewportBottom = before.sectionFrames[2].minY + 100
        let rangeBefore = visibleGlobalRange(table: before, viewportTop: viewportTop, viewportBottom: viewportBottom)
        let rangeAfter = visibleGlobalRange(table: after, viewportTop: viewportTop, viewportBottom: viewportBottom)
        XCTAssertEqual(rangeBefore, rangeAfter, "Outer feed's visible range must be unchanged by shelf card append")
    }

    // MARK: - Test 7: Section-search timing — sub-linear

    func testSectionSearchTimingSubLinear() {
        let sectionCounts = [8, 16, 32, 64, 128]
        let itemsPerSection = 60
        let lookupsPerSize = 300
        let viewportHeight: CGFloat = 800

        var elapsedBySize: [Int: TimeInterval] = [:]

        for sectionCount in sectionCounts {
            var sections: [SpikeSection] = []
            for s in 0..<sectionCount {
                let heights: [CGFloat] = (0..<itemsPerSection).map { i in CGFloat(40 + ((s + i) % 5) * 15) }
                sections.append(SpikeSection(kind: .vertical(VerticalLayoutProvider(spacing: 6)), headerHeight: 30, itemHeights: heights))
            }
            let table = SpikeSectionTable.build(sections: sections, availableWidth: 320)
            let totalHeight = table.sectionFrames.last!.maxY
            let maxTop = max(0, totalHeight - viewportHeight)

            // Directional: sweep forward then backward, like a scroll-then-reverse gesture.
            var positions: [CGFloat] = []
            let half = lookupsPerSize / 2
            for step in 0..<half { positions.append(maxTop * CGFloat(step) / CGFloat(max(1, half - 1))) }
            for step in 0..<half { positions.append(maxTop * CGFloat(half - 1 - step) / CGFloat(max(1, half - 1))) }

            let start = Date()
            for top in positions {
                _ = visibleGlobalRange(table: table, viewportTop: top, viewportBottom: top + viewportHeight)
            }
            elapsedBySize[sectionCount] = Date().timeIntervalSince(start)
        }

        for sectionCount in sectionCounts {
            print("[SectionedGridSpike] timing S=\(sectionCount) N=\(sectionCount * itemsPerSection): "
                + "\(String(format: "%.5f", elapsedBySize[sectionCount] ?? -1))s for \(lookupsPerSize) directional lookups")
        }

        guard let smallest = elapsedBySize[sectionCounts.first!], let largest = elapsedBySize[sectionCounts.last!] else {
            XCTFail("Missing timing samples"); return
        }

        let sizeGrowth = Double(sectionCounts.last!) / Double(sectionCounts.first!)
        let growthCeiling = 4.0
        print("[SectionedGridSpike] timing growth: size grew \(String(format: "%.1f", sizeGrowth))x, "
            + "lookup time grew \(String(format: "%.2f", largest / max(smallest, .ulpOfOne)))x (ceiling \(growthCeiling)x)")

        XCTAssertLessThan(
            largest, smallest * growthCeiling,
            "Lookup time at S=\(sectionCounts.last!) (\(largest)s) must not grow anywhere near linearly with "
            + "section/item count vs S=\(sectionCounts.first!) (\(smallest)s) — expected ~log(S)+log(n) growth"
        )
    }
}
#endif

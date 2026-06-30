// RenderPipelineTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

final class RenderPipelineTests: XCTestCase {

    // MARK: - Helpers

    private func makeImageTable(id: Int) -> NodeTable {
        NodeTable(
            itemID: id,
            nodes: [.image(ImageDescriptor(
                url: nil, aspectRatio: 1.5, contentMode: 0,
                cornerRadius: 0, layoutHash: id, appearanceHash: 0
            ))],
            parentIndices: [-1],
            layoutHash: id,
            appearanceHash: 0
        )
    }

    private func makeTables(count: Int) -> [NodeTable] {
        (0..<count).map { makeImageTable(id: $0) }
    }

    private func makePipeline(ahead: Int = 10, behind: Int = 3) -> RenderPipeline {
        RenderPipeline(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            imageActor: ImageActor(),
            prefetchAhead: ahead,
            prefetchBehind: behind
        )
    }

    // MARK: - Test 1: Cache hits skip measureNode

    func testCacheHitsSkipMeasure() async {
        let tables = makeTables(count: 20)
        let range = await WorkingRange(capacity: 60)
        let pipeline = makePipeline()
        let width: CGFloat = 320

        // First boundary: all cache misses → measures everything
        await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: width, scale: 1)
        await pipeline.waitForCurrentPrefetch()

        let hitsAfterFirst = await pipeline.cacheHitCount
        XCTAssertEqual(hitsAfterFirst, 0, "No cache hits expected on first cold pass")

        // Reset working range to force the pipeline to refetch the same indices
        await MainActor.run { range.invalidateAll() }

        // Second boundary at same index: must be treated as a new boundary.
        // Poke a different index first to reset lastLeadingIndex, then come back.
        await pipeline.onIndexBoundary(1, workingRange: range, tables: tables, availableWidth: width, scale: 1)
        await pipeline.waitForCurrentPrefetch()
        await MainActor.run { range.invalidateAll() }

        await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: width, scale: 1)
        await pipeline.waitForCurrentPrefetch()

        let hitsAfterSecond = await pipeline.cacheHitCount
        // On the third pass (index 0 after invalidate), all entries should be in LayoutCache.
        // prefetchAhead=10 means indices 0–9 should all be cache hits.
        XCTAssertGreaterThan(hitsAfterSecond, 0,
            "Expected cache hits on second pass of same indices, got \(hitsAfterSecond)")
    }

    // MARK: - Test 2: Scroll down then fling to top (scroll-up refill)

    func testScrollUpAfterDeepScrollDown() async {
        // 600 tables gives rangeEnd = min(500 + 30, 600) = 530 on the deepest boundary.
        let tables = makeTables(count: 600)
        let range = await WorkingRange(capacity: 60)
        // Large prefetch window so warmup covers plenty of items
        let pipeline = makePipeline(ahead: 30, behind: 5)
        let width: CGFloat = 320

        // Scroll down 500 items (matches bead success criterion)
        for step in stride(from: 0, through: 500, by: 10) {
            await pipeline.onIndexBoundary(step, workingRange: range, tables: tables, availableWidth: width, scale: 1)
        }
        await pipeline.waitForCurrentPrefetch()

        // Fling to top
        await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: width, scale: 1)
        await pipeline.waitForCurrentPrefetch()

        // Visible range [0, 10) must be fully populated — zero permanent blank cells
        var nilCount = 0
        for i in 0..<10 {
            let entry = await range.entry(at: i)
            if entry == nil { nilCount += 1 }
        }
        XCTAssertEqual(nilCount, 0,
            "Fling-to-top: \(nilCount) blank cells in [0, 10). resetRange + cache refill must populate the visible window.")
    }

    // MARK: - Test 3: Rapid boundary churn — only the last task commits

    func testSupersededPrefetchLeavesNoStaleCommits() async {
        let tables = makeTables(count: 200)
        let range = await WorkingRange(capacity: 60)
        let pipeline = makePipeline(ahead: 10, behind: 3)
        let width: CGFloat = 320

        // Issue 50 boundary calls in rapid succession without waiting
        for i in 0..<50 {
            await pipeline.onIndexBoundary(i, workingRange: range, tables: tables, availableWidth: width, scale: 1)
        }
        // Wait for the final task (index 49) to complete
        await pipeline.waitForCurrentPrefetch()

        // taskStartCount must equal 50 (one per distinct index)
        let starts = await pipeline.taskStartCount
        XCTAssertEqual(starts, 50, "Expected 50 task starts for 50 distinct boundary calls, got \(starts)")

        // The working range should be anchored around index 49, not 0.
        // Entries from index 0–45 (below rangeStart = 49 - 3 = 46) must not be present —
        // the advance evicted them. WorkingRange.commit's bounds guard silently drops
        // any stale commit from a superseded task.
        for i in 0..<46 {
            let entry = await range.entry(at: i)
            XCTAssertNil(entry, "Index \(i) should be evicted after advance to 46, found entry")
        }
        // Indices [46, 59) should be populated by the surviving task
        var nilCount = 0
        for i in 46..<59 {
            let entry = await range.entry(at: i)
            if entry == nil { nilCount += 1 }
        }
        XCTAssertEqual(nilCount, 0,
            "Expected [46, 59) fully populated by the last prefetch task, got \(nilCount) nils")
    }

    // MARK: - Test 4: Repeated boundary call is a no-op

    func testRepeatedBoundaryIsNoOp() async {
        let tables = makeTables(count: 20)
        let range = await WorkingRange(capacity: 60)
        let pipeline = makePipeline()

        await pipeline.onIndexBoundary(5, workingRange: range, tables: tables, availableWidth: 320, scale: 1)
        let after1 = await pipeline.taskStartCount
        XCTAssertEqual(after1, 1)

        await pipeline.onIndexBoundary(5, workingRange: range, tables: tables, availableWidth: 320, scale: 1)
        let after2 = await pipeline.taskStartCount
        XCTAssertEqual(after2, 1, "Duplicate index must not spawn a new task")
    }

    // MARK: - Test 5: markInvalidated cancels in-flight prefetch

    func testMarkInvalidatedCancelsInFlightPrefetch() async {
        // Build tables with real URLs so the image prefetch path is exercised.
        let url = URL(string: "https://example.com/img.jpg")!
        func makeURLTable(id: Int) -> NodeTable {
            NodeTable(
                itemID: id,
                nodes: [.image(ImageDescriptor(
                    url: url, aspectRatio: 1.5, contentMode: 0,
                    cornerRadius: 0, layoutHash: id, appearanceHash: 0
                ))],
                parentIndices: [-1],
                layoutHash: id,
                appearanceHash: 0
            )
        }
        let tables = (0..<5).map { makeURLTable(id: $0) }
        let range = await WorkingRange(capacity: 20)

        let imageActor = ImageActor()

        // Gate that blocks inside prefetch() — confirmed-in-prefetch semaphore lets the test
        // know that at least one prefetch subtask has entered the actor before we cancel.
        let confirmedInPrefetch = AsyncSemaphore(value: 0)
        let gate = AsyncSemaphore(value: 0)

        await imageActor.set_testPrefetchGateHook {
            await confirmedInPrefetch.signal()
            try? await gate.wait()   // suspends until gate is opened; ignores CancellationError
        }

        let pipeline = RenderPipeline(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            imageActor: imageActor,
            prefetchAhead: 10,
            prefetchBehind: 3
        )

        // Spawn prefetch in the background — it will block at the gate.
        Task {
            await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: 320, scale: 1)
        }

        // Wait until at least one prefetch subtask is inside the actor (past layout commit).
        try? await confirmedInPrefetch.wait()

        let countBefore = await pipeline.taskStartCount

        // Cancel the in-flight prefetch.
        await pipeline.markInvalidated()

        // Release the gate — subtasks resume, but the prefetchTask is already cancelled.
        await gate.signal()

        // markInvalidated() must reset lastLeadingIndex so the same index re-spawns a task.
        await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: 320, scale: 1)
        let countAfter = await pipeline.taskStartCount
        XCTAssertEqual(
            countAfter, countBefore + 1,
            "markInvalidated() must reset lastLeadingIndex; same index must spawn a fresh prefetch task"
        )
        await pipeline.waitForCurrentPrefetch()
    }

    // MARK: - Test 6: Scroll-up resetRange preserves ring buffer invariants

    func testResetRangeRestoresCapacityInvariant() async {
        let range = await WorkingRange(capacity: 10)
        let layout = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 320, height: 100))

        await MainActor.run {
            // Advance forward to index 5
            range.advance(to: 5)
            // Commit 5 entries in [5, 10)
            for i in 5..<10 {
                range.commit(layout, at: i)
            }
        }

        // Entries [5, 10) present
        for i in 5..<10 {
            let entry = await range.entry(at: i)
            XCTAssertNotNil(entry, "Index \(i) should be present before reset")
        }

        await MainActor.run {
            // Scroll up: reset to index 0
            range.resetRange(to: 0)
        }

        // All entries cleared, rangeStart = 0
        for i in 0..<10 {
            let entry = await range.entry(at: i)
            XCTAssertNil(entry, "Index \(i) should be nil after resetRange(to: 0)")
        }
        let start = await range.currentRangeStart
        XCTAssertEqual(start, 0)
    }
}
#endif

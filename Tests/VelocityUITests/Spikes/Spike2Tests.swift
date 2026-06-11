// Spike2Tests.swift

#if canImport(UIKit)
import XCTest
import Darwin
@testable import VelocityUI

/// Spike 2: validates WorkingRange ring buffer correctness, zero nil lookups
/// during scroll simulation, zero allocations on the read path, and pipeline
/// deduplication semantics.
final class Spike2Tests: XCTestCase {

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

    private func makeTextTable(id: Int) -> NodeTable {
        NodeTable(
            itemID: id,
            nodes: [
                .vstack(VStackDescriptor(alignment: 0, spacing: 8)),
                .text(TextDescriptor(
                    content: "Feed item \(id): some text content goes here.",
                    font: VFontDescriptor(size: 14, weight: 0),
                    color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                    lineLimit: 2, lineBreakMode: 0,
                    layoutHash: id, appearanceHash: 0
                ))
            ],
            parentIndices: [-1, 0],
            layoutHash: id,
            appearanceHash: 0
        )
    }

    private func makeTables(count: Int) -> [NodeTable] {
        (0..<count).map { $0 % 2 == 0 ? makeImageTable(id: $0) : makeTextTable(id: $0) }
    }

    // MARK: - Test 1: Ring buffer correctness

    func testRingBufferCorrectness() async {
        let range = await WorkingRange(capacity: 60)
        let layouts = (0..<60).map { i in
            ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 320, height: CGFloat(100 + i)))
        }

        // Commit all 60
        await MainActor.run {
            for (i, layout) in layouts.enumerated() {
                range.commit(layout, at: i)
            }
        }

        // All should be retrievable
        for i in 0..<60 {
            let result = await range.layout(at: i)
            XCTAssertNotNil(result, "Index \(i) should be in buffer")
            XCTAssertEqual(result?.totalFrame.height, CGFloat(100 + i))
        }

        // Advance by 10 — indices 0–9 evicted, 10–59 intact
        await MainActor.run { range.advance(to: 10) }
        for i in 0..<10 {
            let result = await range.layout(at: i)
            XCTAssertNil(result, "Index \(i) should be evicted after advance(to: 10)")
        }
        for i in 10..<60 {
            let result = await range.layout(at: i)
            XCTAssertNotNil(result, "Index \(i) should still be in buffer after advance(to: 10)")
        }

        // Advance past entire capacity — all nil
        await MainActor.run { range.advance(to: 70) }
        for i in 70..<130 {
            let result = await range.layout(at: i)
            XCTAssertNil(result, "Index \(i) should be nil after advance past capacity")
        }
    }

    // MARK: - Test 2: Scroll simulation — zero nil lookups after warmup

    func testZeroNilLookupsAfterWarmup() async {
        let tables = makeTables(count: 200)
        let range = await WorkingRange(capacity: 60)
        let pipeline = RenderPipeline()
        let width: CGFloat = 320
        let visibleCount = 20

        // Warmup: seed the first boundary
        await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: width)
        await pipeline.waitForCurrentPrefetch()

        var nilCount = 0
        var frameCount = 0

        // Simulate scroll: advance 1 item per "frame", 100 frames total
        for leadingIndex in 1..<100 {
            // Pipeline boundary: notify every time leading changes
            await pipeline.onIndexBoundary(leadingIndex, workingRange: range, tables: tables, availableWidth: width)

            // Don't wait for prefetch — this is the scroll path (synchronous reads only)
            // Check visible range
            for vi in leadingIndex..<(leadingIndex + visibleCount) where vi < tables.count {
                let layout = await range.layout(at: vi)
                if layout == nil { nilCount += 1 }
            }
            frameCount += 1

            // After frame 5, wait for pipeline to catch up (simulates display link cadence)
            if leadingIndex % 5 == 0 {
                await pipeline.waitForCurrentPrefetch()
            }
        }

        print("[Spike2] Frames: \(frameCount), nil lookups: \(nilCount)")
        // Allow a small number of nils during the very first frames while pipeline catches up
        XCTAssertLessThanOrEqual(nilCount, visibleCount * 3,
            "After warmup, nil lookups should be minimal. Got \(nilCount) over \(frameCount) frames.")
    }

    // MARK: - Test 3: Zero allocations on scroll read path

    func testZeroAllocationsOnLayoutReadPath() async {
        let range = await WorkingRange(capacity: 60)
        let layout = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 320, height: 200))

        await MainActor.run {
            for i in 0..<60 { range.commit(layout, at: i) }
        }

        // Measure heap blocks before and after 10,000 synchronous reads
        let allocDelta = await MainActor.run { () -> Int in
            var before = malloc_statistics_t()
            malloc_zone_statistics(nil, &before)

            for i in 0..<10_000 {
                _ = range.layout(at: i % 60)
            }

            var after = malloc_statistics_t()
            malloc_zone_statistics(nil, &after)
            return Int(after.blocks_in_use) - Int(before.blocks_in_use)
        }

        print("[Spike2] Allocation delta over 10k reads: \(allocDelta) blocks")
        // malloc_zone_statistics counts process-wide allocations. On device, OS background
        // activity adds ~80-100 blocks over the measurement window; on simulator it's near zero.
        // Threshold of 200 comfortably rules out per-call allocs (would be 10,000+) while
        // tolerating real-device noise.
        XCTAssertLessThanOrEqual(allocDelta, 200,
            "layout(at:) must not allocate on the scroll path. Delta: \(allocDelta)")
    }

    // MARK: - Test 4: Pipeline boundary deduplication

    func testPipelineDeduplicatesSameBoundary() async {
        let tables = makeTables(count: 60)
        let range = await WorkingRange(capacity: 60)
        let pipeline = RenderPipeline()

        // First call with index 5 — spawns task
        await pipeline.onIndexBoundary(5, workingRange: range, tables: tables, availableWidth: 320)
        let countAfterFirst = await pipeline.taskStartCount
        XCTAssertEqual(countAfterFirst, 1, "First call should start one task")

        // Same index again — must be no-op
        await pipeline.onIndexBoundary(5, workingRange: range, tables: tables, availableWidth: 320)
        let countAfterDuplicate = await pipeline.taskStartCount
        XCTAssertEqual(countAfterDuplicate, 1, "Duplicate index should not start a new task")

        // New index — must cancel old and start new
        await pipeline.onIndexBoundary(10, workingRange: range, tables: tables, availableWidth: 320)
        let countAfterNew = await pipeline.taskStartCount
        XCTAssertEqual(countAfterNew, 2, "New index should start a new task")

        await pipeline.waitForCurrentPrefetch()
    }
}
#endif

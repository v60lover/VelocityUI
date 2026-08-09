// RenderPipelineTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
import os
@testable import VelocityUI

// MARK: - URLProtocol helper (RenderPipelineTests-local)

/// Serves a 2×2 JPEG synchronously and counts per-URL network requests.
/// Thread-safe: all state protected by _lock.
/// Mirrors PerURLCountingProtocol in ImagePrefetchIntegrationTests — that class is
/// private to its file; this class is scoped to this test file only.
private final class PipelinePrefetchCountingProtocol: URLProtocol {
    nonisolated(unsafe) private static let _lock = OSAllocatedUnfairLock(
        initialState: [URL: Int]()
    )

    static func count(for url: URL) -> Int {
        _lock.withLock { $0[url, default: 0] }
    }
    static func reset() { _lock.withLock { $0.removeAll() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

    override func startLoading() {
        if let url = request.url {
            PipelinePrefetchCountingProtocol._lock.withLock { $0[url, default: 0] += 1 }
        }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: fmt
        ).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let resp = URLResponse(
            url: request.url!,
            mimeType: "image/jpeg",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Multi-release gate (RenderPipelineTests-local)

/// Test-only gate: `open()` releases every `wait()` call registered so far, and any
/// `wait()` call after `open()` returns immediately.
///
/// A single-release `AsyncSemaphore` is not sufficient as a gate for
/// `ImageActor._testPrefetchGateHook`: the hook fires before `inFlight` registration
/// (ImageActor.prefetch()), so concurrent prefetch() calls that share one cache key
/// (same URL/targetSize/cornerRadius/scale — as a batch of items pointing at one URL
/// does) can each independently reach the hook before any of them dedupes against the
/// others. A one-shot semaphore signal only wakes one such caller; the rest suspend on
/// `wait()` forever, since nothing signals again — an unrecoverable deadlock. This gate
/// opens for all current and future waiters at once, matching what the test actually
/// needs: "let every prefetch that reached the hook proceed."
private actor OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

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

    // MARK: - Test 5: markInvalidated resets state and re-spawn works (AC3 re-spawn half)

    /// Verifies two AC(3) properties:
    ///   (a) markInvalidated() resets lastLeadingIndex so a superseded batch's index re-triggers a new Task.
    ///   (b) The re-spawned task completes successfully and commits all items to WorkingRange.
    ///
    /// The gate hook fires inside a fire-and-forget prefetch Task — by design this is after
    /// commit (commit latency is on the measure-only path, not network). "Committed nothing for
    /// the superseded batch" is therefore not assertable here without a measure-phase gate hook;
    /// that property is covered by testSupersededPrefetchLeavesNoStaleCommits (Test 3), which
    /// exercises cancellation during the measure phase via rapid boundary churn.
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

        // Mocked session (matches the pattern used elsewhere in this file) — this test's
        // 5 tables share one URL/size/radius/scale, so multiple prefetch() calls can reach
        // the gate hook before markInvalidated()'s cancel is observed (see OneShotGate doc).
        // A real URLSession.shared fetch to this URL is an unmocked, unbounded network
        // dependency on top of that race; mocking removes it as a variable.
        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let imageActor = ImageActor(session: session, dimensionCache: DimensionCache())

        // Gate that blocks inside a spawned prefetch Task — confirmed-in-prefetch semaphore lets
        // the test know that at least one prefetch is in-flight before we cancel.
        let confirmedInPrefetch = AsyncSemaphore(value: 0)
        let gate = OneShotGate()

        await imageActor.set_testPrefetchGateHook {
            await confirmedInPrefetch.signal()
            await gate.wait()   // suspends until gate is opened
        }

        let pipeline = RenderPipeline(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            imageActor: imageActor,
            prefetchAhead: 10,
            prefetchBehind: 3
        )

        // Spawn prefetch in the background — layout commits quickly; gate blocks prefetch Task.
        Task {
            await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: 320, scale: 1)
        }

        // Wait until at least one prefetch Task is inside the actor.
        try? await confirmedInPrefetch.wait()

        let countBefore = await pipeline.taskStartCount

        // Cancel the in-flight prefetch.
        await pipeline.markInvalidated()

        // Release the gate — prefetch Task(s) resume; outer prefetchTask is already cancelled.
        await gate.open()

        // markInvalidated() must reset lastLeadingIndex so the same index re-spawns a task.
        await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: 320, scale: 1)
        let countAfter = await pipeline.taskStartCount
        XCTAssertEqual(
            countAfter, countBefore + 1,
            "markInvalidated() must reset lastLeadingIndex; same index must spawn a fresh prefetch task"
        )
        await pipeline.waitForCurrentPrefetch()

        // AC(3b): the re-spawned task must have committed all 5 items to WorkingRange.
        // (If commit happened for the old batch, this still passes — the entries are present
        // either way, which is correct. The important invariant is that the re-spawn path
        // produces a fully committed range regardless of whether the old batch committed.)
        var nilCount = 0
        for i in 0..<5 {
            let entry = await range.entry(at: i)
            if entry == nil { nilCount += 1 }
        }
        XCTAssertEqual(nilCount, 0,
            "After markInvalidated() + re-spawn, WorkingRange must have all 5 entries; \(nilCount) nil slots")
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

    // MARK: - Test 7: AC(1) — every .image fragment with a non-nil URL triggers prefetch

    /// Verifies VelocityUI-48c AC(1): after onIndexBoundary commits, every .image fragment
    /// with a non-nil URL has had imageActor.prefetch(for:…) invoked — evidenced by exactly
    /// one network request per distinct URL reaching PipelinePrefetchCountingProtocol.
    ///
    /// Synchronisation: waitForCurrentPrefetch() is the sole happens-before anchor.
    /// No Task.sleep — the prefetch withTaskGroup in RenderPipeline awaits every prefetch()
    /// call, and each prefetch() awaits its inner decode Task to completion, so the URLProtocol
    /// count is fully settled when waitForCurrentPrefetch() returns.
    func testEveryImageFragmentTriggersPrefetch() async {
        let n = 5
        let imageURLs = (0..<n).map { i in
            URL(string: "https://prefetch-ac1.example.com/\(i).jpg")!
        }

        // Wire up a URLSession whose only protocol class is the counting interceptor.
        // DimensionCache and ImageActor share the same session so all network paths are
        // observable; DimensionCache does not issue requests during the prefetch phase
        // (classify() reads synchronously from the cache, which starts empty, and never
        // calls dimensions(for:) asynchronously during measureNode).
        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let imageActor = ImageActor(session: session, dimensionCache: dc)
        await imageActor._testResetPrefetchedURLs()

        // Build N tables with distinct non-nil image URLs.
        func makeURLTable(_ id: Int, url: URL) -> NodeTable {
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

        // N tables with distinct URLs, plus one nil-URL table to confirm nil-URL
        // fragments are correctly skipped (zero network requests for that slot).
        var tables = (0..<n).map { makeURLTable($0, url: imageURLs[$0]) }
        tables.append(makeImageTable(id: n))  // url: nil — must produce no network request

        let range = await WorkingRange(capacity: 30)
        let pipeline = RenderPipeline(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            imageActor: imageActor,
            prefetchAhead: n + 5,   // covers all n+1 table indices from leading=0
            prefetchBehind: 0
        )

        await pipeline.onIndexBoundary(
            0, workingRange: range, tables: tables, availableWidth: 320, scale: 2
        )
        // waitForCurrentPrefetch() is the happens-before anchor: it awaits the prefetch
        // Task, which awaits the withTaskGroup, which awaits every actor.prefetch() call,
        // which in turn awaits its inner decode Task (including the URLSession round-trip).
        await pipeline.waitForCurrentPrefetch()

        // AC(1): each distinct image URL must have triggered exactly one network fetch.
        // "Exactly one" proves: (a) prefetch() was invoked (not zero), and (b) no duplicate
        // fetches were issued for the same fragment (not more than one).
        for (i, url) in imageURLs.enumerated() {
            XCTAssertEqual(
                PipelinePrefetchCountingProtocol.count(for: url),
                1,
                "Fragment \(i) URL \(url): expected 1 network fetch, got \(PipelinePrefetchCountingProtocol.count(for: url))"
            )
        }

        // Corroborating assertion via the actor-side prefetch hook: confirms prefetch()
        // entered the cold path (past in-flight and cache checks) for each URL.
        let prefetchedURLs = await imageActor._testGetPrefetchedURLs()
        XCTAssertEqual(
            Set(prefetchedURLs), Set(imageURLs),
            "ImageActor._testPrefetchedURLs must contain exactly the \(n) image URLs"
        )
        XCTAssertEqual(
            prefetchedURLs.count, n,
            "Each URL must enter the prefetch cold path exactly once; got \(prefetchedURLs.count) entries for \(n) URLs"
        )
    }

    // MARK: - Test 8: Mixed batch — LayoutCache hits prefetch without waiting for cold-measure sibling (VelocityUI-1su.1)

    /// Verifies AC(2) and AC(4) for bead VelocityUI-1su.1.
    ///
    /// AC(1) — structural verification: cache-hit items reach the for-await consumer before the
    /// cold-miss item (item 0 traverses 2 extra async suspension points: measureNode + cache.set).
    /// The consumer spawns prefetch Tasks in completion order, so items 1-9 dispatch before item 0.
    /// Wall-clock timestamp-delta assertions (as originally specified in AC1) require an injectable
    /// slow-measure hook (_testMeasureGateHook) that does not yet exist — deferred to Phase 6
    /// os_signpost integration. This test instead verifies correctness under a mixed-cache batch.
    ///
    /// AC(2): WorkingRange.commit fires in a single MainActor.run hop — all items committed.
    /// AC(4): each distinct URL receives exactly one network fetch regardless of mixed cache state.
    ///
    /// Setup: items 1-9 are pre-warmed in LayoutCache (cache hits); item 0 is a cold miss.
    func testMixedBatchPerItemDispatch() async {
        let n = 10
        let imageURLs = (0..<n).map { URL(string: "https://mixed-batch.example.com/\($0).jpg")! }

        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let imageActor = ImageActor(session: session, dimensionCache: dc)

        func makeURLTable(_ id: Int, url: URL) -> NodeTable {
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

        let tables = (0..<n).map { makeURLTable($0, url: imageURLs[$0]) }
        let layoutCache = LayoutCache()
        let textPool = TextMeasurementPool()
        let width: CGFloat = 320

        // Pre-warm LayoutCache for items 1-9; item 0 remains a cold miss.
        for i in 1..<n {
            let key = CacheKey(layoutHash: tables[i].layoutHash, width: width)
            let layout = await measureNode(tables[i], nodeIndex: 0, width: width, textPool: textPool)
            let fragments = extractFragments(table: tables[i], layout: layout)
            await layoutCache.set(CellEntry(layout: layout, fragments: fragments), for: key)
        }

        let range = await WorkingRange(capacity: 30)
        let pipeline = RenderPipeline(
            textPool: textPool,
            layoutCache: layoutCache,
            imageActor: imageActor,
            prefetchAhead: n + 2,
            prefetchBehind: 0
        )

        await pipeline.onIndexBoundary(0, workingRange: range, tables: tables, availableWidth: width, scale: 2)
        await pipeline.waitForCurrentPrefetch()

        // AC(4): every image URL must receive exactly one network fetch.
        for (i, url) in imageURLs.enumerated() {
            XCTAssertEqual(
                PipelinePrefetchCountingProtocol.count(for: url),
                1,
                "Mixed-batch item \(i): expected 1 network fetch, got \(PipelinePrefetchCountingProtocol.count(for: url))"
            )
        }

        // AC(2): all 10 items committed to WorkingRange in a single hop.
        var nilCount = 0
        for i in 0..<n {
            let entry = await range.entry(at: i)
            if entry == nil { nilCount += 1 }
        }
        XCTAssertEqual(nilCount, 0,
            "All \(n) items must be committed to WorkingRange; \(nilCount) nil slots remain")

        // LayoutCache hit count: items 1-9 were pre-warmed, item 0 was cold.
        let hits = await pipeline.cacheHitCount
        XCTAssertEqual(hits, n - 1,
            "Expected \(n - 1) LayoutCache hits (items 1-9 pre-warmed), got \(hits)")
    }

    // MARK: - Test 9: Generation guard bails before inner Task spawn on supersession (AC1)

    /// Verifies VelocityUI-1su.4 AC(1) for the primary generation-guard layer.
    ///
    /// Setup: all-cache-hit batch at leadingIndex 0 (prefetch Tasks dispatch quickly).
    /// Gate hook holds each prefetch at step 3 (after Task.isCancelled, before isCurrent check).
    /// While all N prefetches are suspended at the gate, a non-overlapping boundary fires,
    /// bumping the generation. Gate releases — isCurrent() returns false — all bail.
    ///
    /// Assertions:
    /// - _testPrefetchedURLs is empty (no inner Task was spawned → URL never appended)
    /// - Network count = 0 (no network fetch started for the abandoned URLs)
    func testGenerationGuardBailsBeforeInnerTaskSpawn() async {
        let n = 5
        let imageURLs = (0..<n).map { URL(string: "https://gen-guard.example.com/\($0).jpg")! }

        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let imageActor = ImageActor(session: session, dimensionCache: dc)
        await imageActor._testResetPrefetchedURLs()

        func makeURLTable(_ id: Int, url: URL) -> NodeTable {
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

        let tables = (0..<n).map { makeURLTable($0, url: imageURLs[$0]) }
        let layoutCache = LayoutCache()
        let textPool = TextMeasurementPool()
        let width: CGFloat = 320

        // Pre-warm LayoutCache: all cache hits → prefetch Tasks spawn in the for-await consumer
        // almost immediately after the group starts. This maximises the window in which a
        // superseding boundary can land while prefetches are at the gate.
        for i in 0..<n {
            let key = CacheKey(layoutHash: tables[i].layoutHash, width: width)
            let layout = await measureNode(tables[i], nodeIndex: 0, width: width, textPool: textPool)
            let fragments = extractFragments(table: tables[i], layout: layout)
            await layoutCache.set(CellEntry(layout: layout, fragments: fragments), for: key)
        }

        // Gate: suspends each prefetch Task between isCancelled check and isCurrent check.
        // confirmedAtGate is signalled once per Task that reaches the gate.
        let confirmedAtGate = AsyncSemaphore(value: 0)
        let gate = AsyncSemaphore(value: 0)
        await imageActor.set_testPrefetchGateHook {
            await confirmedAtGate.signal()
            try? await gate.wait()
        }

        let range = await WorkingRange(capacity: 30)
        let pipeline = RenderPipeline(
            textPool: textPool,
            layoutCache: layoutCache,
            imageActor: imageActor,
            prefetchAhead: n + 2,
            prefetchBehind: 0
        )

        // Large filler table for boundary 500 — non-overlapping with [0, n).
        let largeTables = tables + (n..<600).map { makeImageTable(id: $0) }

        // Fire boundary 0 in the background; layout commits quickly (all cache hits),
        // then the for-await consumer spawns n prefetch Tasks that block at the gate.
        Task {
            await pipeline.onIndexBoundary(
                0, workingRange: range, tables: tables, availableWidth: width, scale: 1
            )
        }

        // Wait until all n prefetch Tasks are suspended at the gate — deterministic anchor.
        // At this point boundary-0's prefetchTask has necessarily passed the post-taskGroup
        // guard (Task.isCancelled was false; boundary-500 hasn't fired yet), so it is in
        // `for task in spawnedPrefetches { await task.value }` awaiting the n bailing tasks.
        for _ in 0..<n { try? await confirmedAtGate.wait() }

        // Capture boundary-0's task BEFORE superseding — needed for the bail anchor below.
        let boundary0Task = await pipeline.prefetchTask

        // Supersede: new boundary at index 500 bumps the generation.
        // Deep-cancel has nothing to cancel (no inner Tasks spawned yet — all at the gate).
        await pipeline.onIndexBoundary(
            500, workingRange: range, tables: largeTables, availableWidth: width, scale: 1
        )

        // Release gate — all n prefetch Tasks resume, check isCurrent() → false → bail.
        for _ in 0..<n { await gate.signal() }

        // Anchor: boundary-0's task is awaiting the n spawned prefetch Tasks.
        // Each Task wakes, checks isCurrent() → false, returns. After all n return,
        // boundary-0's `for task in spawnedPrefetches { await task.value }` loop exits.
        // This ensures every prefetch has decided before _testPrefetchedURLs is read —
        // without this, a regressed isCurrent() could append and race the assertion.
        await boundary0Task?.value

        // Drain the boundary-500 task.
        await pipeline.waitForCurrentPrefetch()

        // AC(1): generation guard fired — no inner Task was spawned, so no URL was appended
        // to _testPrefetchedURLs and no network fetch was started.
        let prefetchedURLs = await imageActor._testGetPrefetchedURLs()
        XCTAssertTrue(
            prefetchedURLs.isEmpty,
            "Generation guard must prevent inner Task spawn: expected 0 prefetched URLs, got \(prefetchedURLs.count)"
        )

        for (i, url) in imageURLs.enumerated() {
            let count = PipelinePrefetchCountingProtocol.count(for: url)
            XCTAssertEqual(
                count, 0,
                "Generation guard: URL \(i) must have 0 network fetches after bail, got \(count)"
            )
        }
    }

    // MARK: - Test 10: Discrete-jump boundary drains without deadlock (AC1 liveness)

    /// Liveness test for VelocityUI-1su.4 AC(1) — deep cancel layer.
    ///
    /// An all-cache-hit batch at leadingIndex 0 is immediately superseded by a non-overlapping
    /// boundary at index 500. Some prefetch Tasks may have already spawned their inner decode
    /// Tasks (past step 4) before the supersession fires. The deep-cancel mechanism calls
    /// inFlight[key]?.cancel() on those Tasks. This test verifies the pipeline reaches
    /// stable completion without deadlock under rapid supersession.
    ///
    /// Property asserted: waitForCurrentPrefetch() returns (no stall).
    /// Network-level count bounds are verified by testGenerationGuardBailsBeforeInnerTaskSpawn
    /// (gate-held variant) and testEveryImageFragmentTriggersPrefetch (no-supersession baseline).
    func testDiscreteJumpBoundaryDrainsWithoutStall() async {
        let n = 5
        let imageURLs = (0..<n).map { URL(string: "https://discrete-jump.example.com/\($0).jpg")! }

        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let imageActor = ImageActor(session: session, dimensionCache: dc)

        func makeURLTable(_ id: Int, url: URL) -> NodeTable {
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

        let tables = (0..<n).map { makeURLTable($0, url: imageURLs[$0]) }
        let largeTables = tables + (n..<600).map { makeImageTable(id: $0) }
        let layoutCache = LayoutCache()
        let textPool = TextMeasurementPool()
        let width: CGFloat = 320

        // Pre-warm LayoutCache so prefetch Tasks spawn quickly after measure completes.
        for i in 0..<n {
            let key = CacheKey(layoutHash: tables[i].layoutHash, width: width)
            let layout = await measureNode(tables[i], nodeIndex: 0, width: width, textPool: textPool)
            let fragments = extractFragments(table: tables[i], layout: layout)
            await layoutCache.set(CellEntry(layout: layout, fragments: fragments), for: key)
        }

        let range = await WorkingRange(capacity: 30)
        let pipeline = RenderPipeline(
            textPool: textPool,
            layoutCache: layoutCache,
            imageActor: imageActor,
            prefetchAhead: n + 2,
            prefetchBehind: 0
        )

        // Fire boundary 0 immediately followed by boundary 500 — no coordination between them.
        // Some inner Tasks may have already spawned (deep cancel fires); others may still be
        // pending (generation guard fires). Both paths must reach stable completion.
        await pipeline.onIndexBoundary(
            0, workingRange: range, tables: tables, availableWidth: width, scale: 1
        )
        await pipeline.onIndexBoundary(
            500, workingRange: range, tables: largeTables, availableWidth: width, scale: 1
        )

        // Liveness assertion: pipeline must drain without deadlock.
        await pipeline.waitForCurrentPrefetch()
    }

    // MARK: - Test 11: Smooth-scroll overlapping range produces no duplicate fetches (AC2)

    /// Verifies VelocityUI-1su.4 AC(2): consecutive OVERLAPPING boundaries do not cause
    /// cancel-thrash or duplicate network fetches for shared URLs.
    ///
    /// Setup: N items pre-warmed. Boundary at index 0 covers [0, N). Boundary at index 1
    /// covers [0, N+1) (overlapping — shifts by 1). URLs 0..N-1 must each receive exactly
    /// one network fetch regardless of whether the second boundary's prefetch Tasks coalesce
    /// onto the first boundary's in-flight Tasks or hit the cache.
    func testSmoothScrollOverlappingRangeNoThrash() async {
        let n = 8
        let imageURLs = (0..<n).map { URL(string: "https://smooth-scroll.example.com/\($0).jpg")! }
        let extraURL = URL(string: "https://smooth-scroll.example.com/\(n).jpg")!

        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let imageActor = ImageActor(session: session, dimensionCache: dc)

        func makeURLTable(_ id: Int, url: URL) -> NodeTable {
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

        var tables = (0..<n).map { makeURLTable($0, url: imageURLs[$0]) }
        tables.append(makeURLTable(n, url: extraURL))  // index n: new item in second boundary

        let layoutCache = LayoutCache()
        let textPool = TextMeasurementPool()
        let width: CGFloat = 320

        // Pre-warm all n+1 items so both boundaries are pure cache-hit batches.
        for i in 0...n {
            let key = CacheKey(layoutHash: tables[i].layoutHash, width: width)
            let layout = await measureNode(tables[i], nodeIndex: 0, width: width, textPool: textPool)
            let fragments = extractFragments(table: tables[i], layout: layout)
            await layoutCache.set(CellEntry(layout: layout, fragments: fragments), for: key)
        }

        let range = await WorkingRange(capacity: 30)
        let pipeline = RenderPipeline(
            textPool: textPool,
            layoutCache: layoutCache,
            imageActor: imageActor,
            prefetchAhead: n + 2,
            prefetchBehind: 0
        )

        // Boundary at index 0: range [0, n+2) — covers all n+1 tables.
        await pipeline.onIndexBoundary(
            0, workingRange: range, tables: tables, availableWidth: width, scale: 1
        )
        // Immediately fire overlapping boundary at index 1: range [0, n+2) — same URLs, one
        // generation bump. Smooth-scroll invariant: shared URLs must not be re-fetched.
        await pipeline.onIndexBoundary(
            1, workingRange: range, tables: tables, availableWidth: width, scale: 1
        )
        await pipeline.waitForCurrentPrefetch()

        // AC(2): each URL must appear at most once — coalescing (inFlight or cache hit)
        // must prevent duplicate fetches regardless of timing.
        for (i, url) in imageURLs.enumerated() {
            let count = PipelinePrefetchCountingProtocol.count(for: url)
            XCTAssertLessThanOrEqual(
                count, 1,
                "Smooth-scroll no-thrash: URL \(i) must have ≤ 1 fetch, got \(count)"
            )
        }
        // cacheHitCount must be > 0: second boundary resolves at least some items from cache.
        let hits = await pipeline.cacheHitCount
        XCTAssertGreaterThan(hits, 0,
            "Second boundary must hit the LayoutCache for pre-warmed items; cacheHitCount=\(hits)")
    }

    // MARK: - Test 12: Deep cancel releases decode slot (AC1 secondary layer + bw1 hook)

    /// Verifies VelocityUI-1su.4 AC(1) deep-cancel layer and bw1 hook wiring.
    ///
    /// Three prefetches acquire decode slots and block at `_testDecodeBodyGateHook`.
    /// `cancelInFlightPrefetches` cancels all three inner Tasks — cancellation propagates
    /// into `gate.wait()` inside the hook via `withTaskCancellationHandler` in AsyncSemaphore,
    /// unblocking each task. The post-hook `guard !Task.isCancelled` in `_decode()` releases
    /// the slot. A fourth "witness" prefetch acquires a freed slot and completes, proving
    /// no slot leak under deep cancel.
    ///
    /// Assertions:
    /// - Witness URL receives ≥ 1 network fetch (slot was released; witness proceeded).
    /// - Each cancelled URL receives exactly 1 network fetch (no retry after cancel).
    func testDeepCancelReleasesDecodeSlot() async {
        // 3 cancel URLs == AsyncSemaphore(value: 3) in ImageActor.swift:102.
        // Filling all slots proves the witness must wait; change this if the semaphore cap changes.
        let cancelURLs = (0..<3).map { URL(string: "https://deep-cancel.example.com/cancel\($0).jpg")! }
        let witnessURL = URL(string: "https://deep-cancel.example.com/witness.jpg")!

        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let actor = ImageActor(session: session, dimensionCache: dc)

        // First 3 hook invocations (cancel URLs) block; 4th+ (witness) pass through immediately.
        let invocationCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let atGate = AsyncSemaphore(value: 0)
        let gate = AsyncSemaphore(value: 0)
        await actor.set_testDecodeBodyGateHook {
            let n = invocationCount.withLock { $0 += 1; return $0 }
            guard n <= 3 else { return }   // witness: pass through
            await atGate.signal()          // notify test: one decode slot is now held
            try? await gate.wait()         // hold until cancelled or explicitly signalled
        }

        let targetSize = CGSize(width: 100, height: 100)

        // Start 3 prefetches concurrently — each network-fetches (synchronous URLProtocol),
        // enters _decode(), acquires a slot, and blocks at the hook.
        for url in cancelURLs {
            let capturedURL = url
            Task { await actor.prefetch(for: capturedURL, targetSize: targetSize, cornerRadius: 0, scale: 1, priority: .ahead) }
        }

        // Deterministic anchor: wait until all 3 decode slots are held.
        for _ in 0..<3 { try? await atGate.wait() }

        // Deep cancel: inFlight[key]?.cancel() for each cancel URL.
        // Cancellation propagates into gate.wait() via AsyncSemaphore.withTaskCancellationHandler,
        // unblocking each task without an explicit gate signal.
        let specs = cancelURLs.map { PrefetchSpec(url: $0, targetSize: targetSize, cornerRadius: 0, scale: 1) }
        await actor.cancelInFlightPrefetches(specs)

        // Witness starts with 3 slots in-cancellation; blocks at decodeSemaphore.wait()
        // until a cancelled task releases its slot, then proceeds through the hook no-op path.
        let witnessTask = Task { await actor.prefetch(for: witnessURL, targetSize: targetSize, cornerRadius: 0, scale: 1, priority: .ahead) }
        await witnessTask.value

        XCTAssertGreaterThanOrEqual(
            PipelinePrefetchCountingProtocol.count(for: witnessURL), 1,
            "Witness prefetch must complete — cancelled tasks must release their decode slots"
        )
        for (i, url) in cancelURLs.enumerated() {
            XCTAssertEqual(
                PipelinePrefetchCountingProtocol.count(for: url), 1,
                "Cancelled URL \(i) must have exactly 1 network fetch — no retry after deep cancel"
            )
        }
    }

    // MARK: - Test 13: onIndexBoundary classifies prefetch priority by index vs. leadingIndex

    /// Verifies VelocityUI-he0: items at/after leadingIndex request `.ahead`; items before it
    /// request `.behind`. Uses the `_testGetPrefetchedPriorities()` seam on ImageActor to
    /// capture the per-call priority without needing a fake ImageActor threaded through
    /// RenderPipeline.
    func testPrefetchPriorityReflectsAheadBehindClassification() async {
        let n = 6
        let imageURLs = (0..<n).map { i in
            URL(string: "https://prefetch-priority.example.com/\(i).jpg")!
        }

        PipelinePrefetchCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PipelinePrefetchCountingProtocol.self]
        let session = URLSession(configuration: config)
        let dc = DimensionCache(session: session)
        let imageActor = ImageActor(session: session, dimensionCache: dc)
        await imageActor._testResetPrefetchedURLs()
        await imageActor._testResetPrefetchedPriorities()

        func makeURLTable(_ id: Int, url: URL) -> NodeTable {
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

        let tables = (0..<n).map { makeURLTable($0, url: imageURLs[$0]) }
        let range = await WorkingRange(capacity: 30)
        let leadingIndex = 3

        // ahead=n, behind=n: prefetchRange clamps to [0, n) — the full table — so every
        // index's classification is exercised in one boundary call.
        let pipeline = RenderPipeline(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            imageActor: imageActor,
            prefetchAhead: n,
            prefetchBehind: n
        )

        await pipeline.onIndexBoundary(
            leadingIndex, workingRange: range, tables: tables, availableWidth: 320, scale: 2
        )
        await pipeline.waitForCurrentPrefetch()

        let priorities = await imageActor._testGetPrefetchedPriorities()
        let byURL = Dictionary(uniqueKeysWithValues: priorities.map { ($0.url, $0.priority) })

        XCTAssertEqual(byURL.count, n, "Every image URL must have a recorded prefetch priority")

        for (i, url) in imageURLs.enumerated() {
            let expected: DecodePriority = i >= leadingIndex ? .ahead : .behind
            XCTAssertEqual(
                byURL[url], expected,
                "Table index \(i) (leadingIndex=\(leadingIndex)) must request \(expected); got \(String(describing: byURL[url]))"
            )
        }
    }
}
#endif

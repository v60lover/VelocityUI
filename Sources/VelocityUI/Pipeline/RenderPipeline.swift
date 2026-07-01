// RenderPipeline.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

/// Prefetch actor — runs off MainActor, writes back to WorkingRange via MainActor.run.
/// Called by the scroll container on leading-index boundary crossings (not every frame).
public actor RenderPipeline {
    private var lastLeadingIndex: Int = -1
    private(set) var prefetchTask: Task<Void, Never>?

    /// Incremented each time a new prefetch Task is spawned.
    /// Internal for testing only — not part of the production API.
    private(set) var taskStartCount: Int = 0

    /// Incremented each time onIndexBoundary resolves an index from LayoutCache
    /// rather than re-measuring. Internal for testing only.
    private(set) var cacheHitCount: Int = 0

    private let textPool: TextMeasurementPool
    private let layoutCache: LayoutCache
    private let imageActor: ImageActor

    private let prefetchAhead: Int
    private let prefetchBehind: Int

    public init(
        textPool: TextMeasurementPool,
        layoutCache: LayoutCache,
        imageActor: ImageActor,
        prefetchAhead: Int = 10,
        prefetchBehind: Int = 3
    ) {
        self.textPool = textPool
        self.layoutCache = layoutCache
        self.imageActor = imageActor
        self.prefetchAhead = prefetchAhead
        self.prefetchBehind = prefetchBehind
    }

    /// Test-only convenience — creates a private pool, cache, and image actor not shared with RenderEnvironment.
    /// Uses prefetchAhead = 60 to match the old hardcoded range and preserve Spike2 test thresholds.
    /// The private `ImageActor` instance's cache is isolated — do not combine with `env.imageActor` in tests expecting shared warmup.
    init() {
        self.textPool = TextMeasurementPool()
        self.layoutCache = LayoutCache()
        self.imageActor = ImageActor()
        self.prefetchAhead = 60
        self.prefetchBehind = 3
    }

    /// Notify the pipeline that the visible leading index has changed.
    /// No-op if leadingIndex hasn't changed since last call.
    /// Cancels and replaces any running prefetch task.
    ///
    /// - Parameters:
    ///   - leadingIndex:   First visible item index at the time of the boundary crossing.
    ///   - workingRange:   Ring buffer shared with the scroll container (MainActor-isolated).
    ///   - tables:         NodeTables in display order, parallel to the item array.
    ///   - availableWidth: Viewport width in points, captured verbatim at the MainActor call site.
    ///   - scale:          Screen scale captured at the MainActor call site (e.g. `traitCollection.displayScale`).
    ///                     `UITraitCollection.displayScale` is MainActor-isolated; capturing it at the call site
    ///                     ensures the `ImageCacheKey` matches the one mount-time `spawnMediaFetches` constructs.
    public func onIndexBoundary(
        _ leadingIndex: Int,
        workingRange: WorkingRange,
        tables: [NodeTable],
        availableWidth: CGFloat,
        scale: CGFloat
    ) {
        guard leadingIndex != lastLeadingIndex else { return }
        lastLeadingIndex = leadingIndex
        prefetchTask?.cancel()
        taskStartCount += 1

        // Capture actor state before entering the Task — group.addTask closures are
        // @Sendable nonisolated and cannot reference actor-isolated self directly.
        let cache = layoutCache
        let pool = textPool
        let actor = imageActor
        let capturedScale = scale
        let ahead = prefetchAhead
        let behind = prefetchBehind

        prefetchTask = Task {
            let rangeStart = max(0, leadingIndex - behind)
            let rangeEnd = min(leadingIndex + ahead, tables.count)
            guard rangeEnd > rangeStart else { return }

            // Single MainActor hop: advance or reset the ring buffer, then collect nil slots.
            // Combining both operations avoids N serial @MainActor awaits.
            let needed: [Int] = await MainActor.run {
                if rangeStart < workingRange.currentRangeStart {
                    // Scrolled backward past the window start — O(capacity) rebuild.
                    workingRange.resetRange(to: rangeStart)
                } else {
                    workingRange.advance(to: rangeStart)
                }
                return (rangeStart..<rangeEnd).filter { workingRange.entry(at: $0) == nil }
            }
            guard !needed.isEmpty, !Task.isCancelled else { return }

            // Parallel: check LayoutCache first; fall back to measureNode on a miss.
            // The for-await consumer fires each item's image prefetches as fire-and-forget
            // Tasks immediately when that item's layout resolves — cache-hit items dispatch
            // before cold-measure siblings finish. Prefetch Tasks are unstructured so commit
            // latency stays on the measure-only critical path, not gated on network+decode.
            var results: [(Int, ResolvedLayout, [Fragment])] = []
            var localHits = 0
            var spawnedPrefetches: [Task<Void, Never>] = []
            await withTaskGroup(of: (Int, ResolvedLayout, [Fragment], Bool).self) { group in
                for index in needed {
                    let table = tables[index]
                    let key = CacheKey(layoutHash: table.layoutHash, width: availableWidth)
                    group.addTask {
                        if let entry = await cache.get(key) {
                            return (index, entry.layout, entry.fragments, true)
                        }
                        // Guard before the expensive path — exits quickly on cancellation.
                        guard !Task.isCancelled else { return (index, .placeholder, [], false) }
                        let layout = await measureNode(
                            table, nodeIndex: 0,
                            width: availableWidth,
                            textPool: pool
                        )
                        let fragments = extractFragments(table: table, layout: layout)
                        await cache.set(CellEntry(layout: layout, fragments: fragments), for: key)
                        return (index, layout, fragments, false)
                    }
                }
                // Consume results in completion order; spawn prefetch immediately per item.
                // Cancelled results (isHit=false, fragments=[]) are skipped without spawning.
                for await (i, layout, fragments, isHit) in group {
                    guard !Task.isCancelled else { continue }
                    for fragment in fragments {
                        guard case .image(let d) = fragment.content, let url = d.url else { continue }
                        spawnedPrefetches.append(Task {
                            await actor.prefetch(for: url, targetSize: fragment.frame.size, cornerRadius: d.cornerRadius, scale: capturedScale)
                        })
                    }
                    if isHit { localHits += 1 }
                    results.append((i, layout, fragments))
                }
            }
            // Outer guard prevents any commit from a superseded prefetch. Cancelled subtasks
            // return .placeholder; the consumer skips them, so results holds only valid entries.
            guard !Task.isCancelled else {
                spawnedPrefetches.forEach { $0.cancel() }
                return
            }

            cacheHitCount += localHits

            await MainActor.run {
                for (i, layout, fragments) in results {
                    workingRange.commit(layout, fragments, at: i)
                }
            }

            // Await spawned prefetch Tasks so waitForCurrentPrefetch() captures full completion.
            // Cancellation of prefetchTask doesn't propagate to unstructured Tasks; best-effort
            // cancel is acceptable per ImageActor.prefetch contract (inner decode Task is unstructured).
            for task in spawnedPrefetches {
                await task.value
            }
        }
    }

    /// Resets dedup state and cancels any in-flight prefetch so the next
    /// `onIndexBoundary` call with the same leading index is not skipped by the
    /// guard on line 57 — necessary after `WorkingRange.invalidateAll()` wipes
    /// all entries and the leading index hasn't changed.
    public func markInvalidated() {
        lastLeadingIndex = -1
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// Awaits the current prefetch task. Used in tests to synchronise assertions.
    public func waitForCurrentPrefetch() async {
        await prefetchTask?.value
    }
}
#endif

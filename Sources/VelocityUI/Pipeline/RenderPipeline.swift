// RenderPipeline.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics
import os

/// Monotonic generation counter for the prefetch generation guard (primary supersession layer).
///
/// Bumped once per `onIndexBoundary` call. Each spawned prefetch Task captures its generation
/// value and the shared token, then checks `token.generation == gen` immediately before
/// launching the inner decode Task — if a newer boundary has fired the check returns false
/// and the task bails without starting any network work.
private final class PrefetchGenerationToken: Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    var generation: Int { lock.withLock { $0 } }

    @discardableResult
    func advance() -> Int {
        lock.withLock {
            $0 += 1
            return $0
        }
    }
}

/// Returns the half-open prefetch index range for a given leading visible index.
///
/// Single authoritative formula shared by the deep-cancel stale filter and the measure
/// loop — both call this function so they can never silently diverge (e.g. the stale
/// filter cancelling items the measure loop still wants, or missing items it abandons).
private func prefetchRange(leadingIndex: Int, ahead: Int, behind: Int, count: Int) -> Range<Int> {
    let start = max(0, leadingIndex - behind)
    let end = min(leadingIndex + ahead, count)
    // Clamp to avoid a trap: if leadingIndex is at or beyond count (feed shrank under a
    // stale boundary), start can exceed end. Both call sites handle empty ranges correctly.
    return start..<max(start, end)
}

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

    // MARK: - Supersession guard state

    /// Generation counter shared with every spawned prefetch Task.
    private let generationToken = PrefetchGenerationToken()

    /// One record per image fragment prefetched in the current batch.
    /// Populated incrementally in the for-await consumer loop (actor-isolated).
    /// Cleared and replaced on each new boundary call.
    private struct ActivePrefetchItem: Sendable {
        let index: Int
        let url: URL
        let targetSize: CGSize
        let cornerRadius: CGFloat
        let scale: CGFloat
    }
    private var activePrefetchItems: [ActivePrefetchItem] = []

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

        // Deep cancel (secondary layer): items from the previous batch whose index falls
        // outside the new range are guaranteed not to be needed. Cancel their in-flight
        // inner decode Tasks before they consume more network/decode budget.
        let newRange = prefetchRange(leadingIndex: leadingIndex, ahead: prefetchAhead, behind: prefetchBehind, count: tables.count)
        let staleItems = activePrefetchItems.filter { !newRange.contains($0.index) }
        if !staleItems.isEmpty {
            let actor = imageActor
            let specs = staleItems.map {
                PrefetchSpec(url: $0.url, targetSize: $0.targetSize, cornerRadius: $0.cornerRadius, scale: $0.scale)
            }
            Task { await actor.cancelInFlightPrefetches(specs) }
        }
        activePrefetchItems = []  // new batch populates incrementally via for-await loop

        prefetchTask?.cancel()
        taskStartCount += 1

        // Bump generation after clearing active items and before spawning new prefetches —
        // any prefetch that passed its guard in the old batch is stale by definition.
        let token = generationToken
        let myGen = token.advance()

        // Capture actor state before entering the Task — group.addTask closures are
        // @Sendable nonisolated and cannot reference actor-isolated self directly.
        let cache = layoutCache
        let pool = textPool
        let actor = imageActor
        let capturedScale = scale
        let ahead = prefetchAhead
        let behind = prefetchBehind

        prefetchTask = Task {
            let range = prefetchRange(leadingIndex: leadingIndex, ahead: ahead, behind: behind, count: tables.count)
            guard !range.isEmpty else { return }

            // Single MainActor hop: advance or reset the ring buffer, then collect nil slots.
            // Combining both operations avoids N serial @MainActor awaits.
            let needed: [Int] = await MainActor.run {
                if range.lowerBound < workingRange.currentRangeStart {
                    // Scrolled backward past the window start — O(capacity) rebuild.
                    workingRange.resetRange(to: range.lowerBound)
                } else {
                    workingRange.advance(to: range.lowerBound)
                }
                return range.filter { workingRange.entry(at: $0) == nil }
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
                        let capturedURL = url
                        let capturedSize = fragment.frame.size
                        let capturedRadius = d.cornerRadius
                        let gen = myGen
                        // Items at/after leadingIndex are coming into view next; items before
                        // it were already scrolled past. No scroll-direction signal exists yet —
                        // this assumes downward scroll; a velocity-aware pass can refine it later.
                        let p: DecodePriority = i >= leadingIndex ? .ahead : .behind
                        spawnedPrefetches.append(Task {
                            await actor.prefetch(
                                for: capturedURL,
                                targetSize: capturedSize,
                                cornerRadius: capturedRadius,
                                scale: capturedScale,
                                priority: p,
                                isCurrent: { token.generation == gen }
                            )
                        })
                        // Track for deep-cancel on the next superseding boundary.
                        // The for-await body runs isolated to RenderPipeline's actor, so
                        // appending to the actor-stored array is safe without additional locks.
                        self.activePrefetchItems.append(ActivePrefetchItem(
                            index: i,
                            url: capturedURL,
                            targetSize: capturedSize,
                            cornerRadius: capturedRadius,
                            scale: capturedScale
                        ))
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
        if !activePrefetchItems.isEmpty {
            let actor = imageActor
            let specs = activePrefetchItems.map {
                PrefetchSpec(url: $0.url, targetSize: $0.targetSize, cornerRadius: $0.cornerRadius, scale: $0.scale)
            }
            Task { await actor.cancelInFlightPrefetches(specs) }
            activePrefetchItems = []
        }
    }

    /// Awaits the current prefetch task. Used in tests to synchronise assertions.
    public func waitForCurrentPrefetch() async {
        await prefetchTask?.value
    }
}
#endif

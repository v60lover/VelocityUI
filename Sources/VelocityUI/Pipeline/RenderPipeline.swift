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

private struct TextBitmapArtifact: @unchecked Sendable {
    let key: BlockKey
    let image: CGImage
    let size: CGSize
}

private nonisolated func rasterizeTextArtifacts(
    table: NodeTable,
    fragments: [Fragment],
    scale: CGFloat
) -> [TextBitmapArtifact] {
    let itemID = table.itemID
    return fragments.enumerated().compactMap { position, fragment in
        guard case .text(let descriptor) = fragment.content,
              let image = rasterizeText(descriptor, size: fragment.frame.size, scale: scale)
        else { return nil }
        let key = BlockKey(boxedItemID: itemID, index: position, blockID: fragment.blockID)
        return TextBitmapArtifact(key: key, image: image, size: fragment.frame.size)
    }
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

    /// Scroll direction from the most recent `onIndexBoundary` call. Internal for
    /// testing only — lets tests assert on the classification-driving signal directly
    /// instead of round-tripping through ImageActor's prefetch-priority seam.
    private(set) var lastDirection: ScrollDirection = .down

    private let textPool: TextMeasurementPool
    private let layoutCache: LayoutCache
    private let imageActor: ImageActor
    private let frozenBitmapStore: FrozenBitmapStore

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
        frozenBitmapStore: FrozenBitmapStore = FrozenBitmapStore(),
        prefetchAhead: Int = 10,
        prefetchBehind: Int = 3
    ) {
        self.textPool = textPool
        self.layoutCache = layoutCache
        self.imageActor = imageActor
        self.frozenBitmapStore = frozenBitmapStore
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
        self.frozenBitmapStore = FrozenBitmapStore()
        self.prefetchAhead = 60
        self.prefetchBehind = 3
    }

    /// Notify the pipeline that the visible leading index has changed. No-op if unchanged since
    /// last call; cancels and replaces any running prefetch task.
    ///
    /// - Parameters:
    ///   - tables: NodeTables in display order, parallel to the item array.
    ///   - scale: Captured at the `@MainActor` call site (e.g. `traitCollection.displayScale`)
    ///     so the `ImageCacheKey` matches the one mount-time `spawnMediaFetches` constructs.
    ///   - direction: Real scroll-travel direction from `FeedScrollView`'s `contentOffset` delta
    ///     — determines which side of `leadingIndex` classifies `.ahead` vs `.behind`. Defaults
    ///     to `.down` (VelocityUI-he0's original assumption), so non-observing callers are
    ///     unaffected.
    public func onIndexBoundary(
        _ leadingIndex: Int,
        workingRange: WorkingRange,
        tables: [NodeTable],
        availableWidth: CGFloat,
        scale: CGFloat,
        direction: ScrollDirection = .down
    ) {
        guard leadingIndex != lastLeadingIndex else { return }
        lastLeadingIndex = leadingIndex
        lastDirection = direction

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
        let bitmapStore = frozenBitmapStore
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
            // before cold-measure siblings finish. Text rasterization completes before commit
            // so the first mount has pixels; network/decode prefetch remains unstructured and
            // does not gate that commit.
            var results: [(Int, ResolvedLayout, [Fragment], [TextBitmapArtifact])] = []
            var localHits = 0
            var spawnedPrefetches: [Task<Void, Never>] = []
            await withTaskGroup(of: (Int, ResolvedLayout, [Fragment], [TextBitmapArtifact], Bool).self) { group in
                for index in needed {
                    let table = tables[index]
                    let key = CacheKey(layoutHash: table.layoutHash, width: availableWidth)
                    group.addTask {
                        if let entry = await cache.get(key) {
                            let artifacts = rasterizeTextArtifacts(
                                table: table,
                                fragments: entry.fragments,
                                scale: capturedScale
                            )
                            return (index, entry.layout, entry.fragments, artifacts, true)
                        }
                        // Guard before the expensive path — exits quickly on cancellation.
                        guard !Task.isCancelled else { return (index, .placeholder, [], [], false) }
                        let layout = await measureNode(
                            table, nodeIndex: 0,
                            width: availableWidth,
                            textPool: pool
                        )
                        let fragments = extractFragments(table: table, layout: layout)
                        let artifacts = rasterizeTextArtifacts(
                            table: table,
                            fragments: fragments,
                            scale: capturedScale
                        )
                        await cache.set(CellEntry(layout: layout, fragments: fragments), for: key)
                        return (index, layout, fragments, artifacts, false)
                    }
                }
                // Consume results in completion order; spawn prefetch immediately per item.
                // Cancelled results (isHit=false, fragments=[]) are skipped without spawning.
                for await (i, layout, fragments, artifacts, isHit) in group {
                    guard !Task.isCancelled else { continue }
                    for fragment in fragments {
                        guard case .image(let d) = fragment.content, let url = d.url else { continue }
                        let capturedURL = url
                        let capturedSize = fragment.frame.size
                        let capturedRadius = d.cornerRadius
                        let gen = myGen
                        // On downward scroll, items at/after leadingIndex are coming into view
                        // next (higher indices, below the viewport). On upward scroll the travel
                        // direction inverts: items at/before leadingIndex (lower indices, above
                        // the viewport) are what's coming next. `direction` is a real signal —
                        // FeedScrollView derives it from contentOffset.y deltas, not assumed.
                        let p: DecodePriority
                        switch direction {
                        case .down: p = i >= leadingIndex ? .ahead : .behind
                        case .up:   p = i <= leadingIndex ? .ahead : .behind
                        }
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
                    results.append((i, layout, fragments, artifacts))
                }
            }
            // Outer guard prevents any commit from a superseded prefetch. Cancelled subtasks
            // return .placeholder; the consumer skips them, so results holds only valid entries.
            guard !Task.isCancelled else {
                spawnedPrefetches.forEach { $0.cancel() }
                return
            }

            cacheHitCount += localHits

            for (_, _, _, artifacts) in results {
                for artifact in artifacts {
                    bitmapStore.store(
                        artifact.image,
                        size: artifact.size,
                        cost: artifact.image.bytesPerRow * artifact.image.height,
                        for: artifact.key
                    )
                }
            }

            await MainActor.run {
                for (i, layout, fragments, _) in results {
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

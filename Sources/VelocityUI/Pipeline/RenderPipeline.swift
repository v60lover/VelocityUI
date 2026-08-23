// RenderPipeline.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics
import os

/// Monotonic generation counter for the prefetch supersession guard. Bumped once per
/// `onIndexBoundary` call; each spawned prefetch Task checks its captured generation against
/// the token right before starting decode work, bailing without network work if a newer
/// boundary already fired.
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

/// Clamps a caller-supplied warm range to `0..<count`. Defensive: `tables.count` is this
/// actor's own source of truth, so this is what prevents a trap if a stale boundary call
/// races a shrinking feed.
private func clampedRange(_ range: Range<Int>, count: Int) -> Range<Int> {
    let start = max(0, range.lowerBound)
    let end = min(range.upperBound, count)
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
    /// Last warm range this actor was notified of. `nil` means never notified — distinct
    /// from the legitimate empty `0..<0`. Compared by full range, so a window that
    /// widens/narrows at the same leading edge still re-notifies.
    private var lastWarmRange: Range<Int>?
    private(set) var prefetchTask: Task<Void, Never>?

    /// Incremented each time a new prefetch Task is spawned.
    /// Internal for testing only — not part of the production API.
    private(set) var taskStartCount: Int = 0

    /// Incremented each time onIndexBoundary resolves an index from LayoutCache
    /// rather than re-measuring. Internal for testing only.
    private(set) var cacheHitCount: Int = 0

    /// Scroll direction from the most recent `onIndexBoundary` call. Test-only.
    private(set) var lastDirection: ScrollDirection = .down

    private let textPool: TextMeasurementPool
    private let layoutCache: LayoutCache
    private let imageActor: ImageActor
    private let frozenBitmapStore: FrozenBitmapStore

    // MARK: - Supersession guard state

    /// Generation counter shared with every spawned prefetch Task.
    private let generationToken = PrefetchGenerationToken()

    /// One record per image fragment prefetched in the current batch — cleared and
    /// replaced on each new boundary call.
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
        frozenBitmapStore: FrozenBitmapStore = FrozenBitmapStore()
    ) {
        self.textPool = textPool
        self.layoutCache = layoutCache
        self.imageActor = imageActor
        self.frozenBitmapStore = frozenBitmapStore
    }

    /// Test-only convenience — creates a private pool/cache/imageActor not shared with
    /// RenderEnvironment; its cache is isolated from `env.imageActor`.
    init() {
        self.textPool = TextMeasurementPool()
        self.layoutCache = LayoutCache()
        self.imageActor = ImageActor()
        self.frozenBitmapStore = FrozenBitmapStore()
    }

    /// Notifies the pipeline that the warm window changed. No-op if `warmRange` is unchanged
    /// since the last call; otherwise cancels and replaces the running prefetch task.
    ///
    /// - Parameters:
    ///   - warmRange: exact index range to measure/prefetch, already computed by the caller;
    ///     re-clamped to `0..<tables.count` defensively.
    ///   - leadingIndex: real current top-visible index, used only to classify each prefetch
    ///     as `.ahead`/`.behind` by `direction`.
    ///   - tables: NodeTables in display order, parallel to the item array.
    ///   - availableWidth: the measure width — must be the exact width every other read site
    ///     (`FeedScrollView`'s own `CacheKey` lookups) uses, or writes here silently miss reads.
    ///   - scale: captured at the `@MainActor` call site so `ImageCacheKey` matches mount time's.
    ///   - direction: real scroll-travel direction from `contentOffset` deltas; determines
    ///     which side of `leadingIndex` is `.ahead` vs `.behind`.
    public func onIndexBoundary(
        warmRange: Range<Int>,
        leadingIndex: Int,
        workingRange: WorkingRange,
        tables: [NodeTable],
        availableWidth: CGFloat,
        scale: CGFloat,
        direction: ScrollDirection = .down
    ) {
        guard warmRange != lastWarmRange else { return }
        lastWarmRange = warmRange
        lastDirection = direction

        // Deep cancel: items from the previous batch outside the new range are guaranteed
        // not needed — cancel their in-flight decode Tasks before they burn more budget.
        let newRange = clampedRange(warmRange, count: tables.count)
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
        let capturedWarmRange = warmRange

        prefetchTask = Task {
            let range = clampedRange(capturedWarmRange, count: tables.count)
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

            // Parallel: LayoutCache lookup, falling back to measureNode on a miss. The
            // for-await consumer fires each item's image prefetches as soon as its layout
            // resolves — cache hits dispatch before cold-measure siblings finish, and
            // prefetch work doesn't gate commit.
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
                        // Direction flips which side of leadingIndex is "ahead": downward
                        // scroll means higher indices come next, upward inverts it.
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

            // Await spawned prefetch Tasks so waitForCurrentPrefetch() captures full completion —
            // cancelling prefetchTask doesn't propagate to these unstructured Tasks.
            for task in spawnedPrefetches {
                await task.value
            }
        }
    }

    /// Resets dedup state and cancels any in-flight prefetch so the next `onIndexBoundary`
    /// call with the same warm range isn't skipped by the unchanged-range guard — needed
    /// after `WorkingRange.invalidateAll()` wipes entries without the range itself changing.
    public func markInvalidated() {
        lastWarmRange = nil
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

// RenderPipeline.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics
import os
import SwaTex
import SwaTexRender

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
    private let highlightRegistry: HighlightRegistry
    private let formulaCache: FormulaCache
    private let mathFontProvider: KaTeXFontProvider

    /// Fires once per code-block body tokenized+rasterized from scratch, on cold miss or
    /// cache-hit-without-reuse alike — see `RenderEnvironment.codeBodyRetokenizeObserver`.
    /// `nil` in production and in most tests.
    private let codeBodyRetokenizeObserver: (@Sendable () -> Void)?

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

    // MARK: - Raster repair state

    /// Indices currently being repaired by an in-flight `repairArtifacts` call — see
    /// VelocityUI-8otc.6.3. Guards against two overlapping calls (e.g. two coalesced
    /// `FeedScrollView` layout passes) spawning duplicate raster work for the same index.
    private var inFlightRepairIndices: Set<Int> = []

    public init(
        textPool: TextMeasurementPool,
        layoutCache: LayoutCache,
        imageActor: ImageActor,
        frozenBitmapStore: FrozenBitmapStore = FrozenBitmapStore(),
        highlightRegistry: HighlightRegistry,
        formulaCache: FormulaCache = .init(),
        mathFontProvider: KaTeXFontProvider = .init(),
        codeBodyRetokenizeObserver: (@Sendable () -> Void)? = nil
    ) {
        self.textPool = textPool
        self.layoutCache = layoutCache
        self.imageActor = imageActor
        self.frozenBitmapStore = frozenBitmapStore
        self.highlightRegistry = highlightRegistry
        self.formulaCache = formulaCache
        self.mathFontProvider = mathFontProvider
        self.codeBodyRetokenizeObserver = codeBodyRetokenizeObserver
    }

    /// Test-only convenience — creates a private pool/cache/imageActor not shared with
    /// RenderEnvironment; its cache is isolated from `env.imageActor`.
    init() {
        self.textPool = TextMeasurementPool()
        self.layoutCache = LayoutCache()
        self.imageActor = ImageActor()
        self.frozenBitmapStore = FrozenBitmapStore()
        self.highlightRegistry = HighlightRegistry()
        self.formulaCache = FormulaCache()
        self.mathFontProvider = KaTeXFontProvider()
        self.codeBodyRetokenizeObserver = nil
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
    ///   - invalidate: when `true`, runs the invalidation reset (same body as `markInvalidated()`)
    ///     BEFORE the `warmRange == lastWarmRange` dedup guard below, inside this same actor
    ///     call. Callers use this instead of a separate `markInvalidated()` Task so "invalidate"
    ///     and "schedule the replacement" can never be reordered by the scheduler — the actor
    ///     serializes them into one op.
    public func onIndexBoundary(
        warmRange: Range<Int>,
        leadingIndex: Int,
        workingRange: WorkingRange,
        tables: [NodeTable],
        availableWidth: CGFloat,
        scale: CGFloat,
        direction: ScrollDirection = .down,
        invalidate: Bool = false
    ) {
        if invalidate {
            performInvalidation()
        }

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
        let registry = highlightRegistry
        let formulaCache = formulaCache
        let fontProvider = mathFontProvider
        let capturedScale = scale
        let capturedWarmRange = warmRange

        prefetchTask = Task {
            // Keep the pixels and their cache identity on the same locked theme snapshot.
            let themeSnapshot = registry.themeSnapshot
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
            var localCodeBodyRetokenizes = 0
            var spawnedPrefetches: [Task<Void, Never>] = []
            await withTaskGroup(of: (Int, ResolvedLayout, [Fragment], [TextBitmapArtifact], Bool, Int).self) { group in
                for index in needed {
                    let table = tables[index]
                    let key = CacheKey(layoutHash: table.layoutHash, width: availableWidth)
                    group.addTask {
                        if let entry = await cache.get(key) {
                            let (artifacts, retokenizeCount) = rasterizeTextArtifacts(
                                table: table,
                                fragments: entry.fragments,
                                layoutWidth: availableWidth,
                                scale: capturedScale,
                                highlightRegistry: registry,
                                themeSnapshot: themeSnapshot,
                                reusableFrom: bitmapStore,
                                formulaCache: formulaCache, fontProvider: fontProvider
                            )
                            let tableArtifacts = rasterizeTableArtifacts(
                                table: table, fragments: entry.fragments, scale: capturedScale,
                                formulaCache: formulaCache, fontProvider: fontProvider
                            )
                            let mathArtifacts = rasterizeMathArtifacts(
                                table: table, fragments: entry.fragments, scale: capturedScale,
                                formulaCache: formulaCache, fontProvider: fontProvider
                            )
                            return (index, entry.layout, entry.fragments, artifacts + tableArtifacts + mathArtifacts, true, retokenizeCount)
                        }
                        // Guard before the expensive path — exits quickly on cancellation.
                        guard !Task.isCancelled else { return (index, .placeholder, [], [], false, 0) }
                        let layout = await measureNode(
                            table, nodeIndex: 0,
                            width: availableWidth,
                            textPool: pool,
                            formulaCache: formulaCache
                        )
                        let fragments = extractFragments(table: table, layout: layout)
                        let (artifacts, retokenizeCount) = rasterizeTextArtifacts(
                            table: table,
                            fragments: fragments,
                            layoutWidth: availableWidth,
                            scale: capturedScale,
                            highlightRegistry: registry,
                            themeSnapshot: themeSnapshot,
                            reusableFrom: nil,
                            formulaCache: formulaCache, fontProvider: fontProvider
                        )
                        let tableArtifacts = rasterizeTableArtifacts(
                            table: table, fragments: fragments, scale: capturedScale,
                            formulaCache: formulaCache, fontProvider: fontProvider
                        )
                        let mathArtifacts = rasterizeMathArtifacts(
                            table: table, fragments: fragments, scale: capturedScale,
                            formulaCache: formulaCache, fontProvider: fontProvider
                        )
                        await cache.set(CellEntry(layout: layout, fragments: fragments), for: key)
                        return (index, layout, fragments, artifacts + tableArtifacts + mathArtifacts, false, retokenizeCount)
                    }
                }
                // Consume results in completion order; spawn prefetch immediately per item.
                // Cancelled results (isHit=false, fragments=[]) are skipped without spawning.
                for await (i, layout, fragments, artifacts, isHit, retokenizeCount) in group {
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
                    localCodeBodyRetokenizes += retokenizeCount
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
            if let codeBodyRetokenizeObserver {
                for _ in 0..<localCodeBodyRetokenizes { codeBodyRetokenizeObserver() }
            }

            for (_, _, _, artifacts) in results {
                for artifact in artifacts {
                    bitmapStore.store(
                        artifact.image,
                        size: artifact.size,
                        cost: artifact.image.bytesPerRow * artifact.image.height,
                        for: artifact.key,
                        codeBodyIdentity: artifact.codeBodyIdentity
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

    /// Regenerates raster artifacts for indices whose `WorkingRange` entry is still valid but
    /// whose bitmaps were evicted from BOTH `VisibleBlockStore` and `FrozenBitmapStore` — a
    /// WorkingRange hit proves layout + fragment metadata survived, not that the raster pixels
    /// did (VelocityUI-8otc.6.3). Reuses the committed `entry.layout`/`entry.fragments`; only
    /// re-measures when the entry is missing or its layout collapsed to zero height.
    ///
    /// Coalesces: an index already covered by another in-flight call to this method is skipped,
    /// so two racing callers (e.g. two `FeedScrollView` layout passes) never spawn duplicate
    /// raster work for the same index. Callers must not `await` this from the scroll path itself
    /// — it runs off `updateVisibleCells`, on the async repair side channel.
    public func repairArtifacts(
        indices: Set<Int>,
        workingRange: WorkingRange,
        tables: [NodeTable],
        availableWidth: CGFloat,
        scale: CGFloat
    ) async {
        let toRepair = indices.subtracting(inFlightRepairIndices)
        guard !toRepair.isEmpty else { return }
        inFlightRepairIndices.formUnion(toRepair)
        defer { inFlightRepairIndices.subtract(toRepair) }

        // Capture actor state before entering the TaskGroup — its closures are @Sendable
        // nonisolated and cannot reference actor-isolated self directly (same reason
        // onIndexBoundary captures locals above).
        let themeSnapshot = highlightRegistry.themeSnapshot
        let pool = textPool
        let bitmapStore = frozenBitmapStore
        let registry = highlightRegistry
        let formulaCache = formulaCache
        let fontProvider = mathFontProvider

        await withTaskGroup(of: Void.self) { group in
            for index in toRepair where index < tables.count {
                let table = tables[index]
                group.addTask {
                    guard !Task.isCancelled else { return }

                    let fragments: [Fragment]
                    if let entry = await MainActor.run(body: { workingRange.entry(at: index) }),
                       entry.layout.totalFrame.height > 0 {
                        fragments = entry.fragments
                    } else {
                        guard !Task.isCancelled else { return }
                        let layout = await measureNode(
                            table, nodeIndex: 0, width: availableWidth,
                            textPool: pool, formulaCache: formulaCache
                        )
                        let measuredFragments = extractFragments(table: table, layout: layout)
                        await MainActor.run { workingRange.commit(layout, measuredFragments, at: index) }
                        fragments = measuredFragments
                    }

                    guard !Task.isCancelled else { return }

                    let (textArtifacts, _) = rasterizeTextArtifacts(
                        table: table, fragments: fragments, layoutWidth: availableWidth, scale: scale,
                        highlightRegistry: registry, themeSnapshot: themeSnapshot,
                        reusableFrom: bitmapStore, formulaCache: formulaCache, fontProvider: fontProvider
                    )
                    let tableArtifacts = rasterizeTableArtifacts(
                        table: table, fragments: fragments, scale: scale,
                        formulaCache: formulaCache, fontProvider: fontProvider
                    )
                    let mathArtifacts = rasterizeMathArtifacts(
                        table: table, fragments: fragments, scale: scale,
                        formulaCache: formulaCache, fontProvider: fontProvider
                    )
                    for artifact in textArtifacts + tableArtifacts + mathArtifacts {
                        bitmapStore.store(
                            artifact.image, size: artifact.size,
                            cost: artifact.image.bytesPerRow * artifact.image.height,
                            for: artifact.key, codeBodyIdentity: artifact.codeBodyIdentity
                        )
                    }
                }
            }
        }
    }

    /// Resets dedup state and cancels any in-flight prefetch so the next `onIndexBoundary`
    /// call with the same warm range isn't skipped by the unchanged-range guard — needed
    /// after `WorkingRange.invalidateAll()` wipes entries without the range itself changing.
    ///
    /// Production callers should prefer `onIndexBoundary(invalidate: true)` instead of calling
    /// this from a separate Task — two unstructured Tasks race, and a late invalidate can cancel
    /// the replacement work it was meant to precede. Stays public and safe to call standalone
    /// when there is no following boundary notification to race against (e.g. teardown), and
    /// for tests.
    public func markInvalidated() {
        performInvalidation()
    }

    private func performInvalidation() {
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

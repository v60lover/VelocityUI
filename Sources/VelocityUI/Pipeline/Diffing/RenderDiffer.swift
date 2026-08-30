// RenderDiffer.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

// MARK: - ChangeKind

/// Coarse classification of how two NodeTables for the same item differ, picking the minimum
/// re-work path: `.none` skips entirely, `.appearance` re-commits visuals only, `.media`
/// re-fetches image content, `.layout` does a full re-measure. A `cornerRadius`-only change
/// still classifies `.appearance`, but since rounding is baked at decode time (not on
/// `CALayer`), that consumer must still re-request the image for a new rounded bitmap.
public enum ChangeKind: Sendable {
    case none
    case appearance
    case media
    case layout
}

// MARK: - classify

/// Compares two NodeTables via a three-tier hash-first algorithm: both hashes equal →
/// `.none`; layoutHash equal → `.appearance`; else a flat-array walk classifies `.media`
/// only if every differing node is an image URL change with dimensions already cached,
/// else `.layout`.
///
/// - Parameter dimensionCache: same instance `ImageActor` uses; `nil` disables the
///   `.media` fast-path (forces `.layout`).
public nonisolated func classify(
    _ prev: NodeTable,
    _ next: NodeTable,
    dimensionCache: DimensionCache?
) -> ChangeKind {
    // Tier 1: identical
    if prev.layoutHash == next.layoutHash && prev.appearanceHash == next.appearanceHash {
        return .none
    }
    // Tier 2: appearance-only (layout is stable, no re-measure needed)
    if prev.layoutHash == next.layoutHash {
        return .appearance
    }
    // Tier 3: layout hash changed — walk flat arrays to check if it's media-only.
    // Node counts differing means structural change → always .layout.
    let pNodes = prev.nodes
    let nNodes = next.nodes
    guard pNodes.count == nNodes.count else { return .layout }

    for i in pNodes.indices {
        let p = pNodes[i]
        let n = nNodes[i]
        // Fast-skip: per-node layout is unchanged
        if nodeLayoutEquals(p, n) { continue }
        // Layout differs for this node. Only image URL changes with known dimensions
        // can stay at .media — everything else forces .layout.
        guard case .image(let pd) = p,
              case .image(let nd) = n,
              pd.aspectRatio == nd.aspectRatio,
              pd.contentMode == nd.contentMode,
              let url = nd.url,
              dimensionCache?.get(url) != nil
        else { return .layout }
    }
    // Every layout-hash-differing node was an image URL change with cached dimensions.
    return .media
}

// MARK: - LayoutSnapshot

/// Ordered snapshot of NodeTables for a set of items.
///
/// Tables appear in display order. Each entry carries its own itemID via
/// `NodeTable.itemID`. Produced from the items array in `FeedScrollView`.
public struct LayoutSnapshot: Sendable {
    public let tables: [NodeTable]

    public init(tables: [NodeTable]) {
        self.tables = tables
    }
}

// MARK: - ChangeSet

/// Flat description of differences between two LayoutSnapshots. All change arrays carry
/// full NodeTable references plus `(prevIdx, nextIdx)` positions, avoiding a second lookup.
/// `removed` carries the prev-state table for resource cleanup; `survived` holds
/// `.none`-classified pairs so `rebuildFrames` can forward known heights.
///
/// CoW contract: release the previous `ChangeSet` before calling `diff()` again — a
/// still-retained one forces a private-copy reallocation on `resetScratch()`, defeating
/// the scratch arrays' zero-allocation reuse.
public struct ChangeSet: Sendable {
    public let layoutChanged:     [(prev: NodeTable, next: NodeTable, prevIdx: Int, nextIdx: Int)]
    public let appearanceChanged: [(prev: NodeTable, next: NodeTable, prevIdx: Int, nextIdx: Int)]
    public let mediaChanged:      [(prev: NodeTable, next: NodeTable, prevIdx: Int, nextIdx: Int)]
    public let added:             [(table: NodeTable, nextIdx: Int)]
    /// Prev-state tables for items no longer present in the next snapshot.
    public let removed:           [(table: NodeTable, prevIdx: Int)]
    /// (prevIdx, nextIdx) pairs for .none-classified (unchanged) items.
    /// Enables zero-AnyHashable height forwarding in rebuildFrames.
    public let survived:          [(prevIdx: Int, nextIdx: Int)]

    /// True when at least one change array is non-empty. `survived` is excluded.
    public var hasChanges: Bool {
        !layoutChanged.isEmpty || !appearanceChanged.isEmpty ||
        !mediaChanged.isEmpty || !added.isEmpty || !removed.isEmpty
    }
}

// MARK: - RenderDiffer

/// Allocation-free differ for consecutive LayoutSnapshots — scratch arrays reuse via
/// `removeAll(keepingCapacity: true)` after the first `diff()` call. Inject the same
/// `DimensionCache` `ImageActor` uses, or `classify()`'s `.media` fast-path silently
/// breaks. `diff()` must not be called concurrently — `@unchecked Sendable` relies on
/// `FeedScrollView` (`@MainActor`) as sole owner.
public final class RenderDiffer: @unchecked Sendable {

    private let dimensionCache: DimensionCache?

    // Scratch buffers — reused across diff() calls
    private var scratchLayout:     [(prev: NodeTable, next: NodeTable, prevIdx: Int, nextIdx: Int)] = []
    private var scratchAppearance: [(prev: NodeTable, next: NodeTable, prevIdx: Int, nextIdx: Int)] = []
    private var scratchMedia:      [(prev: NodeTable, next: NodeTable, prevIdx: Int, nextIdx: Int)] = []
    private var scratchAdded:      [(table: NodeTable, nextIdx: Int)] = []
    private var scratchRemoved:    [(table: NodeTable, prevIdx: Int)] = []
    private var scratchSurvived:   [(prevIdx: Int, nextIdx: Int)] = []
    private var scratchPrevIndex:  [AnyHashable: Int] = [:]

    /// - Parameter dimensionCache: same instance as `ImageActor.dimensionCache`, or `nil`
    ///   to disable the `.media` fast-path — required explicitly so the choice is visible
    ///   at each call site.
    public init(dimensionCache: DimensionCache?) {
        self.dimensionCache = dimensionCache
    }

    /// Computes the delta between two consecutive snapshots.
    ///
    /// On the second+ call, no backing-buffer allocations occur for the scratch
    /// arrays as long as the diff size does not exceed the historical maximum —
    /// `removeAll(keepingCapacity: true)` retains bucket/element capacity.
    public func diff(prev: LayoutSnapshot, next: LayoutSnapshot) -> ChangeSet {
        resetScratch()

        // Build O(1) lookup: itemID → index in prev.tables
        for (i, table) in prev.tables.enumerated() {
            scratchPrevIndex[table.itemID] = i
        }

        // Walk next tables: classify existing items, collect added items
        for (nextIdx, nextTable) in next.tables.enumerated() {
            guard let prevIdx = scratchPrevIndex[nextTable.itemID] else {
                scratchAdded.append((nextTable, nextIdx))
                continue
            }
            let prevTable = prev.tables[prevIdx]
            // Remove from prevIndex so we know what remains (= removed) after this loop
            scratchPrevIndex.removeValue(forKey: nextTable.itemID)

            switch classify(prevTable, nextTable, dimensionCache: dimensionCache) {
            case .none:        scratchSurvived.append((prevIdx, nextIdx))
            case .appearance:  scratchAppearance.append((prevTable, nextTable, prevIdx, nextIdx))
            case .media:       scratchMedia.append((prevTable, nextTable, prevIdx, nextIdx))
            case .layout:      scratchLayout.append((prevTable, nextTable, prevIdx, nextIdx))
            }
        }

        // Items still in prevIndex were not found in next → removed.
        // Walk prev.tables in order (not the dict) so removed preserves display order.
        for (i, table) in prev.tables.enumerated() where scratchPrevIndex[table.itemID] != nil {
            scratchRemoved.append((table, i))
        }

        return ChangeSet(
            layoutChanged:     scratchLayout,
            appearanceChanged: scratchAppearance,
            mediaChanged:      scratchMedia,
            added:             scratchAdded,
            removed:           scratchRemoved,
            survived:          scratchSurvived
        )
    }

    // MARK: - Internal test hooks

    /// Backing capacity of the scratch buffers after the most recent diff() call.
    /// Used in tests to verify `removeAll(keepingCapacity: true)` semantics — capacity
    /// must not drop below the peak seen during a large diff.
    var scratchLayoutCapacity:     Int { scratchLayout.capacity }
    var scratchAppearanceCapacity: Int { scratchAppearance.capacity }
    var scratchMediaCapacity:      Int { scratchMedia.capacity }
    var scratchAddedCapacity:      Int { scratchAdded.capacity }
    var scratchRemovedCapacity:    Int { scratchRemoved.capacity }
    var scratchSurvivedCapacity:   Int { scratchSurvived.capacity }

    // MARK: - Private

    private func resetScratch() {
        scratchLayout.removeAll(keepingCapacity: true)
        scratchAppearance.removeAll(keepingCapacity: true)
        scratchMedia.removeAll(keepingCapacity: true)
        scratchAdded.removeAll(keepingCapacity: true)
        scratchRemoved.removeAll(keepingCapacity: true)
        scratchSurvived.removeAll(keepingCapacity: true)
        scratchPrevIndex.removeAll(keepingCapacity: true)
    }
}

// MARK: - Private helpers

/// Returns true when two NodeKind values have identical layout properties.
/// Compares stored descriptor layoutHash values; for spacers, compares the
/// raw CGFloat directly (spacer has no descriptor, its value IS the layout).
private nonisolated func nodeLayoutEquals(_ a: NodeKind, _ b: NodeKind) -> Bool {
    switch (a, b) {
    case (.vstack(let d1),     .vstack(let d2)):     return d1.layoutHash == d2.layoutHash
    case (.hstack(let d1),     .hstack(let d2)):     return d1.layoutHash == d2.layoutHash
    case (.zstack(let d1),     .zstack(let d2)):     return d1.layoutHash == d2.layoutHash
    case (.spacer(let v1),     .spacer(let v2)):     return v1 == v2
    case (.text(let d1),       .text(let d2)):       return d1.layoutHash == d2.layoutHash
    case (.image(let d1),      .image(let d2)):      return d1.layoutHash == d2.layoutHash
    case (.gif(let d1),        .gif(let d2)):        return d1.layoutHash == d2.layoutHash
    case (.video(let d1),      .video(let d2)):      return d1.layoutHash == d2.layoutHash
    case (.hosting(let d1),    .hosting(let d2)):    return d1.layoutHash == d2.layoutHash
    case (.customLayer(let s1),.customLayer(let s2)):return s1 == s2
    default:                                          return false  // different node kinds
    }
}
#endif

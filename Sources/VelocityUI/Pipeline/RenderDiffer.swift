// RenderDiffer.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

// MARK: - ChangeKind

/// Coarse classification of how two NodeTables for the same item differ.
///
/// Consumers use ChangeKind to select the minimum re-work path:
/// - `.none`: skip entirely — nothing changed.
/// - `.appearance`: re-commit visual properties only; geometry and media unchanged.
/// - `.media`: re-fetch image content; geometry unchanged (layout does not re-run).
/// - `.layout`: full re-measure and re-commit.
///
/// Note on `.appearance` + cornerRadius: AsyncImageNode bakes corner rounding at
/// decode time via CGContext clip (never on CALayer). A cornerRadius change classifies
/// as `.appearance`, but the appearance consumer MUST re-request image content from
/// ImageActor so the new rounded bitmap is decoded. See ImageDescriptor.cornerRadius.
public enum ChangeKind: Sendable {
    case none
    case appearance
    case media
    case layout
}

// MARK: - classify

/// Compares two NodeTables for the same item and returns the minimum change tier.
///
/// Three-tier, hash-first algorithm:
/// 1. Both hashes equal → `.none` (O(1), zero node inspection).
/// 2. layoutHash equal, appearanceHash different → `.appearance` (provable from hashes).
/// 3. layoutHash different → pairwise flat-array walk. If every node with a differing
///    layout hash is an image node where only the URL changed and the new URL's
///    dimensions are already in `dimensionCache` → `.media`. Otherwise → `.layout`.
///
/// - Parameters:
///   - prev: The previous NodeTable for this item.
///   - next: The updated NodeTable for the same item (must carry the same itemID).
///   - dimensionCache: The shared DimensionCache. Pass the same instance as ImageActor
///     uses so decode-time stores are visible here (DimensionCache.swift DI contract).
///     Pass `nil` to disable the `.media` fast-path (forces `.layout` when layout changes).
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

/// Flat description of differences between two LayoutSnapshots.
///
/// All five change arrays carry full NodeTable references so consumers can
/// route work without a second lookup. Each entry also carries (prevIdx,
/// nextIdx) — the item's position in the prev and next snapshot respectively
/// — so consumers can avoid O(N) AnyHashable dictionary rebuilds.
///
/// `removed` carries the prev-state table (not the new state) so consumers
/// can clean up media resources keyed by the old descriptor.
///
/// `survived` carries (prevIdx, nextIdx) pairs for items classified .none —
/// unchanged items that still need their known heights forwarded to rebuildFrames.
/// It does NOT contribute to `hasChanges`.
///
/// `layoutChanged` pairs are ordered: prev first, next second.
///
/// CoW lifetime contract: release the previous ChangeSet **before** calling
/// `diff()` again. The scratch arrays backing the six result arrays are
/// reused across calls via `removeAll(keepingCapacity: true)`. If a prior
/// ChangeSet is still retained when `resetScratch()` runs, Swift's
/// copy-on-write semantics will reallocate the backing buffer to give that
/// ChangeSet its own copy — defeating the zero-allocation guarantee.
/// `FeedScrollView` must not retain the prior ChangeSet across a call to
/// `diff()`.
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

/// Allocation-free differ for consecutive LayoutSnapshots.
///
/// Scratch arrays are pre-allocated on first `diff()` call and reused on
/// subsequent calls via `removeAll(keepingCapacity: true)`. After warm-up,
/// a diff that touches k items of n allocates only the ChangeSet value
/// types (copied on return) — no backing-buffer growth for the typical
/// append-page case where k << n.
///
/// DI contract: inject the **same** `DimensionCache` that `ImageActor` uses
/// so decode-time dimension stores are visible to `classify()` here.
/// Separate instances defeat the `.media` fast-path.
///
/// Thread safety: `diff()` must not be called concurrently. In production
/// `RenderDiffer` is owned by `FeedScrollView` (a @MainActor type); all calls
/// are on the main actor. `@unchecked Sendable` lets it be passed into
/// actor-isolated closures without copying — the single-owner contract is
/// enforced by the owning isolation context, mirroring `TextMeasurementContext`.
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

    /// - Parameter dimensionCache: Shared cache for the `.media` classify fast-path.
    ///   Must be the same instance as `ImageActor.dimensionCache` per the DI contract
    ///   (DimensionCache.swift:11–17). Pass `nil` to disable the `.media` path (all
    ///   image-URL changes will classify as `.layout`). Omitting this parameter is
    ///   intentionally not supported — pass `env.dimensionCache` or `nil` explicitly
    ///   so the choice is visible at each call site.
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

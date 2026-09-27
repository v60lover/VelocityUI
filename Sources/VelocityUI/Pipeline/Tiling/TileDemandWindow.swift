// TileDemandWindow.swift

/// Tile indices whose `TileRange` intersects `visibleExtent` (the block-local viewport
/// window -- rows or points currently on screen). Computed purely from `tileRanges`, with no
/// dependence on which tiles happen to be mounted right now -- acceptance criterion 4: logical
/// geometry (and, by extension, hit testing and accessibility built on it) stays independent
/// of tile raster residency.
///
/// `tileRanges` must be sorted ascending and non-overlapping (the shape `subdivideIntoTiles`
/// always produces), which lets this binary-search instead of linear-scan (bead-implement
/// Section 11 -- no O(n) `first(where:)` once this sits behind a hot path).
public nonisolated func visibleTileIndices(
    tileRanges: [TileRange],
    visibleExtent: TileRange
) -> Range<Int> {
    guard !visibleExtent.isEmpty, !tileRanges.isEmpty else { return 0..<0 }

    var lo = 0
    var hi = tileRanges.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if tileRanges[mid].upperBound <= visibleExtent.lowerBound {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    guard lo < tileRanges.count, tileRanges[lo].intersects(visibleExtent) else { return 0..<0 }

    var upper = lo + 1
    while upper < tileRanges.count, tileRanges[upper].intersects(visibleExtent) {
        upper += 1
    }
    return lo..<upper
}

/// Which tile indices must have mounted (heavy) raster right now, given the tiles currently
/// intersecting the viewport and a symmetric prefetch bound -- acceptance criterion 3, the
/// "mount" half. Pure arithmetic over indices, same cost class as `WorkingRange`'s ring-buffer
/// bookkeeping, so a caller can run this on the synchronous scroll path.
public nonisolated func tileDemandWindow(
    visibleTileRange: Range<Int>,
    tileCount: Int,
    prefetchBound: Int
) -> Range<Int> {
    guard tileCount > 0, !visibleTileRange.isEmpty else { return 0..<0 }
    let lower = max(0, visibleTileRange.lowerBound - prefetchBound)
    let upper = min(tileCount, visibleTileRange.upperBound + prefetchBound)
    return lower..<upper
}

/// Tile indices that were in `previous`'s demand window but have left `current`'s -- the
/// "release" half of acceptance criterion 3: their heavy raster must be dropped, even though
/// their logical geometry (via `visibleTileIndices`) stays exactly where it was.
public nonisolated func tilesToRelease(previous: Range<Int>, current: Range<Int>) -> [Int] {
    guard !previous.isEmpty else { return [] }
    return previous.filter { !current.contains($0) }
}

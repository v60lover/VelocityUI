// RasterTileCost.swift

/// Byte cost of one rasterized tile's backing bitmap -- `bytesPerRow * height`, the same
/// formula `RenderPipeline` and `FeedScrollView+Items` already use for `FrozenBitmapStore`
/// inserts. Kept as its own function so a tile-cost call site and an image-cost call site
/// can't silently drift (bead-implement Section 3 -- cross-site consistency).
public nonisolated func rasterByteCost(bytesPerRow: Int, height: Int) -> Int {
    bytesPerRow * height
}

/// One row/line's raster cost, before it has been assigned to a tile.
public struct TileExtentCost: Sendable {
    public let byteCost: Int

    public init(byteCost: Int) {
        self.byteCost = byteCost
    }
}

/// Splits `extents` (one entry per row/line, in block order) into `TileRange`s so that no
/// tile's *combined* byte cost exceeds `maxTileByteCost`.
///
/// A single oversized extent -- a very tall row, or an unbreakable long code line -- becomes
/// its own one-extent tile instead of being folded into a bigger bucket, and that tile reports
/// its true cost even when that cost exceeds `maxTileByteCost`. The ceiling bounds how much
/// gets bundled *together*; it cannot shrink a single already-atomic extent. Acceptance
/// criterion 1's "including an oversized row" case is about this cost being reported honestly
/// (so a downstream byte-accounting consumer sees the real number), not about silently
/// truncating or averaging it away.
///
/// Pure and nonisolated: same `extents` + `maxTileByteCost` always produce the same ranges.
/// Result is sorted, contiguous, and non-overlapping, covering `0..<extents.count` exactly --
/// `visibleTileIndices` relies on that ordering for its binary search.
public nonisolated func subdivideIntoTiles(
    extents: [TileExtentCost],
    maxTileByteCost: Int
) -> [TileRange] {
    guard !extents.isEmpty else { return [] }

    var ranges: [TileRange] = []
    var rangeStart = 0
    var runningCost = 0
    for (index, extent) in extents.enumerated() {
        if runningCost > 0, runningCost + extent.byteCost > maxTileByteCost {
            ranges.append(TileRange(lowerBound: rangeStart, upperBound: index))
            rangeStart = index
            runningCost = 0
        }
        runningCost += extent.byteCost
    }
    ranges.append(TileRange(lowerBound: rangeStart, upperBound: extents.count))
    return ranges
}

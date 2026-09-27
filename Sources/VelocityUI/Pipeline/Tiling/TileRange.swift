// TileRange.swift

/// Which part of a block one tile covers, in block-local raster units -- a row index for a
/// table, or an integer point/pixel offset for a paragraph or code body. The unit is fixed by
/// whoever cuts the block into tiles (`subdivideIntoTiles`), not by `TileRange` itself.
///
/// Half-open, like a Swift `Range`: `upperBound` is exclusive. A whole-block raster is the
/// single range `0..<extentCount`. Generalises `RasterIdentity.tileRange` from
/// `docs/STREAMING_DOCUMENT_CONTRACTS.md` section 3.4.
public struct TileRange: Sendable, Hashable {
    public let lowerBound: Int
    public let upperBound: Int

    /// `lowerBound == upperBound` is a valid, empty range -- a degenerate tile over zero
    /// extents, not an error.
    public init(lowerBound: Int, upperBound: Int) {
        precondition(lowerBound <= upperBound, "TileRange requires lowerBound <= upperBound")
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var length: Int { upperBound - lowerBound }
    public var isEmpty: Bool { length == 0 }

    public func intersects(_ other: TileRange) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }
}

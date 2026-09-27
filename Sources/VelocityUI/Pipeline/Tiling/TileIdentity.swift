// TileIdentity.swift

import CoreGraphics

/// What one tile's pixels were drawn for -- `RasterIdentity` from
/// `docs/STREAMING_DOCUMENT_CONTRACTS.md` section 3.4, generalised over whatever
/// content/layout token the caller already tracks (`Token`) instead of hard-coding
/// `BlockLifetime` + `ContentRevision` + width + scale + style, which beads `ln1g.3`/`ln1g.4`
/// haven't landed yet. A caller with those types in hand -- or today's
/// `CodeBodyRasterIdentity` -- supplies `Token` directly; the "old generation can't paint"
/// guarantee below holds regardless of what `Token` turns out to be.
public struct TileIdentity<Token: Sendable & Equatable>: Sendable, Equatable {
    public let contentIdentity: Token
    public let tileRange: TileRange

    public init(contentIdentity: Token, tileRange: TileRange) {
        self.contentIdentity = contentIdentity
        self.tileRange = tileRange
    }
}

extension TileIdentity: Hashable where Token: Hashable {}

/// A finished tile raster, tagged with the identity it was drawn for. `@unchecked Sendable`
/// because `CGImage` itself doesn't conform -- mirroring `StoredBitmapArtifact`'s
/// justification (`FrozenBitmapStore.swift`): callers never mutate a `CGImage`'s backing
/// storage once created, so sharing it across isolation domains is safe.
public struct TileRenderResult<Token: Sendable & Equatable>: @unchecked Sendable {
    public let identity: TileIdentity<Token>
    public let image: CGImage

    public init(identity: TileIdentity<Token>, image: CGImage) {
        self.identity = identity
        self.image = image
    }
}

/// Drops a tile render whose identity no longer matches the block's current identity --
/// acceptance criterion 2, "old generations cannot paint into a new layout". Returns the
/// image only when the delivered tile's full identity (content/layout token *and* tile range)
/// still equals what's currently live for that slot; the caller applies the image only in
/// that case, and otherwise falls back to whatever it already has mounted (or a placeholder).
public nonisolated func mountIfCurrent<Token: Sendable & Equatable>(
    _ result: TileRenderResult<Token>,
    currentIdentity: TileIdentity<Token>
) -> CGImage? {
    result.identity == currentIdentity ? result.image : nil
}

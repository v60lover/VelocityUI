// MathBlockNode.swift

import Foundation

/// A block LaTeX formula (`$$...$$` / `\[...\]`): its own centered block, mirroring
/// `CodeBlockNode`/`MarkdownTableNode`.
///
/// `flatten()` preserves this as one direct math leaf. Rasterization (SwaTex) and Variant B
/// horizontal scroll on overflow run downstream of `descriptor`.
public struct MathBlockNode: RenderNode {
    public let rawTeX: String
    /// Drives both the literal-text fallback font and SwaTex's `RenderOptions.fontSize`.
    public let font: VFontDescriptor
    /// Foreground color for both the formula ink and the literal-text fallback.
    public let color: VColorDescriptor
    public let blockID: BlockID?
    public let blockLifecycle: BlockLifecycle

    public init(
        rawTeX: String,
        font: VFontDescriptor = MathBlockNode.defaultFont,
        color: VColorDescriptor = .primary,
        blockID: BlockID? = nil,
        blockLifecycle: BlockLifecycle = .positional
    ) {
        self.rawTeX = rawTeX
        self.font = font
        self.color = color
        self.blockID = blockID
        self.blockLifecycle = blockLifecycle
    }

    public static let defaultFont = VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight)

    /// Covers `rawTeX`, `font.size`, and hot-ness -- SwaTex's layout depends only on the TeX
    /// source and the target font size, not weight/family/traits (meaningless to a math
    /// typesetter), so those are appearance-only here, the same content-and-font split
    /// `CodeBlockNode.layoutHash` uses. Hot-ness must fold in too: at seal `rawTeX` is unchanged
    /// (only the trailing `$$`, never part of the body, is stripped), so without it the
    /// literal-to-formula transition looks like "unchanged" to block diffing and never re-rasters.
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(rawTeX)
        h.combine(font.size)
        h.combine(blockLifecycle == .hot)
        return h.finalize()
    }

    public var appearanceHash: Int {
        var h = Hasher()
        h.combine(color)
        return h.finalize()
    }

    var descriptor: MathBlockDescriptor {
        MathBlockDescriptor(
            rawTeX: rawTeX,
            font: font,
            color: color,
            blockID: blockID,
            lifecycle: blockLifecycle,
            layoutHash: layoutHash,
            appearanceHash: appearanceHash
        )
    }
}

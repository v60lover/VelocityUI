// FrameSpec.swift

import Foundation
import CoreGraphics

// MARK: - FrameSpec

/// Geometry request from `.frame(width:height:alignment:)`: an explicit slot size (either or
/// both dimensions) plus alignment for when the slot is larger than the content.
///
/// Pure data, no behaviour — slot resolution happens in `LayoutEngine.applyFrame` at measure
/// time. A `nil` dimension is "unspecified" — falls back to intrinsic size on that axis.
public struct FrameSpec: Hashable, Sendable {
    public let width: CGFloat?
    public let height: CGFloat?
    public let alignment: VAlignment

    public init(width: CGFloat? = nil, height: CGFloat? = nil, alignment: VAlignment = .center) {
        self.width = width
        self.height = height
        self.alignment = alignment
    }

    /// The zero-cost default: no dimension constrained, center alignment. `NodeTable.frame(at:)`
    /// returns this for any node that was never `.frame()`-wrapped, so callers can treat
    /// "unframed" and "framed with nothing set" identically without a separate Optional check.
    public static let unspecified = FrameSpec(width: nil, height: nil, alignment: .center)

    /// True when at least one dimension is constrained. A `FrameSpec` with only a non-default
    /// alignment but no width/height is inert — there's no larger slot to align content within.
    public var isSpecified: Bool { width != nil || height != nil }

    /// Merge rule for nested `.frame().frame()` chains. `inner` is closer to the content. Per
    /// dimension, inner wins if it specifies that axis, else outer falls through — matches SwiftUI's
    /// nested-`.frame()` behaviour. Alignment: inner wins whenever `inner.isSpecified`, else outer applies.
    public static func merge(inner: FrameSpec, outer: FrameSpec) -> FrameSpec {
        FrameSpec(
            width: inner.width ?? outer.width,
            height: inner.height ?? outer.height,
            alignment: inner.isSpecified ? inner.alignment : outer.alignment
        )
    }
}

// MARK: - FrameModifierNode

/// Transparent Layer-1-only wrapper produced by `.frame(width:height:alignment:)`.
///
/// Deliberately NOT a `NodeKind` case — modifier nodes fold into their target's layout
/// contribution instead of becoming their own flat-table entry. `flatten()` unwraps the chain and
/// records the merged `FrameSpec` in `NodeTable.frames`. Must never reach past `flatten()`.
public struct FrameModifierNode: RenderNode {
    /// The wrapped node. Existential because the wrapper is generic over "any RenderNode",
    /// same erasure boundary as `VStackNode.children` — resolved away by `flatten()`.
    public let content: any RenderNode
    public let spec: FrameSpec

    /// Framing is geometry, so it folds into `layoutHash` alongside the wrapped content's own
    /// `layoutHash` — a `.frame()` change must miss `CacheKey` and force `LayoutCache` to re-measure.
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(spec.width)
        h.combine(spec.height)
        h.combine(spec.alignment)
        h.combine(content.layoutHash)
        return h.finalize()
    }

    /// Framing never affects paint, only the slot content is measured/placed into. `appearanceHash`
    /// passes through unchanged so a `.frame()` change is never mistaken for a repaint-only update.
    public var appearanceHash: Int { content.appearanceHash }
}

// MARK: - .frame() modifier

extension RenderNode {
    /// Constrains this node's layout slot to `width`/`height` (`nil` = keep intrinsic on that axis).
    ///
    /// `alignment` only applies when the slot is LARGER than the content (letterbox case) — when
    /// smaller, the slot wins and content clips. `AsyncImage` with `contentMode: .fill` fills the
    /// slot instead of aligning within it.
    ///
    /// - Important: erases the node to `FrameModifierNode` — apply type-specific modifiers
    ///   (`TextNode.font`, `AsyncImageNode.cornerRadius`, etc.) BEFORE `.frame()`, since they're
    ///   undefined afterward.
    public func frame(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        alignment: VAlignment = .center
    ) -> FrameModifierNode {
        FrameModifierNode(content: self, spec: FrameSpec(width: width, height: height, alignment: alignment))
    }
}

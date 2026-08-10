// FrameSpec.swift

import Foundation
import CoreGraphics

// MARK: - FrameSpec

/// A geometry request produced by `.frame(width:height:alignment:)`: an explicit slot
/// size (either or both dimensions), plus how content is aligned within that slot when
/// the slot is larger than the content's intrinsic size.
///
/// `FrameSpec` is pure data — it carries no behaviour. The actual slot resolution
/// (center/align when slot > content, clip when slot < content, image `.fill` semantics)
/// happens in `LayoutEngine.applyFrame` at measure time (see VelocityUI-rsg). Keeping
/// this type behaviour-free is what lets it fold cleanly into `layoutHash` — it is
/// itself `Hashable`, so `FrameModifierNode.layoutHash` can hash it directly.
///
/// A dimension left `nil` is "unspecified" — the framed node falls back to its
/// intrinsic size on that axis, exactly as if `.frame()` had not been applied there.
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

    /// True when at least one dimension is constrained. Callers use this to decide whether
    /// framing changes measurement at all — a `FrameSpec` with only a non-default alignment
    /// but no width/height is inert (there is no larger slot to align content within).
    public var isSpecified: Bool { width != nil || height != nil }

    /// Merge rule for nested `.frame().frame()` chains (rare but legal — see
    /// `RenderNode.frame(width:height:alignment:)` below). `inner` is the frame closer to
    /// the content (evaluated first, deeper in the modifier chain); `outer` wraps it.
    ///
    /// Per dimension: the INNER spec wins if it specifies that dimension; otherwise the
    /// outer spec's value (possibly also nil) falls through. This matches SwiftUI's
    /// nested-`.frame()` behaviour, where the innermost explicit size for a given axis is
    /// authoritative and an outer `.frame()` only fills in axes the inner frame left open.
    ///
    /// Alignment does not merge per-axis (it is a single enum, not two optionals): the
    /// inner alignment wins outright whenever the inner spec is otherwise specified
    /// (`inner.isSpecified`), since that is the frame actually establishing a sizing
    /// context to align within. If the inner spec specifies nothing, its alignment is
    /// meaningless (no slot for it to act on) and the outer alignment applies instead.
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
/// This is deliberately NOT a `NodeKind` case. Per the Flattener rule (Flattener.swift:13),
/// modifier nodes fold into their target's layout contribution rather than becoming their
/// own flat-table entry — that keeps `NodeKind` closed/exhaustive and avoids a per-node
/// heap box for something that carries no renderable content of its own. `flatten()`
/// (VelocityUI-dv7) unwraps any `FrameModifierNode` chain before appending the wrapped
/// node's `NodeKind`, and records the merged `FrameSpec` in `NodeTable.frames` at the
/// wrapped node's index. `FrameModifierNode` itself must never reach past `flatten()`.
public struct FrameModifierNode: RenderNode {
    /// The wrapped node. Existential because the wrapper is generic over "any RenderNode",
    /// same erasure boundary as `VStackNode.children` — resolved away by `flatten()`.
    public let content: any RenderNode
    public let spec: FrameSpec

    /// Framing is geometry, so it folds into `layoutHash` alongside the wrapped content's
    /// own `layoutHash` — a `.frame()` change must produce a different `NodeTable.layoutHash`
    /// so `CacheKey` misses and `LayoutCache` re-measures (see epic VelocityUI-j4z).
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(spec.width)
        h.combine(spec.height)
        h.combine(spec.alignment)
        h.combine(content.layoutHash)
        return h.finalize()
    }

    /// Framing never affects paint — it only affects the slot content is measured/placed
    /// into. `appearanceHash` passes through unchanged so a `.frame()` change is never
    /// mistaken for a repaint-only update by the appearance-only fast path.
    public var appearanceHash: Int { content.appearanceHash }
}

// MARK: - .frame() modifier

extension RenderNode {
    /// Constrains this node's layout slot to `width`/`height` (either or both may be left
    /// `nil` for "keep intrinsic on that axis"), available uniformly on every `RenderNode` —
    /// `Text`, `AsyncImage`, `VStack`/`HStack`/`ZStack`, and future GIF/Video/Hosting nodes.
    ///
    /// Frozen semantics (see epic VelocityUI-j4z): `alignment` positions content within the
    /// slot only when the slot is LARGER than the node's intrinsic content on that axis
    /// (the padding/letterbox case); when the slot is SMALLER, the slot wins and content is
    /// clipped at the slot bounds. An `AsyncImage` with `contentMode: .fill` fills the framed
    /// slot instead of being aligned/letterboxed within it.
    ///
    /// - Important: `.frame()` erases the concrete node type to `FrameModifierNode` (its
    ///   `content` is `any RenderNode`). Type-specific chainable modifiers — `TextNode.font`,
    ///   `TextNode.lineLimit`, `AsyncImageNode.cornerRadius`, etc. — must be applied BEFORE
    ///   `.frame()`, not after, since they are not defined on `FrameModifierNode`.
    public func frame(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        alignment: VAlignment = .center
    ) -> FrameModifierNode {
        FrameModifierNode(content: self, spec: FrameSpec(width: width, height: height, alignment: alignment))
    }
}

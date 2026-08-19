// Fragment.swift

import Foundation
import CoreGraphics

// MARK: - Types

public enum FragmentContent: Sendable {
    case image(ImageDescriptor)
    case text(TextDescriptor)
    /// Spacer, hosting, gif, video, customLayer — frame only, no renderable content in Phase 1.
    case geometry
}

/// A flat render instruction produced by extractFragments.
///
/// id is the node's index in NodeTable.nodes — stable across re-measures of the
/// same NodeTable. RenderCell uses this to route applyContent(id:image:) to the
/// correct sublayer without re-scanning the layout tree.
///
/// Array order = z-order (back to front), matching ZStack semantics.
public struct Fragment: Sendable {
    public let id: Int
    /// Optional stable identity propagated from a `.renderID(...)` modifier.
    public let blockID: BlockID?
    public let content: FragmentContent
    /// Absolute frame in cell coordinates (origin relative to the cell's top-left corner).
    public let frame: CGRect

    public init(id: Int, blockID: BlockID? = nil, content: FragmentContent, frame: CGRect) {
        self.id = id
        self.blockID = blockID
        self.content = content
        self.frame = frame
    }
}

// MARK: - Post-pass extraction

/// Walks a ResolvedLayout tree alongside its NodeTable and produces a flat, ordered list
/// of Fragments with absolute frames in cell coordinates.
///
/// - Containers (vstack/hstack/zstack) contribute no Fragment, only resolve child
///   coordinate spaces. Leaf nodes (image, text, spacer, hosting, gif, video, customLayer)
///   each produce one.
/// - Array order = z-order (earlier = back, later = front), matching ZStack draw order.
public nonisolated func extractFragments(table: NodeTable, layout: ResolvedLayout) -> [Fragment] {
    var result: [Fragment] = []
    // clip starts nil: an unframed tree never establishes a slot to clip against, so this
    // stays nil the entire recursion and the `if let clip` intersection below never runs —
    // byte-identical fragment output to the pre-clip behavior for every unframed row.
    collectFragments(table: table, layout: layout, parentOrigin: .zero, clip: nil, into: &result)
    return result
}

// MARK: - Private

/// `clip`, when non-nil, is an absolute rect (cell coordinates, same space as `Fragment.frame`)
/// every descendant fragment must intersect before emission. Set on crossing a FRAMED container
/// (VelocityUI-983) and narrows — never widens — through nested framed containers via
/// `clip.map { $0.intersection(slotAbs) } ?? slotAbs`.
///
/// Why: `applyFrame` clamps a framed container's own `totalFrame` to the slot, but an UNFRAMED
/// descendant leaf can still measure larger on its own axis (e.g. an unframed `.image`'s
/// intrinsic `width / aspectRatio` height) — nothing else clamps raw children to the container's
/// bounds. Since `RenderCell` never sets `masksToBounds` (reserved for corner-radius rounding,
/// not layout clipping), an unclipped leaf paints past the cell edge and over neighboring cells
/// — visible as "expand"/glitch on scroll-up. This is a geometry clip on the emitted `CGRect`,
/// not a pixel crop — `contentMode` still governs on-leaf drawing.
private nonisolated func collectFragments(
    table: NodeTable,
    layout: ResolvedLayout,
    parentOrigin: CGPoint,
    clip: CGRect?,
    into result: inout [Fragment]
) {
    let nodeIndex = layout.nodeIndex
    guard nodeIndex >= 0, nodeIndex < table.nodes.count else { return }

    // Children's frames (and a container's own totalFrame) are stored relative to this
    // node's local origin. Shift by parentOrigin to get cell-absolute coordinates.
    let absoluteFrame = layout.totalFrame.offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)

    // Leaves draw at contentFrame when `.frame()` (VelocityUI-rsg) aligned/clamped the
    // content within a slot that differs from totalFrame; contentFrame is nil in the
    // common unframed case, where this is identical to absoluteFrame — byte-identical
    // fragment output for every unframed row. Containers never set contentFrame (they
    // express framing by shifting `children` in `applyFrame` instead), so this value is
    // simply unused on the container branch below.
    let drawFrame = (layout.contentFrame ?? layout.totalFrame).offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)

    // Shared by every leaf case below: intersect against the inherited clip (nil = no-op,
    // the unframed path) and drop the fragment entirely when fully clipped — an empty/null
    // rect is not a degenerate Fragment, it's "nothing to paint here."
    func appendLeaf(_ content: FragmentContent) {
        var frame = drawFrame
        if let clip { frame = frame.intersection(clip) }
        guard !frame.isNull, !frame.isEmpty else { return }
        result.append(Fragment(id: nodeIndex, blockID: table.blockID(at: nodeIndex), content: content, frame: frame))
    }

    switch table.nodes[nodeIndex] {
    case .image(let d):
        appendLeaf(.image(d))
    case .text(let d):
        appendLeaf(.text(d))
    case .spacer, .hosting, .gif, .video, .customLayer:
        appendLeaf(.geometry)
    case .vstack, .hstack, .zstack:
        // A framed container establishes (or further narrows) the clip for everything
        // beneath it — its own absolute slot (absoluteFrame) is exactly what descendants
        // must not paint outside of. An unframed container passes `clip` through unchanged.
        var childClip = clip
        if table.frame(at: nodeIndex).isSpecified {
            childClip = clip.map { $0.intersection(absoluteFrame) } ?? absoluteFrame
        }
        // Container nodes: no fragment. Children are in this container's local space,
        // so pass absoluteFrame.origin (= totalFrame's origin) as their parentOrigin —
        // children were already alignment-shifted in applyFrame, so no double-count.
        for child in layout.children {
            collectFragments(table: table, layout: child, parentOrigin: absoluteFrame.origin, clip: childClip, into: &result)
        }
    }
}

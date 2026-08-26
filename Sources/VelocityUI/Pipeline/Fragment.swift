// Fragment.swift

import Foundation
import CoreGraphics

// MARK: - Types

public enum FragmentContent: Sendable {
    case image(ImageDescriptor)
    case text(TextDescriptor)
    /// A code block's container background — synthesized by `extractFragments`, not present in
    /// `NodeTable`. See `CodeBlockBackgroundDescriptor`.
    case codeBlockBackground(CodeBlockBackgroundDescriptor)
    /// Spacer, hosting, gif, video, customLayer — frame only, no renderable content in Phase 1.
    case geometry
}

/// A flat render instruction produced by extractFragments.
///
/// `id` is the node's index in `NodeTable.nodes` — stays stable across re-measures,
/// so `RenderCell` can route `applyContent(id:image:)` to the right sublayer without
/// re-scanning the layout tree. Array order = z-order (back to front), like ZStack.
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

/// Walks a `ResolvedLayout` tree with its `NodeTable` and flattens it into an ordered
/// list of `Fragment`s with absolute frames in cell coordinates. Containers (vstack/
/// hstack/zstack) produce no fragment of their own, just resolve child coordinates;
/// leaves each produce one.
public nonisolated func extractFragments(table: NodeTable, layout: ResolvedLayout) -> [Fragment] {
    var result: [Fragment] = []
    // clip starts nil — an unframed tree never sets one, so output for unframed rows
    // is unchanged from before clipping was added.
    collectFragments(table: table, layout: layout, parentOrigin: .zero, clip: nil, into: &result)
    return insertingCodeBlockBackgrounds(into: result)
}

/// Synthesizes one background `Fragment` for each adjacent header/body pair produced by
/// `CodeBlockNode`'s expansion (matched via `TextDescriptor.codeBlockRole`), inserted directly
/// before the header so it paints behind both. `CodeBlockNode` can't wrap header/body in a
/// container (see its doc comment) and VelocityUI-qinu's ZStack sibling-size primitive is
/// deliberately parked, so this post-pass is the only place that can add the "behind" layer
/// without touching LayoutEngine — see VelocityUI-oz5q.5's design notes.
///
/// The synthesized fragment's `id` is negative (`-(header.id) - 1`), guaranteed disjoint from
/// every real `NodeTable` index (always >= 0), so it can't collide with any other fragment's
/// identity across recycles.
private nonisolated func insertingCodeBlockBackgrounds(into fragments: [Fragment]) -> [Fragment] {
    var result: [Fragment] = []
    result.reserveCapacity(fragments.count + 1)
    var index = 0
    while index < fragments.count {
        let fragment = fragments[index]
        if case .text(let headerText) = fragment.content,
           case .header(let chrome) = headerText.codeBlockRole,
           index + 1 < fragments.count,
           case .text(let bodyText) = fragments[index + 1].content,
           case .body = bodyText.codeBlockRole {
            result.append(Fragment(
                id: -(fragment.id) - 1,
                content: .codeBlockBackground(CodeBlockBackgroundDescriptor(
                    cornerRadius: chrome.cornerRadius, color: chrome.backgroundColor)),
                frame: fragment.frame.union(fragments[index + 1].frame)
            ))
        }
        result.append(fragment)
        index += 1
    }
    return result
}

// MARK: - Private

/// `clip`, when set, is an absolute rect every descendant fragment must be intersected
/// with before it's emitted. It's set when crossing a framed container and only ever
/// narrows going deeper.
///
/// Why we need this: an unframed leaf (e.g. an image sized by its own aspect ratio) can
/// measure larger than its framed container's slot, and nothing else clamps it. Since
/// `RenderCell` never sets `masksToBounds`, an unclipped leaf paints past the cell edge
/// and over neighboring cells — visible as a glitch on scroll-up. This clips the emitted
/// `CGRect` itself; it doesn't crop pixels, so `contentMode` still governs the drawing.
private nonisolated func collectFragments(
    table: NodeTable,
    layout: ResolvedLayout,
    parentOrigin: CGPoint,
    clip: CGRect?,
    into result: inout [Fragment]
) {
    let nodeIndex = layout.nodeIndex
    guard nodeIndex >= 0, nodeIndex < table.nodes.count else { return }

    // Frames are stored relative to this node's local origin — shift by parentOrigin
    // to get cell-absolute coordinates.
    let absoluteFrame = layout.totalFrame.offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)

    // contentFrame is set when `.frame()` aligned/clamped a leaf within a slot that
    // differs from totalFrame; nil (falls back to totalFrame) in the common unframed
    // case. Containers never set it — they express framing via `children` instead — so
    // it's unused on the container branch below.
    let drawFrame = (layout.contentFrame ?? layout.totalFrame).offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)

    // Intersect against the inherited clip and drop the fragment if fully clipped —
    // an empty rect means "nothing to paint here", not a degenerate Fragment.
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
        // A framed container narrows the clip to its own slot; an unframed one
        // passes the inherited clip through unchanged.
        var childClip = clip
        if table.frame(at: nodeIndex).isSpecified {
            childClip = clip.map { $0.intersection(absoluteFrame) } ?? absoluteFrame
        }
        // No fragment for containers themselves. Children are already alignment-shifted
        // within this container's local space, so pass absoluteFrame.origin as parentOrigin.
        for child in layout.children {
            collectFragments(table: table, layout: child, parentOrigin: absoluteFrame.origin, clip: childClip, into: &result)
        }
    }
}

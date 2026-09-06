// Fragment.swift

import Foundation
import CoreGraphics

// MARK: - Types

public enum FragmentContent: Sendable {
    case image(ImageDescriptor)
    case text(TextDescriptor)
    /// A pre-rounded container background — synthesized by `extractFragments`, not present in
    /// `NodeTable`. Originally a code block's chrome; also reused for a plain text row's
    /// `.roundedBackground(cornerRadius:color:)` (e.g. a chat bubble). See
    /// `CodeBlockBackgroundDescriptor`.
    case codeBlockBackground(CodeBlockBackgroundDescriptor)
    /// A rasterized GFM table (grid lines + cell text baked into one `CGImage`). See
    /// `TableRasterDescriptor`.
    case table(TableRasterDescriptor)
    /// A rasterized block math formula (or its literal-text fallback), baked into one `CGImage`.
    /// See `MathBlockRasterDescriptor`.
    case mathBlock(MathBlockRasterDescriptor)
    /// Spacer, hosting, gif, video, customLayer — frame only, no renderable content in Phase 1.
    case geometry
}

/// Carries a rasterized table's identity/geometry through the Layer 1 → Layer 3 boundary. The
/// pixels themselves arrive later via the same `synchronousContent[id]` channel `.image`/`.text`
/// use — this descriptor only carries what `RenderCell` needs to mount them.
public struct TableRasterDescriptor: Sendable {
    /// The table's full unclipped raster size (`Σ column widths + gridlines`,
    /// `TableRasterizer`'s reported size) — the clamp bound for horizontal scroll. Larger than
    /// `Fragment.frame.size.width` only when the table overflowed its cell and needs scroll.
    public let naturalContentSize: CGSize
    public let layoutHash: Int
    public let appearanceHash: Int

    public init(naturalContentSize: CGSize, layoutHash: Int, appearanceHash: Int) {
        self.naturalContentSize = naturalContentSize
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
    }
}

/// Carries a rasterized math block's identity/geometry through the Layer 1 → Layer 3 boundary,
/// mirroring `TableRasterDescriptor` exactly. `naturalContentSize` is the raster canvas size --
/// `max(formula width, block width)`, already centered at raster time -- the clamp bound for
/// horizontal scroll.
public struct MathBlockRasterDescriptor: Sendable {
    public let naturalContentSize: CGSize
    public let layoutHash: Int
    public let appearanceHash: Int

    public init(naturalContentSize: CGSize, layoutHash: Int, appearanceHash: Int) {
        self.naturalContentSize = naturalContentSize
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
    }
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

/// Walks a `ResolvedLayout` tree with its `NodeTable` and flattens it into an ordered
/// list of `Fragment`s with absolute frames in cell coordinates. Containers (vstack/
/// hstack/zstack) produce no fragment of their own, just resolve child coordinates;
/// leaves each produce one.
public nonisolated func extractFragments(table: NodeTable, layout: ResolvedLayout) -> [Fragment] {
    var result: [Fragment] = []
    // clip starts nil — an unframed tree never sets one, so output for unframed rows
    // is unchanged from before clipping was added.
    collectFragments(table: table, layout: layout, parentOrigin: .zero, clip: nil, into: &result)
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
    func clippedFrame() -> CGRect? {
        var frame = drawFrame
        if let clip { frame = frame.intersection(clip) }
        guard !frame.isNull, !frame.isEmpty else { return nil }
        return frame
    }
    func appendLeaf(_ content: FragmentContent) {
        guard let frame = clippedFrame() else { return }
        result.append(Fragment(id: nodeIndex, blockID: table.blockID(at: nodeIndex), content: content, frame: frame))
    }

    switch table.nodes[nodeIndex] {
    case .codeBlock(let descriptor):
        guard layout.renderPart == nil,
              let background = layout.children.first(where: { $0.renderPart == .codeBackground }),
              let header = layout.children.first(where: { $0.renderPart == .codeHeader }),
              let body = layout.children.first(where: { $0.renderPart == .codeBody })
        else { return }
        result.append(contentsOf: materializeCodeBlockFragments(
            descriptor: descriptor,
            nodeIndex: nodeIndex,
            ownerBlockID: table.blockID(at: nodeIndex),
            backgroundFrame: background.totalFrame.offsetBy(dx: absoluteFrame.minX, dy: absoluteFrame.minY),
            headerFrame: header.totalFrame.offsetBy(dx: absoluteFrame.minX, dy: absoluteFrame.minY),
            bodyFrame: body.totalFrame.offsetBy(dx: absoluteFrame.minX, dy: absoluteFrame.minY),
            clip: clip
        ))
    case .image(let d):
        appendLeaf(.image(d))
    case .text(let d):
        // A row can carry its own pre-rounded backing layer (e.g. a chat bubble) -- synthesize
        // it directly behind the text fragment, sharing the exact same clipped frame (no
        // padding/inset, matching the code card's own header/body-flush-to-background layout).
        // Reuses `.codeBlockBackground`'s content type and RenderCell's already-generic
        // rasterize + 9-patch-stretch rendering verbatim -- nothing code-specific in that path.
        if let chrome = d.backgroundChrome, let frame = clippedFrame() {
            result.append(Fragment(
                id: textBackgroundFragmentID(nodeIndex: nodeIndex),
                blockID: codePartID(owner: table.blockID(at: nodeIndex), nodeIndex: nodeIndex, part: .textBackground),
                content: .codeBlockBackground(CodeBlockBackgroundDescriptor(cornerRadius: chrome.cornerRadius, color: chrome.color)),
                frame: frame
            ))
        }
        appendLeaf(.text(d))
    case .table(let descriptor):
        // `measureNode`'s `.table` case attaches the solved, possibly-overflowing natural
        // content size as a `.tableBody` child (mirrors the code block's `.codeBody` child) --
        // the outer `absoluteFrame` itself stays pinned to the cell width, same as a code card.
        guard layout.renderPart == nil,
              let body = layout.children.first(where: { $0.renderPart == .tableBody })
        else { return }
        appendLeaf(.table(TableRasterDescriptor(
            naturalContentSize: body.totalFrame.size,
            layoutHash: descriptor.layoutHash,
            appearanceHash: descriptor.appearanceHash
        )))
    case .mathBlock(let descriptor):
        // Mirrors `.table` above: `measureNode`'s `.mathBlock` case attaches the natural
        // (possibly overflowing) content size as a `.mathBody` child -- the outer
        // `absoluteFrame` itself stays pinned to the cell width, same as a table.
        guard layout.renderPart == nil,
              let body = layout.children.first(where: { $0.renderPart == .mathBody })
        else { return }
        appendLeaf(.mathBlock(MathBlockRasterDescriptor(
            naturalContentSize: body.totalFrame.size,
            layoutHash: descriptor.layoutHash,
            appearanceHash: descriptor.appearanceHash
        )))
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

/// Positional fallback when the block has no stable `BlockID`.
struct PositionalCodeBlockPartID: Hashable, Sendable {
    let nodeIndex: Int
    let part: RenderPartKind
}

struct OwnedCodeBlockPartID: Hashable, Sendable {
    let owner: BlockID
    let part: RenderPartKind
}

/// Stable owners keep their part identities across sibling insertions.
func codePartID(owner: BlockID?, nodeIndex: Int, part: RenderPartKind) -> BlockID {
    if let owner {
        return BlockID(OwnedCodeBlockPartID(owner: owner, part: part))
    }
    return BlockID(PositionalCodeBlockPartID(nodeIndex: nodeIndex, part: part))
}

/// Synthetic ids are negative and disjoint from real `NodeTable` indices. A given `nodeIndex` is
/// never both a `.codeBlock` and a `.text` node, so `textBackgroundFragmentID` sharing the same
/// `nodeIndex * 3 + n` scheme as the code-block ids below can't collide with them.
func codeBackgroundFragmentID(nodeIndex: Int) -> Int { -(nodeIndex * 3 + 1) }
func codeHeaderFragmentID(nodeIndex: Int) -> Int { -(nodeIndex * 3 + 2) }
func textBackgroundFragmentID(nodeIndex: Int) -> Int { -(nodeIndex * 3 + 3) }

/// Produces one atomic `[background, header, body]` code-card paint plan.
/// A visible card keeps all three fragments even when an individual part is empty or clipped.
func materializeCodeBlockFragments(
    descriptor: CodeBlockDescriptor,
    nodeIndex: Int,
    ownerBlockID: BlockID?,
    backgroundFrame: CGRect,
    headerFrame: CGRect,
    bodyFrame: CGRect,
    clip: CGRect? = nil
) -> [Fragment] {
    let parts: [(RenderPartKind, Int, FragmentContent, CGRect)] = [
        (.codeBackground, codeBackgroundFragmentID(nodeIndex: nodeIndex), .codeBlockBackground(CodeBlockBackgroundDescriptor(cornerRadius: descriptor.chrome.cornerRadius, color: descriptor.chrome.backgroundColor)), backgroundFrame),
        (.codeHeader, codeHeaderFragmentID(nodeIndex: nodeIndex), .text(descriptor.headerText), headerFrame),
        (.codeBody, nodeIndex, .text(descriptor.bodyText), bodyFrame),
    ]
    if let clip {
        let visibleBackground = backgroundFrame.intersection(clip)
        guard !visibleBackground.isNull, !visibleBackground.isEmpty else { return [] }
    }
    return parts.map { part, id, content, frame in
        let visibleFrame: CGRect
        if let clip {
            let intersection = frame.intersection(clip)
            visibleFrame = intersection.isNull ? CGRect(origin: clip.origin, size: .zero) : intersection
        } else {
            visibleFrame = frame
        }
        return Fragment(
            id: id,
            blockID: codePartID(owner: ownerBlockID, nodeIndex: nodeIndex, part: part),
            content: content,
            frame: visibleFrame
        )
    }
}

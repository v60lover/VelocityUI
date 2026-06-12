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
    public let content: FragmentContent
    /// Absolute frame in cell coordinates (origin relative to the cell's top-left corner).
    public let frame: CGRect
}

// MARK: - Post-pass extraction

/// Walks a ResolvedLayout tree alongside its NodeTable and produces a flat,
/// ordered list of Fragments with absolute frames in cell coordinates.
///
/// Container nodes (vstack, hstack, zstack) contribute no Fragment of their own —
/// they only resolve coordinate spaces for their children. Leaf nodes (image, text,
/// spacer, hosting, gif, video, customLayer) each produce one Fragment.
///
/// Z-order for overlapping fragments: array index mirrors ZStack draw order
/// (earlier = further back, later = further front).
public nonisolated func extractFragments(table: NodeTable, layout: ResolvedLayout) -> [Fragment] {
    var result: [Fragment] = []
    collectFragments(table: table, layout: layout, parentOrigin: .zero, into: &result)
    return result
}

// MARK: - Private

private nonisolated func collectFragments(
    table: NodeTable,
    layout: ResolvedLayout,
    parentOrigin: CGPoint,
    into result: inout [Fragment]
) {
    let nodeIndex = layout.nodeIndex
    guard nodeIndex >= 0, nodeIndex < table.nodes.count else { return }

    // Children's frames are stored relative to this node's local origin.
    // Shift by parentOrigin to get cell-absolute coordinates.
    let absoluteFrame = layout.totalFrame.offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)

    switch table.nodes[nodeIndex] {
    case .image(let d):
        result.append(Fragment(id: nodeIndex, content: .image(d), frame: absoluteFrame))
    case .text(let d):
        result.append(Fragment(id: nodeIndex, content: .text(d), frame: absoluteFrame))
    case .spacer, .hosting, .gif, .video, .customLayer:
        result.append(Fragment(id: nodeIndex, content: .geometry, frame: absoluteFrame))
    case .vstack, .hstack, .zstack:
        // Container nodes: no fragment. Children are in this container's local space,
        // so pass absoluteFrame.origin as their parentOrigin.
        for child in layout.children {
            collectFragments(table: table, layout: child, parentOrigin: absoluteFrame.origin, into: &result)
        }
    }
}

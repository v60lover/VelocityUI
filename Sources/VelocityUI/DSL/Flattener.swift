// Flattener.swift

import Foundation
import CoreGraphics

/// Converts a Layer 1 DSL tree into a flat, existential-free NodeTable at the Layer 1/2 boundary.
///
/// @MainActor: DSL node children arrays are Layer-1-internal and accessed only here.
/// After this call, zero `any RenderNode` references exist in or past the returned NodeTable.
///
/// All existential type tests are concentrated in the single `switch` inside `visit`.
/// Adding a new DSL node type requires only adding a case there — nowhere else.
/// Modifier nodes (padding etc.) should fold into their target descriptor's layout contribution
/// at measure time rather than becoming NodeKind cases — keeps NodeKind closed and exhaustive.
@MainActor
public func flatten<ID: Hashable & Sendable>(_ root: any RenderNode, itemID: ID) -> NodeTable {
    var nodes: [NodeKind] = []
    var parentIndices: [Int] = []
    // Sparse — only indices that were actually `.frame()`-wrapped get an entry. Kept empty
    // (not even reserved) in the common unframed case so the final `frames` array collapses
    // to `nil` and NodeTable never allocates a [FrameSpec] for unframed cells.
    var frameByIndex: [Int: FrameSpec] = [:]

    func visit(_ node: any RenderNode, parent: Int) {
        // Unwrap any FrameModifierNode chain BEFORE the unconditional appends below.
        // FrameModifierNode is transparent: it contributes no NodeKind and no
        // parentIndices entry of its own — the wrapped concrete node lands at `myIndex`
        // with `parent` as ITS parent, exactly as if `.frame()` had never been called.
        //
        // Traversal visits the OUTERMOST `.frame()` first (it's what `node` is bound to
        // on entry) and walks toward content via `f.content`, so each subsequent iteration
        // is strictly closer to content than everything merged so far. Per the merge
        // contract from #1 ("a specified dimension on the INNER, closer-to-content frame
        // wins"), the newly-unwrapped frame at each step is the one closer to content —
        // it must be passed as `inner`, with the previously-accumulated (shallower, more
        // outer) `spec` passed as `outer`. Verified against `.frame(width:100).frame(width:200)`
        // (inner=100, outer=200): `merge(inner: f.spec, outer: spec)` resolves to width=100
        // as the contract requires; the naively-symmetric `merge(inner: spec, outer: f.spec)`
        // would silently let the outer frame win instead — do not swap this back.
        var node = node
        var spec = FrameSpec.unspecified
        while let f = node as? FrameModifierNode {
            spec = FrameSpec.merge(inner: f.spec, outer: spec)
            node = f.content
        }

        let myIndex = nodes.count
        parentIndices.append(parent)
        if spec.isSpecified { frameByIndex[myIndex] = spec }
        switch node {
        case let n as VStackNode:
            nodes.append(.vstack(VStackDescriptor(
                alignment: n.alignment.rawValue, spacing: n.spacing,
                layoutHash: n.layoutHash, appearanceHash: n.appearanceHash)))
            for child in n.children { visit(child, parent: myIndex) }
        case let n as HStackNode:
            nodes.append(.hstack(HStackDescriptor(
                alignment: n.alignment.rawValue, spacing: n.spacing,
                layoutHash: n.layoutHash, appearanceHash: n.appearanceHash)))
            for child in n.children { visit(child, parent: myIndex) }
        case let n as ZStackNode:
            nodes.append(.zstack(ZStackDescriptor(
                alignment: n.alignment.rawValue,
                layoutHash: n.layoutHash, appearanceHash: n.appearanceHash)))
            for child in n.children { visit(child, parent: myIndex) }
        case let n as SpacerNode:
            nodes.append(.spacer(n.minLength ?? 0))
        case let n as TextNode:
            nodes.append(.text(TextDescriptor(
                content: n.content, font: n.font, color: n.color,
                lineLimit: n.lineLimit, lineBreakMode: n.lineBreakMode.rawValue,
                layoutHash: n.layoutHash, appearanceHash: n.appearanceHash)))
        case let n as AsyncImageNode:
            nodes.append(.image(ImageDescriptor(
                url: n.url, aspectRatio: n.aspectRatio,
                contentMode: n.contentMode.rawValue, cornerRadius: n.cornerRadius,
                layoutHash: n.layoutHash, appearanceHash: n.appearanceHash,
                thumbnailData: n.thumbnailData, blurHash: n.blurHash,
                customPlaceholderPayload: n.customPlaceholderPayload)))
        default:
            // GIF / Video / Hosting DSL nodes are Phase 3–4; add a case here when they land.
            // Unknown user-defined RenderNode types are not supported in Phase 1 — use RenderView.
            assertionFailure("flatten: unknown DSL node \(type(of: node)) — add a case to visit(_:parent:)")
            nodes.append(.spacer(0))
        }
    }

    visit(root, parent: -1)

    // nil (not an all-`.unspecified` array) when nothing in the tree was framed — this is
    // the zero-cost unframed path NodeTable.frame(at:) and measureNode rely on: no
    // [FrameSpec] allocation, single predicted nil-check branch.
    let frames: [FrameSpec]? = frameByIndex.isEmpty
        ? nil
        : (0..<nodes.count).map { frameByIndex[$0] ?? .unspecified }

    return NodeTable(
        itemID: itemID,
        nodes: nodes,
        parentIndices: parentIndices,
        layoutHash: root.layoutHash,
        appearanceHash: root.appearanceHash,
        frames: frames
    )
}

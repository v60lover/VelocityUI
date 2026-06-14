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

    func visit(_ node: any RenderNode, parent: Int) {
        let myIndex = nodes.count
        parentIndices.append(parent)
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
                layoutHash: n.layoutHash, appearanceHash: n.appearanceHash)))
        default:
            // GIF / Video / Hosting DSL nodes are Phase 3–4; add a case here when they land.
            // Unknown user-defined RenderNode types are not supported in Phase 1 — use RenderView.
            assertionFailure("flatten: unknown DSL node \(type(of: node)) — add a case to visit(_:parent:)")
            nodes.append(.spacer(0))
        }
    }

    visit(root, parent: -1)

    return NodeTable(
        itemID: itemID,
        nodes: nodes,
        parentIndices: parentIndices,
        layoutHash: root.layoutHash,
        appearanceHash: root.appearanceHash
    )
}

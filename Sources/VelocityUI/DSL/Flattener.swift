// Flattener.swift

import Foundation
import CoreGraphics

/// Converts a Layer 1 DSL tree into a flat, existential-free NodeTable at the Layer 1/2 boundary.
/// Only this call touches Layer-1-internal DSL children arrays; after it, zero `any RenderNode`
/// references exist in or past the returned table.
///
/// All existential type tests live in the single `switch` inside `visit` — a new DSL node type
/// only needs a case there. Modifier nodes (padding etc.) should fold into their target
/// descriptor's layout contribution at measure time, not become NodeKind cases.
///
/// - Parameter contentSizeCategory: Dynamic Type category baked into every `TextDescriptor`
///   (VelocityUI-ezo.2.5). `flatten()` is the only `@MainActor` boundary aware of the live
///   trait environment, so it's where this enters the pipeline. Default `.unspecified`
///   preserves prior behavior exactly. Folds into `NodeTable.layoutHash` only when the tree
///   contains a text node — see `sawText` below for why unconditional folding would be wrong.
@MainActor
public func flatten<ID: Hashable & Sendable>(
    _ root: any RenderNode,
    itemID: ID,
    contentSizeCategory: VContentSizeCategory = .unspecified
) -> NodeTable {
    var nodes: [NodeKind] = []
    var parentIndices: [Int] = []
    // Sparse — only indices that were actually `.frame()`-wrapped get an entry. Kept empty
    // (not even reserved) in the common unframed case so the final `frames` array collapses
    // to `nil` and NodeTable never allocates a [FrameSpec] for unframed cells.
    var frameByIndex: [Int: FrameSpec] = [:]
    // Set the first time a TextNode is visited. Gates whether contentSizeCategory folds into
    // the returned NodeTable's top-level layoutHash (see the call site below for why this
    // matters: unconditionally folding it in would make classify() misclassify category-blind,
    // pure-image trees as `.media` instead of `.none` on every Dynamic Type change).
    var sawText = false

    func visit(_ node: any RenderNode, parent: Int) {
        // Unwrap the FrameModifierNode chain (transparent: contributes no NodeKind/parentIndices
        // entry of its own — the wrapped node lands at `myIndex` with `parent`, as if `.frame()`
        // never wrapped it).
        //
        // Traversal hits the OUTERMOST `.frame()` first and walks toward content, so each step
        // is closer to content than what's merged so far. Per the "inner (closer-to-content)
        // wins" merge contract, the newly-unwrapped frame is `inner` and the accumulated `spec`
        // is `outer`. Verified: `.frame(width:100).frame(width:200)` → `merge(inner: f.spec,
        // outer: spec)` resolves width=100 correctly; swapping the args would let the outer
        // frame win instead — do not swap this back.
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
            sawText = true
            nodes.append(.text(TextDescriptor(
                content: n.content, font: n.font, color: n.color,
                lineLimit: n.lineLimit, lineBreakMode: n.lineBreakMode.rawValue,
                underlineStyle: n.underlineStyle.rawValue, strikethroughStyle: n.strikethroughStyle.rawValue,
                kerning: n.kerning, lineSpacing: n.lineSpacing,
                contentSizeCategory: contentSizeCategory,
                layoutHash: combineHash(n.layoutHash, contentSizeCategory), appearanceHash: n.appearanceHash)))
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

    // sawText gate: a category-blind (pure-image/spacer/container) tree must keep byte-identical
    // layoutHash across categories — folding it in unconditionally would make classify()'s
    // tier-1 fast path miss on every Dynamic Type change even though nothing in the tree
    // actually depends on the category, and its tier-3 walk would then find no node differing
    // and misclassify the whole item as `.media` instead of `.none`. See the flatten() doc.
    let tableLayoutHash = sawText ? combineHash(root.layoutHash, contentSizeCategory) : root.layoutHash

    return NodeTable(
        itemID: itemID,
        nodes: nodes,
        parentIndices: parentIndices,
        layoutHash: tableLayoutHash,
        appearanceHash: root.appearanceHash,
        frames: frames
    )
}

/// Combines a DSL-level layoutHash with the Dynamic Type category `flatten()` was called with.
/// Used for both the table's top-level layoutHash (gated by `sawText`) and each `.text` node's
/// own `TextDescriptor.layoutHash`.
///
/// `.unspecified` is a true identity transform — returns `layoutHash` verbatim, not just an
/// equal-valued mix — so callers that never opt into Dynamic Type get byte-identical output to
/// pre-ezo.2.5 (`testFlatten_textDescriptor_carriesNodeHashes`,
/// `testFlatten_tableHashes_matchRootNode` assert exact, not cross-call, equality).
private func combineHash(_ layoutHash: Int, _ category: VContentSizeCategory) -> Int {
    guard category != .unspecified else { return layoutHash }
    var h = Hasher()
    h.combine(layoutHash)
    h.combine(category)
    return h.finalize()
}

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
/// - Parameter contentSizeCategory: Dynamic Type category baked into every `TextDescriptor`.
///   `flatten()` is the only `@MainActor` boundary aware of the live trait environment, so it's
///   where this enters the pipeline. Folds into `NodeTable.layoutHash` only when the tree contains
///   a text node — see `sawText` below for why unconditional folding would be wrong.
@MainActor
public func flatten<ID: Hashable & Sendable>(
    _ root: any RenderNode,
    itemID: ID,
    contentSizeCategory: VContentSizeCategory = .unspecified
) -> NodeTable {
    var nodes: [NodeKind] = []
    var parentIndices: [Int] = []
    // Sparse — only `.frame()`-wrapped indices get an entry. Empty in the common unframed case so
    // the final `frames` array collapses to `nil` and NodeTable never allocates for unframed cells.
    var frameByIndex: [Int: FrameSpec] = [:]
    var blockIDByIndex: [Int: BlockID] = [:]
    var blockLifecycleByIndex: [Int: BlockLifecycle] = [:]
    // Set the first time a TextNode is visited. Gates whether contentSizeCategory folds into the
    // top-level layoutHash — unconditional folding would misclassify category-blind, pure-image
    // trees as `.media` instead of `.none` on every Dynamic Type change.
    var sawText = false

    func visit(_ node: any RenderNode, parent: Int) {
        // Unwrap the FrameModifierNode chain (transparent — contributes no NodeKind/parentIndices entry
        // of its own; the wrapped node lands at `myIndex` as if `.frame()` never wrapped it).
        //
        // Traversal hits the OUTERMOST `.frame()` first, so the newly-unwrapped frame is `inner` (closer
        // to content) and the accumulated `spec` is `outer` in the merge call below — do not swap these,
        // or the outer frame wins instead of the inner one per the merge contract.
        var node = node
        var spec = FrameSpec.unspecified
        var blockID: BlockID?
        while true {
            if let f = node as? FrameModifierNode {
                spec = FrameSpec.merge(inner: f.spec, outer: spec)
                node = f.content
            } else if let modifier = node as? RenderIDModifierNode {
                blockID = blockID ?? modifier.blockID
                node = modifier.content
            } else {
                break
            }
        }

        if let codeBlock = node as? CodeBlockNode {
            assert(!spec.isSpecified && blockID == nil,
                "CodeBlockNode does not support .frame()/.renderID() — use its own blockID: parameter")
            let myIndex = nodes.count
            let descriptor = codeBlock.descriptor
            parentIndices.append(parent)
            nodes.append(.codeBlock(descriptor))
            if let id = descriptor.blockID { blockIDByIndex[myIndex] = id }
            if descriptor.lifecycle != .positional { blockLifecycleByIndex[myIndex] = descriptor.lifecycle }
            sawText = true
            return
        }

        if let table = node as? MarkdownTableNode {
            assert(!spec.isSpecified && blockID == nil,
                "MarkdownTableNode does not support .frame()/.renderID() — use its own blockID: parameter")
            let myIndex = nodes.count
            let descriptor = table.descriptor
            parentIndices.append(parent)
            nodes.append(.table(descriptor))
            if let id = descriptor.blockID { blockIDByIndex[myIndex] = id }
            if descriptor.lifecycle != .positional { blockLifecycleByIndex[myIndex] = descriptor.lifecycle }
            sawText = true
            return
        }

        if let mathBlock = node as? MathBlockNode {
            assert(!spec.isSpecified && blockID == nil,
                "MathBlockNode does not support .frame()/.renderID() — use its own blockID: parameter")
            let myIndex = nodes.count
            let descriptor = mathBlock.descriptor
            parentIndices.append(parent)
            nodes.append(.mathBlock(descriptor))
            if let id = descriptor.blockID { blockIDByIndex[myIndex] = id }
            if descriptor.lifecycle != .positional { blockLifecycleByIndex[myIndex] = descriptor.lifecycle }
            sawText = true
            return
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
            blockID = blockID ?? n.blockID
            if n.blockLifecycle != .positional { blockLifecycleByIndex[myIndex] = n.blockLifecycle }
            nodes.append(.text(TextDescriptor(
                content: n.content, font: n.font, color: n.color,
                lineLimit: n.lineLimit, lineBreakMode: n.lineBreakMode.rawValue,
                underlineStyle: n.underlineStyle.rawValue, strikethroughStyle: n.strikethroughStyle.rawValue,
                kerning: n.kerning, lineSpacing: n.lineSpacing,
                contentSizeCategory: contentSizeCategory,
                runs: n.runs,
                leadingBarColor: n.leadingBarColor, leadingBarWidth: n.leadingBarWidth, leadingBarGap: n.leadingBarGap,
                ruleColor: n.ruleColor,
                alignment: n.alignment, maxWidthFraction: n.maxWidthFraction,
                layoutHash: combineHash(n.layoutHash, contentSizeCategory), appearanceHash: n.appearanceHash,
                codeBlockRole: n.codeBlockRole, backgroundChrome: n.backgroundChrome)))
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
        if let blockID { blockIDByIndex[myIndex] = blockID }
    }

    visit(root, parent: -1)

    // nil (not an all-`.unspecified` array) when nothing in the tree was framed — the zero-cost
    // unframed path NodeTable.frame(at:) and measureNode rely on: no allocation, one nil-check branch.
    let frames: [FrameSpec]? = frameByIndex.isEmpty
        ? nil
        : (0..<nodes.count).map { frameByIndex[$0] ?? .unspecified }
    let blockIDs = (0..<nodes.count).map { blockIDByIndex[$0] }
    let blockLifecycles = (0..<nodes.count).map { blockLifecycleByIndex[$0] ?? .positional }

    // sawText gate: a category-blind tree must keep byte-identical layoutHash across categories, or
    // classify()'s tier-1 fast path misses on every Dynamic Type change and misclassifies as `.media`.
    let tableLayoutHash = sawText ? combineHash(root.layoutHash, contentSizeCategory) : root.layoutHash

    return NodeTable(
        itemID: itemID,
        nodes: nodes,
        parentIndices: parentIndices,
        layoutHash: tableLayoutHash,
        appearanceHash: root.appearanceHash,
        frames: frames,
        blockIDs: blockIDs,
        blockLifecycles: blockLifecycles
    )
}

/// Combines a DSL-level layoutHash with the Dynamic Type category `flatten()` was called with.
/// Used for both the table's top-level layoutHash (gated by `sawText`) and each `.text` node's
/// own `TextDescriptor.layoutHash`.
///
/// `.unspecified` is a true identity transform — returns `layoutHash` verbatim, so callers that
/// never opt into Dynamic Type get byte-identical output.
private func combineHash(_ layoutHash: Int, _ category: VContentSizeCategory) -> Int {
    guard category != .unspecified else { return layoutHash }
    var h = Hasher()
    h.combine(layoutHash)
    h.combine(category)
    return h.finalize()
}

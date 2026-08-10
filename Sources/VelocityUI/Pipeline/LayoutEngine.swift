// LayoutEngine.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

/// nonisolated async — runs on the cooperative pool, never touches @MainActor.
/// Recursively measures a NodeTable tree, parallelising children via TaskGroup.
public func measureNode(
    _ table: NodeTable,
    nodeIndex: Int,
    width: CGFloat,
    textPool: TextMeasurementPool
) async -> ResolvedLayout {
    guard nodeIndex >= 0, nodeIndex < table.nodes.count else {
        return .placeholder
    }
    switch table.nodes[nodeIndex] {
    case .vstack(let d):
        return await measureVStack(
            table: table, nodeIndex: nodeIndex,
            width: width, textPool: textPool,
            spacing: d.spacing
        )
    case .hstack(let d):
        return await measureHStack(
            table: table, nodeIndex: nodeIndex,
            width: width, textPool: textPool,
            spacing: d.spacing
        )
    case .zstack:
        let childIndices = table.children(of: nodeIndex)
        var maxW: CGFloat = 0
        var maxH: CGFloat = 0
        var children: [ResolvedLayout] = []
        await withTaskGroup(of: (Int, ResolvedLayout).self) { group in
            for (i, ci) in childIndices.enumerated() {
                group.addTask {
                    let r = await measureNode(table, nodeIndex: ci, width: width, textPool: textPool)
                    return (i, r)
                }
            }
            var results = [(Int, ResolvedLayout)]()
            for await pair in group { results.append(pair) }
            results.sort { $0.0 < $1.0 }
            for (_, r) in results {
                maxW = max(maxW, r.totalFrame.width)
                maxH = max(maxH, r.totalFrame.height)
                children.append(r)
            }
        }
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: maxW, height: maxH), children: children, nodeIndex: nodeIndex)

    case .text(let d):
        return await textPool.withContext { ctx in
            let size = ctx.measure(d, width: width)
            return ResolvedLayout(totalFrame: CGRect(origin: .zero, size: size), nodeIndex: nodeIndex)
        }

    case .image(let d):
        let h = d.aspectRatio.map { width / $0 } ?? width
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: h), nodeIndex: nodeIndex)

    case .spacer(let size):
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: size), nodeIndex: nodeIndex)

    case .hosting(let d):
        return ResolvedLayout(totalFrame: CGRect(origin: .zero, size: d.size), nodeIndex: nodeIndex)

    case .gif, .video, .customLayer:
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: 44), nodeIndex: nodeIndex)
    }
}

/// Synchronous, allocation-free intrinsic height for a NEW/unmeasured row, computed straight
/// from the NodeTable — no decode, no cache probe, no actor hop. Exists so Layer 3's
/// `FeedScrollView.rebuildFrames` can seed `resolvedFrames` with the real image height instead
/// of the flat `estimatedItemHeight` placeholder before the async pipeline (`measureNode`) ever
/// runs, which otherwise leaves every unmeasured image row wrong until its first WorkingRange
/// commit — see VelocityUI-ksh.
///
/// Mirrors the `.image` case of `measureNode` above EXACTLY (`width / aspectRatio`, falling back
/// to `width` when `aspectRatio` is nil) so the two never disagree: once the pipeline measures
/// the same table at the same width, `refineKnownFrames` sees a zero delta for these rows.
///
/// Only handles the single-image row shape Phase 1 image-only feeds produce (`table.nodes` has
/// exactly one node and it's `.image`). Returns `nil` for text/mixed/container rows — those
/// still need `measureNode`'s async, TextKit-backed measurement and keep using
/// `estimatedItemHeight` as their pre-measure placeholder.
func intrinsicHeight(for table: NodeTable, width: CGFloat) -> CGFloat? {
    guard table.nodes.count == 1, case .image(let d) = table.nodes[0] else { return nil }
    return d.aspectRatio.map { width / $0 } ?? width
}

// MARK: - Private helpers

/// Parallel measurement is unconditionally correct for VStack: each child independently
/// fills the full available width — siblings are irrelevant, now and after any future
/// node types are added. No sequential pass is ever needed here.
private func measureVStack(
    table: NodeTable, nodeIndex: Int,
    width: CGFloat, textPool: TextMeasurementPool,
    spacing: CGFloat
) async -> ResolvedLayout {
    let childIndices = table.children(of: nodeIndex)
    guard !childIndices.isEmpty else {
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: 0), nodeIndex: nodeIndex)
    }

    var ordered = [(Int, ResolvedLayout)]()
    await withTaskGroup(of: (Int, ResolvedLayout).self) { group in
        for (i, ci) in childIndices.enumerated() {
            group.addTask {
                let r = await measureNode(table, nodeIndex: ci, width: width, textPool: textPool)
                return (i, r)
            }
        }
        for await pair in group { ordered.append(pair) }
    }
    ordered.sort { $0.0 < $1.0 }

    var cursor: CGFloat = 0
    var children: [ResolvedLayout] = []
    var crossMax: CGFloat = 0

    for (idx, (_, layout)) in ordered.enumerated() {
        children.append(layout.offsetBy(dy: cursor))
        cursor += layout.totalFrame.height
        if idx < ordered.count - 1 { cursor += spacing }
        crossMax = max(crossMax, layout.totalFrame.width)
    }

    let frame = CGRect(x: 0, y: 0, width: width, height: cursor)
    return ResolvedLayout(totalFrame: frame, children: children, nodeIndex: nodeIndex)
}

/// Two-pass HStack measurement (VelocityUI-g5x): a serial pass measures fixed-size children
/// in order — each fed the width still remaining after its predecessors' claims — then a
/// parallel pass distributes whatever width is left evenly across flexible (`.text`) children.
///
/// `.text` is the only flexible kind. Everything else (`.hosting`, `.image`, `.gif`, `.video`,
/// `.customLayer`, nested stacks, and `.spacer`) is fixed: it claims serially from the running
/// width budget rather than waiting for the proportional split. `.spacer` is measured inline
/// here rather than via `measureNode` because the shared `.spacer` case in `measureNode` maps
/// its CGFloat onto whichever axis `width` represents — correct for VStack (size is the
/// along-axis height, `width` is the cross length) but wrong for HStack, where size must be the
/// along-axis *width* claim and the cross length (height) is unknown at this call depth.
private func measureHStack(
    table: NodeTable, nodeIndex: Int,
    width: CGFloat, textPool: TextMeasurementPool,
    spacing: CGFloat
) async -> ResolvedLayout {
    let childIndices = table.children(of: nodeIndex)
    guard !childIndices.isEmpty else {
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: 0), nodeIndex: nodeIndex)
    }

    let totalSpacing = spacing * CGFloat(max(0, childIndices.count - 1))
    var remainingWidth = max(0, width - totalSpacing)

    var results = [ResolvedLayout?](repeating: nil, count: childIndices.count)
    var flexibleSlots: [(slot: Int, childIndex: Int)] = []

    for (i, ci) in childIndices.enumerated() {
        if case .text = table.nodes[ci] {
            flexibleSlots.append((i, ci))
            continue
        }
        let layout: ResolvedLayout
        if case .spacer(let size) = table.nodes[ci] {
            layout = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: size, height: 0), nodeIndex: ci)
        } else {
            layout = await measureNode(table, nodeIndex: ci, width: remainingWidth, textPool: textPool)
        }
        remainingWidth = max(0, remainingWidth - layout.totalFrame.width)
        results[i] = layout
    }

    if !flexibleSlots.isEmpty {
        let perFlexWidth = remainingWidth / CGFloat(flexibleSlots.count)
        await withTaskGroup(of: (Int, ResolvedLayout).self) { group in
            for (slot, ci) in flexibleSlots {
                group.addTask {
                    let r = await measureNode(table, nodeIndex: ci, width: perFlexWidth, textPool: textPool)
                    return (slot, r)
                }
            }
            for await (slot, r) in group { results[slot] = r }
        }
    }

    var cursor: CGFloat = 0
    var children: [ResolvedLayout] = []
    var crossMax: CGFloat = 0

    for (idx, layout) in results.enumerated() {
        guard let layout else { continue }
        children.append(layout.offsetBy(dx: cursor, dy: 0))
        cursor += layout.totalFrame.width
        if idx < results.count - 1 { cursor += spacing }
        crossMax = max(crossMax, layout.totalFrame.height)
    }

    let frame = CGRect(x: 0, y: 0, width: cursor, height: crossMax)
    return ResolvedLayout(totalFrame: frame, children: children, nodeIndex: nodeIndex)
}
#endif

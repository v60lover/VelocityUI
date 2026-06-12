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
        return await measureStack(
            table: table, nodeIndex: nodeIndex,
            width: width, textPool: textPool,
            spacing: d.spacing, axis: .vertical
        )
    case .hstack(let d):
        // KNOWN LIMITATION (VelocityUI-g5x): every HStack child is measured at the full
        // container width instead of a proportional share. Correct for Phase 1 because all
        // cells are image-only VStacks — no HStack child cares about its width constraint.
        // Breaks in Phase 2: TextNode inside an HStack wraps at the wrong width, producing
        // an incorrect cell height and breaking the Spike 4 measure/render parity invariant.
        // Fix: split measureStack → measureVStack / measureHStack. measureHStack needs a
        // two-pass approach — serial pass to collect fixed-size claims, parallel pass to
        // measure flexible children at their resolved widths. Do this before Phase 2 starts.
        return await measureStack(
            table: table, nodeIndex: nodeIndex,
            width: width, textPool: textPool,
            spacing: d.spacing, axis: .horizontal
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

// MARK: - Private helpers

private enum StackAxis { case vertical, horizontal }

private func measureStack(
    table: NodeTable, nodeIndex: Int,
    width: CGFloat, textPool: TextMeasurementPool,
    spacing: CGFloat, axis: StackAxis
) async -> ResolvedLayout {
    let childIndices = table.children(of: nodeIndex)
    guard !childIndices.isEmpty else {
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: 0), nodeIndex: nodeIndex)
    }

    var ordered = [(Int, ResolvedLayout)]()
    // Parallel measurement is unconditionally correct for VStack: each child
    // independently fills the full available width — siblings are irrelevant, now
    // and after any future node types are added.
    // For HStack this is a Phase 1 simplification — see the hstack case above and
    // bead VelocityUI-g5x. Parallelism breaks when a child's measured size depends
    // on how much width siblings claimed (proportional sizing). That requires a
    // sequential first pass to resolve widths, then a parallel second pass —
    // a structural change that belongs in a dedicated measureHStack, not here.
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
        switch axis {
        case .vertical:
            children.append(layout.offsetBy(dy: cursor))
            cursor += layout.totalFrame.height
            if idx < ordered.count - 1 { cursor += spacing }
            crossMax = max(crossMax, layout.totalFrame.width)
        case .horizontal:
            children.append(layout.offsetBy(dx: cursor, dy: 0))
            cursor += layout.totalFrame.width
            if idx < ordered.count - 1 { cursor += spacing }
            crossMax = max(crossMax, layout.totalFrame.height)
        }
    }

    let frame: CGRect = axis == .vertical
        ? CGRect(x: 0, y: 0, width: width, height: cursor)
        : CGRect(x: 0, y: 0, width: cursor, height: crossMax)

    return ResolvedLayout(totalFrame: frame, children: children, nodeIndex: nodeIndex)
}
#endif

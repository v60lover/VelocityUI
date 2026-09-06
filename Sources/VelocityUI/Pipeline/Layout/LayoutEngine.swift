// LayoutEngine.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics
import SwaTex

/// nonisolated async — runs on the cooperative pool, never touches @MainActor. Recursively
/// measures a NodeTable tree, parallelising children via TaskGroup, then applies `.frame()`
/// framing on top of `measureContent`'s intrinsic result.
/// - Parameter formulaCache: memoizes SwaTex parse+layout for `.mathBlock` nodes. `nil` bypasses
///   caching (mirrors `SwaTexEngine.displayList(for:cache:)`'s own nil-bypass convention) — a
///   correctness-neutral perf knob, not an owned-collaborator identity contract, so it defaults
///   freely instead of forcing every call site to thread one through.
public func measureNode(
    _ table: NodeTable,
    nodeIndex: Int,
    width: CGFloat,
    textPool: TextMeasurementPool,
    formulaCache: FormulaCache? = nil
) async -> ResolvedLayout {
    guard nodeIndex >= 0, nodeIndex < table.nodes.count else {
        return .placeholder
    }
    let spec = table.frame(at: nodeIndex)
    // A fixed width in the spec overrides the incoming width proposal — the node (and,
    // for containers, everything measured beneath it) is measured at the framed width
    // rather than whatever width the parent proposed. Unspecified stays a pure passthrough.
    let content = await measureContent(table, nodeIndex: nodeIndex, width: spec.width ?? width, textPool: textPool, formulaCache: formulaCache)
    return spec.isSpecified ? applyFrame(spec, to: content, table: table, nodeIndex: nodeIndex) : content
}

/// Per-`NodeKind` switch measuring each node's intrinsic size, oblivious to any
/// `.frame()` wrapping it — framing is applied by the caller (`measureNode`) after this
/// returns.
private func measureContent(
    _ table: NodeTable,
    nodeIndex: Int,
    width: CGFloat,
    textPool: TextMeasurementPool,
    formulaCache: FormulaCache? = nil
) async -> ResolvedLayout {
    switch table.nodes[nodeIndex] {
    case .vstack(let d):
        return await measureVStack(
            table: table, nodeIndex: nodeIndex,
            width: width, textPool: textPool, formulaCache: formulaCache,
            spacing: d.spacing
        )
    case .hstack(let d):
        return await measureHStack(
            table: table, nodeIndex: nodeIndex,
            width: width, textPool: textPool, formulaCache: formulaCache,
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
                    let r = await measureNode(table, nodeIndex: ci, width: width, textPool: textPool, formulaCache: formulaCache)
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
        if case .body = d.codeBlockRole {
            // A code block body never wraps -- measure it as wide as its longest line
            // (`.greatestFiniteMagnitude`, mirroring CodeBlockRasterizer.rasterizeCodeBlock's
            // width sentinel) instead of clamping to the proposed container width. Color runs
            // don't affect TextKit's glyph layout, so measuring with `colorRuns: []` here still
            // reports the same size the real highlighted raster will end up with -- the actual
            // colors are applied at rasterize time (RenderPipeline / FeedScrollView+Items), not
            // here. This function has no `HighlightRegistry` to look one up anyway.
            let codeDescriptor = makeCodeTextDescriptor(
                lines: d.content.components(separatedBy: "\n")[...],
                colorRuns: [], font: d.font, theme: .defaultLight
            )
            return await textPool.withContext { ctx in
                let size = ctx.measure(codeDescriptor, width: .greatestFiniteMagnitude)
                return ResolvedLayout(totalFrame: CGRect(origin: .zero, size: size), nodeIndex: nodeIndex)
            }
        }
        return await textPool.withContext { ctx in
            // A row measures at its own maxWidthFraction of the proposed column width -- the
            // user bubble (fraction ~0.8) wraps narrower than the assistant's full-width text
            // (fraction 1.0), same width-in/size-out contract as the grid's per-column
            // measurement (GridTextMeasurementTests).
            let measureWidth = width * CGFloat(d.maxWidthFraction)
            let size = ctx.measure(d, width: measureWidth, formulaCache: formulaCache)
            // A rule (markdown thematic break) must span the full proposed width, not the
            // near-zero intrinsic width of its single-space content -- same "pin to container
            // width" contract `.codeBlock`/`.table`/`.mathBlock` use below, just in the other
            // direction (widening a too-narrow leaf instead of clamping a too-wide one). This
            // overrides maxWidthFraction intentionally: a rule always spans the row.
            let resolvedWidth = d.ruleColor != nil ? width : size.width
            // x is placed against the undivided column `width`, not `measureWidth` -- a trailing
            // row is flush with the column's right edge, not the fraction's own right edge.
            let x: CGFloat
            switch d.alignment {
            case .leading: x = 0
            case .center: x = (width - resolvedWidth) / 2
            case .trailing: x = width - resolvedWidth
            }
            return ResolvedLayout(totalFrame: CGRect(x: x, y: 0, width: resolvedWidth, height: size.height), nodeIndex: nodeIndex)
        }

    case .codeBlock(let descriptor):
        let header = await textPool.withContext { ctx in
            let size = ctx.measure(descriptor.headerText, width: width)
            return ResolvedLayout(totalFrame: CGRect(origin: .zero, size: size), nodeIndex: nodeIndex, renderPart: .codeHeader)
        }
        let bodyDescriptor = makeCodeTextDescriptor(
            lines: descriptor.rawCode.components(separatedBy: "\n")[...], colorRuns: [],
            font: descriptor.font, theme: .defaultLight
        )
        let body = await textPool.withContext { ctx in
            let size = ctx.measure(bodyDescriptor, width: .greatestFiniteMagnitude)
            return ResolvedLayout(totalFrame: CGRect(origin: .zero, size: size), nodeIndex: nodeIndex, renderPart: .codeBody)
        }
        // Card/background/body frame width is pinned to the proposed container `width`
        // unconditionally -- a long line must never expand the card or its parent bubble past
        // the feed width. The raster itself stays as wide as its longest line (measured above
        // at `.greatestFiniteMagnitude`); true content width for horizontal scroll comes from
        // `CodeBodyLayerContent.totalSize.width` in RenderCell, independent of this frame.
        let total = CGRect(x: 0, y: 0, width: width, height: header.totalFrame.height + body.totalFrame.height)
        let background = ResolvedLayout(totalFrame: total, nodeIndex: nodeIndex, renderPart: .codeBackground)
        let clampedBody = ResolvedLayout(
            totalFrame: CGRect(x: 0, y: 0, width: width, height: body.totalFrame.height),
            nodeIndex: nodeIndex, renderPart: .codeBody
        )
        return ResolvedLayout(totalFrame: total, children: [background, header, clampedBody.offsetBy(dy: header.totalFrame.height)], nodeIndex: nodeIndex)

    case .image(let d):
        let h = d.aspectRatio.map { width / $0 } ?? width
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: h), nodeIndex: nodeIndex)

    case .spacer(let size):
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: size), nodeIndex: nodeIndex)

    case .hosting(let d):
        return ResolvedLayout(totalFrame: CGRect(origin: .zero, size: d.size), nodeIndex: nodeIndex)

    case .gif, .video, .customLayer:
        return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: 44), nodeIndex: nodeIndex)

    case .table(let descriptor):
        guard !descriptor.cells.isEmpty, !descriptor.cells[0].isEmpty else {
            return ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: width, height: 0), nodeIndex: nodeIndex)
        }
        let tableLayout = await textPool.withContext { ctx -> ResolvedTableLayout in
            // Table cells tokenize inline runs the same way paragraphs do (gojy.2), so a cell's
            // `$...$` gets the same cached typeset path as a paragraph's.
            let measure: TextMeasure = { d, w in ctx.measure(d, width: w, formulaCache: formulaCache) }
            // solve + layout must share one padding value so column widths reserve padding
            // that layout then subtracts back for the text's wrap width.
            let padding = TableCellPadding.default
            let solution = solveColumnWidths(
                cells: descriptor.cells, availableWidth: width, measure: measure, padding: padding
            )
            return layoutTableCells(
                cells: descriptor.cells, columnWidths: solution.widths,
                alignments: descriptor.alignments, measure: measure, padding: padding
            )
        }
        // Card frame is pinned to `width` unconditionally -- a wide table must never expand the
        // cell past the feed width, same reasoning as the code card's background frame. The
        // natural (possibly wider) content size travels separately via the `.tableBody` child,
        // read back by `collectFragments` -- mirrors `.codeBlock`'s `.codeBody` child exactly.
        let total = CGRect(x: 0, y: 0, width: width, height: tableLayout.size.height)
        let body = ResolvedLayout(
            totalFrame: CGRect(origin: .zero, size: tableLayout.size), nodeIndex: nodeIndex, renderPart: .tableBody
        )
        return ResolvedLayout(totalFrame: total, children: [body], nodeIndex: nodeIndex)

    case .mathBlock(let descriptor):
        // Card frame is pinned to `width` unconditionally -- same reasoning as `.codeBlock`/
        // `.table`: a wide formula must never expand the container past the feed width. The
        // real (possibly wider) content size travels via the `.mathBody` child, mirroring
        // `.tableBody`'s role -- `extractFragments` reads it back the same way.
        let mathLayout = await textPool.withContext { ctx -> MathBlockLayout in
            layoutMathBlock(
                rawTeX: descriptor.rawTeX, font: descriptor.font, color: descriptor.color,
                width: width, cache: formulaCache,
                allowFormula: descriptor.lifecycle != .hot,
                measure: { d, w in ctx.measure(d, width: w) }
            )
        }
        // Formula case: canvas is `max(formula width, block width)` -- see MathBlockRasterizer's
        // centering contract. Literal-fallback case: the tight measured (possibly-wrapped,
        // never-wider-than-`width`) size, NOT `width` itself -- mirrors how an ordinary TextNode
        // block reports its own tight width rather than the full card width (`recordTextResult`'s
        // "heading in a stretched font" invariant: a fragment's frame size must equal its
        // bitmap's real pixel size, or `contentsGravity = .resize` silently stretches it).
        let contentSize: CGSize
        switch mathLayout {
        case .formula(_, _, let metrics):
            contentSize = CGSize(width: max(metrics.width, width), height: metrics.height)
        case .literal(_, let size):
            contentSize = size
        }
        let total = CGRect(x: 0, y: 0, width: width, height: contentSize.height)
        let body = ResolvedLayout(
            totalFrame: CGRect(origin: .zero, size: contentSize), nodeIndex: nodeIndex, renderPart: .mathBody
        )
        return ResolvedLayout(totalFrame: total, children: [body], nodeIndex: nodeIndex)
    }
}

// MARK: - Framing

/// Resolves a `.frame()` slot around `content`'s intrinsic measurement. A larger slot
/// positions content via `alignment` (padding/letterbox); a smaller slot wins and clamps
/// content via `min(intrinsic, framed)` — except a `.fill` image, which fills the slot
/// outright. Leaves report the aligned/clamped box as `contentFrame`; containers instead
/// shift every child by the same offset via `offsetBy`.
private func applyFrame(
    _ spec: FrameSpec,
    to content: ResolvedLayout,
    table: NodeTable,
    nodeIndex: Int
) -> ResolvedLayout {
    let intrinsic = content.totalFrame.size
    let framedW = spec.width ?? intrinsic.width
    let framedH = spec.height ?? intrinsic.height
    let slot = CGRect(x: 0, y: 0, width: framedW, height: framedH)

    let isFillImage: Bool = {
        if case .image(let d) = table.nodes[nodeIndex], d.contentMode == VContentMode.fill.rawValue {
            return true
        }
        return false
    }()

    let cw = isFillImage ? framedW : min(intrinsic.width, framedW)
    let ch = isFillImage ? framedH : min(intrinsic.height, framedH)
    let (ox, oy) = alignOffset(slot: slot.size, content: CGSize(width: cw, height: ch), alignment: spec.alignment)

    if content.children.isEmpty {
        return ResolvedLayout(
            totalFrame: slot,
            contentFrame: CGRect(x: ox, y: oy, width: cw, height: ch),
            children: [],
            nodeIndex: nodeIndex
        )
    }

    return ResolvedLayout(
        totalFrame: slot,
        children: content.children.map { $0.offsetBy(dx: ox, dy: oy) },
        nodeIndex: nodeIndex
    )
}

/// (x, y) offset of an aligned content box within a slot, per `VAlignment`'s nine
/// SwiftUI-style positions. Callers must pre-clamp `content <= slot` on both axes — that's
/// what makes an exact-match content/slot a no-op (0, 0) offset.
private func alignOffset(slot: CGSize, content: CGSize, alignment: VAlignment) -> (CGFloat, CGFloat) {
    let dx = slot.width - content.width
    let dy = slot.height - content.height

    let x: CGFloat
    switch alignment {
    case .topLeading, .leading, .bottomLeading: x = 0
    case .top, .center, .bottom: x = dx / 2
    case .topTrailing, .trailing, .bottomTrailing: x = dx
    }

    let y: CGFloat
    switch alignment {
    case .topLeading, .top, .topTrailing: y = 0
    case .leading, .center, .trailing: y = dy / 2
    case .bottomLeading, .bottom, .bottomTrailing: y = dy
    }

    return (x, y)
}

/// Synchronous, allocation-free intrinsic height for a single-image row — lets
/// `FeedScrollView.rebuildFrames` seed a real height before `measureNode` ever runs.
/// Returns `nil` for anything but a lone `.image` node. Must mirror `measureNode`'s
/// `.image` case exactly, including `.frame()` overrides, so the two never disagree.
func intrinsicHeight(for table: NodeTable, width: CGFloat) -> CGFloat? {
    guard table.nodes.count == 1, case .image(let d) = table.nodes[0] else { return nil }
    let spec = table.frame(at: 0)
    let effectiveWidth = spec.width ?? width
    let h = d.aspectRatio.map { effectiveWidth / $0 } ?? effectiveWidth
    return spec.height ?? h
}

// MARK: - Private helpers

/// Parallel measurement is unconditionally correct for VStack: each child independently
/// fills the full available width — siblings are irrelevant, now and after any future
/// node types are added. No sequential pass is ever needed here.
private func measureVStack(
    table: NodeTable, nodeIndex: Int,
    width: CGFloat, textPool: TextMeasurementPool, formulaCache: FormulaCache?,
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
                let r = await measureNode(table, nodeIndex: ci, width: width, textPool: textPool, formulaCache: formulaCache)
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

/// Two-pass HStack measurement: a serial pass measures fixed-size children in order (each
/// fed the width remaining after predecessors' claims), then a parallel pass splits leftover
/// width evenly across flexible (unframed `.text`) children. `.spacer` is measured inline
/// here, not via `measureNode`, because the shared `.spacer` case assumes the along-axis is
/// height — correct for VStack, wrong for HStack.
private func measureHStack(
    table: NodeTable, nodeIndex: Int,
    width: CGFloat, textPool: TextMeasurementPool, formulaCache: FormulaCache?,
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
        if case .text = table.nodes[ci], table.frame(at: ci).width == nil {
            flexibleSlots.append((i, ci))
            continue
        }
        // A fixed-width-framed .text lands here alongside the other fixed kinds — the
        // measureNode call below (not the inline .spacer fast path) applies its frame's
        // width via the same `spec.width ?? width` override every other framed node uses.
        let layout: ResolvedLayout
        if case .spacer(let size) = table.nodes[ci] {
            layout = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: size, height: 0), nodeIndex: ci)
        } else {
            layout = await measureNode(table, nodeIndex: ci, width: remainingWidth, textPool: textPool, formulaCache: formulaCache)
        }
        remainingWidth = max(0, remainingWidth - layout.totalFrame.width)
        results[i] = layout
    }

    if !flexibleSlots.isEmpty {
        let perFlexWidth = remainingWidth / CGFloat(flexibleSlots.count)
        await withTaskGroup(of: (Int, ResolvedLayout).self) { group in
            for (slot, ci) in flexibleSlots {
                group.addTask {
                    let r = await measureNode(table, nodeIndex: ci, width: perFlexWidth, textPool: textPool, formulaCache: formulaCache)
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

// LayoutEngine.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

/// nonisolated async — runs on the cooperative pool, never touches @MainActor. Recursively
/// measures a NodeTable tree, parallelising children via TaskGroup.
///
/// Thin wrapper around `measureContent` (the original unconditional-switch body) that applies
/// `.frame()` framing (VelocityUI-rsg) after intrinsic measurement. Keeps the unframed path a
/// single predicted branch: `table.frame(at:)` returns `.unspecified` in O(1) with no allocation
/// when `table.frames == nil` (the common case), so `measureContent`'s result passes through
/// untouched — byte-identical to pre-framing output.
public func measureNode(
    _ table: NodeTable,
    nodeIndex: Int,
    width: CGFloat,
    textPool: TextMeasurementPool
) async -> ResolvedLayout {
    guard nodeIndex >= 0, nodeIndex < table.nodes.count else {
        return .placeholder
    }
    let spec = table.frame(at: nodeIndex)
    // A fixed width in the spec overrides the incoming width proposal — the node (and,
    // for containers, everything measured beneath it) is measured at the framed width
    // rather than whatever width the parent proposed. Unspecified stays a pure passthrough.
    let content = await measureContent(table, nodeIndex: nodeIndex, width: spec.width ?? width, textPool: textPool)
    return spec.isSpecified ? applyFrame(spec, to: content, table: table, nodeIndex: nodeIndex) : content
}

/// The original unconditional `measureNode` switch, unchanged in shape — every case here
/// measures the node's INTRINSIC size, oblivious to any `.frame()` wrapping it. Framing is
/// applied by the caller (`measureNode` above) after this returns, never in here — keeps
/// this function's per-`NodeKind` cases exactly as simple/parallel as before framing existed.
private func measureContent(
    _ table: NodeTable,
    nodeIndex: Int,
    width: CGFloat,
    textPool: TextMeasurementPool
) async -> ResolvedLayout {
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

// MARK: - Framing (VelocityUI-rsg)

/// Resolves a `.frame()` slot around `content`'s intrinsic measurement.
///
/// Frozen semantics (epic VelocityUI-j4z):
/// - Unspecified dimension keeps the intrinsic size on that axis.
/// - `alignment` (default `.center`) positions content within the slot only when the slot is
///   LARGER than content — the padding/letterbox case.
/// - When the slot is SMALLER, the slot wins: content is clamped via `min(intrinsic, framed)`,
///   never reported larger than the slot ("clip-to-frame", no negative-padding overshoot).
/// - An image leaf with `contentMode == .fill` fills the slot outright (`cw`/`ch` == slot),
///   not fit/aligned — SwiftUI `.fill` semantics beat letterboxing.
///
/// Containers vs. leaves differ because a container's "content" IS its children, already
/// positioned relative to this node's local origin (see `ResolvedLayout.offsetBy` on why
/// `collectFragments` needs children never pre-shifted at the wrong level):
/// - LEAF: report the aligned/clamped box as `contentFrame`, `children` stays empty.
/// - CONTAINER: no separate content box — shift every child by the alignment offset via
///   `offsetBy` instead, as if laid out inside a `totalFrame`-sized box. `contentFrame` stays nil.
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

/// Computes the (x, y) offset of an aligned content box within a slot, per `VAlignment`'s
/// nine SwiftUI-style positions. `content` is expected to already be `<=` `slot` on both
/// axes (callers clamp via `min()` before calling this) — center/top/bottom and
/// leading/center/trailing collapse to the same 0 / midpoint / max-offset math regardless,
/// but the clamp is what makes "content == slot" a no-op offset (0, 0) for the fill/clip cases.
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

/// Synchronous, allocation-free intrinsic height for a NEW/unmeasured row, computed straight
/// from the NodeTable — no decode, no cache probe, no actor hop. Lets `FeedScrollView.rebuildFrames`
/// seed `resolvedFrames` with the real image height instead of the flat `estimatedItemHeight`
/// placeholder before `measureNode` ever runs (VelocityUI-ksh).
///
/// Mirrors `measureNode`'s `.image` case EXACTLY (`width / aspectRatio`, falling back to `width`)
/// so the two never disagree — `refineKnownFrames` sees zero delta once the pipeline measures
/// the same table at the same width.
///
/// Only handles the single-image row shape (`table.nodes` has exactly one `.image` node).
/// Returns `nil` for text/mixed/container rows, which keep using `estimatedItemHeight` until
/// `measureNode`'s async TextKit measurement runs.
///
/// `.frame()` (VelocityUI-rsg): also consults `table.frame(at: 0)`. A framed height overrides
/// the aspect-ratio height (`spec.height ?? h`), matching `applyFrame`'s behavior; a framed
/// width folds into the aspect-ratio computation the same way `measureNode` overrides the width
/// proposal before intrinsic measurement — keeps both formulas in lockstep for every combination.
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

/// Two-pass HStack measurement (VelocityUI-g5x): a serial pass measures fixed-size children in
/// order — each fed the width remaining after predecessors' claims — then a parallel pass splits
/// whatever width is left evenly across flexible (`.text`) children.
///
/// `.text` is the only flexible kind — UNLESS it carries a fixed-width `.frame()` (VelocityUI-rsg),
/// which makes it author-sized like `.hosting`/a framed image, so it claims serially instead.
/// Everything else (`.hosting`, `.image`, `.gif`, `.video`, `.customLayer`, nested stacks,
/// `.spacer`) claims serially too. `.spacer` is measured inline here rather than via `measureNode`
/// because `measureNode`'s shared `.spacer` case maps its CGFloat onto whatever axis `width`
/// represents — correct for VStack (along-axis height) but wrong for HStack, where the along-axis
/// claim is width and the cross length (height) is unknown at this depth.
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

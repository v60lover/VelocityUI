// CodeBlockRasterizer.swift

#if canImport(UIKit)
import UIKit

/// Builds the `TextDescriptor` for a fully-known code block: per-line color runs (from a
/// `SyntaxHighlighter`) laid end-to-end over the joined source, gaps filled with `theme`'s
/// plain color so the run list is always a complete, gapless, ordered partition of `content` --
/// `TextDescriptor.attributedString` only auto-fills a trailing remainder, never an internal gap.
///
/// Pure and nonisolated: same inputs always produce the same descriptor. `font` is used for
/// every run -- `ColorRun` only carries a resolved color, never a font override.
func makeCodeTextDescriptor(
    lines: ArraySlice<String>,
    colorRuns: [LineColorRuns],
    font: VFontDescriptor,
    theme: Theme
) -> TextDescriptor {
    let content = lines.joined(separator: "\n")
    let plainColor = theme.color(for: .plain)

    var runs: [TextRun] = []
    for (offset, line) in lines.enumerated() {
        let lineRuns = offset < colorRuns.count ? colorRuns[offset].runs : []
        runs.append(contentsOf: partitionedRuns(for: line, colorRuns: lineRuns, font: font, plainColor: plainColor))
        if offset < lines.count - 1 {
            runs.append(TextRun(length: 1, font: font, color: plainColor))
        }
    }

    var layoutHasher = Hasher()
    layoutHasher.combine(content)
    layoutHasher.combine(font)

    var appearanceHasher = Hasher()
    appearanceHasher.combine(colorRuns)

    return TextDescriptor(
        content: content,
        font: font,
        color: plainColor,
        lineLimit: nil,
        lineBreakMode: NSLineBreakMode.byClipping.rawValue,
        runs: runs,
        layoutHash: layoutHasher.finalize(),
        appearanceHash: appearanceHasher.finalize()
    )
}

/// One line's color runs, sorted and gap-filled into a gapless partition of `line`'s UTF-16 range.
private func partitionedRuns(
    for line: String,
    colorRuns: [ColorRun],
    font: VFontDescriptor,
    plainColor: VColorDescriptor
) -> [TextRun] {
    let lineLength = line.utf16.count
    guard lineLength > 0 else { return [] }

    let sorted = colorRuns.sorted { $0.range.lowerBound < $1.range.lowerBound }
    var result: [TextRun] = []
    var cursor = 0
    for run in sorted {
        let lower = max(cursor, min(lineLength, run.range.lowerBound))
        let upper = max(lower, min(lineLength, run.range.upperBound))
        guard upper > lower else { continue }
        if lower > cursor {
            result.append(TextRun(length: lower - cursor, font: font, color: plainColor))
        }
        result.append(TextRun(length: upper - lower, font: font, color: run.color))
        cursor = upper
    }
    if cursor < lineLength {
        result.append(TextRun(length: lineLength - cursor, font: font, color: plainColor))
    }
    return result
}

/// Rasterizes a fully-known code block (all lines already sealed) into one non-wrapping CGImage,
/// as wide as its longest line -- the wide raster the future horizontal-scroll consumer
/// (VelocityUI-oz5q.6) shifts via contents-offset. Off-main: measurement runs inside `textPool`'s
/// checkout (which already hops off the pool actor via `Task.detached`); `rasterizeText` itself is
/// a pure nonisolated free function needing no further hop.
///
/// Always re-measures and re-rasterizes the whole block -- per-line incremental re-raster on
/// append is VelocityUI-oz5q.7's job, layered on top without changing this contract.
func rasterizeCodeBlock(
    lines: ArraySlice<String>,
    colorRuns: [LineColorRuns],
    font: VFontDescriptor,
    theme: Theme,
    textPool: TextMeasurementPool,
    scale: CGFloat = 1
) async -> (image: CGImage?, size: CGSize) {
    let descriptor = makeCodeTextDescriptor(lines: lines, colorRuns: colorRuns, font: font, theme: theme)
    // .greatestFiniteMagnitude on the width axis, mirroring this file's existing height sentinel,
    // so no line ever wraps or gets clamped to a container edge -- measure() then reports the
    // true intrinsic longest-line width instead of whatever column width the DSL assigned.
    let size = await textPool.withContext { ctx in ctx.measure(descriptor, width: .greatestFiniteMagnitude) }
    guard size.width > 0, size.height > 0 else { return (nil, size) }
    return (rasterizeText(descriptor, size: size, scale: scale), size)
}
#endif

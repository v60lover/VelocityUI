// CodeBlockRasterizer.swift

#if canImport(UIKit)
import UIKit

/// Right-side ink guard for every code-body raster path (whole-block and per-line). A
/// `layoutFragmentFrame`'s width is the typographic advance, which can end a hair inside the
/// last glyph's actual ink (e.g. bold/italic right-side bearing); a canvas exactly that wide
/// shaves the glyph's tail. Shared by `rasterizeCodeBlock`, `rasterizeCodeBlockSync`, and
/// `HotCodeStreamStore.rasterizeLine` so all three stay in agreement.
let codeInkRightGuard: CGFloat = 2

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

/// Pixel side length of the stretchable background template: a `(2*cornerRadius+1)`-point square
/// is the smallest tile that still has a full straight run between opposite corners for
/// `contentsCenter` to stretch. Single source of truth shared by `rasterizeCodeBlockBackground`
/// and `codeBlockBackgroundContentsCenter` so they can never disagree (CLAUDE.md/bead-implement
/// Section 3 -- cross-site consistency).
private func codeBlockBackgroundTemplateSide(cornerRadius: CGFloat, scale: CGFloat) -> Int {
    pixelLength(cornerRadius * 2 + 1, scale: scale)
}

/// Pre-rounded, stretchable background fill for the code block's container chrome. Draws a small
/// template with corners clipped via `CGContext` (never `CALayer.cornerRadius`/`masksToBounds`,
/// per the hard rule) -- `RenderCell` stretches the flat middle over the final frame via
/// `CALayer.contentsCenter` (paired with `codeBlockBackgroundContentsCenter`), so one small raster
/// covers any code block width/height.
func rasterizeCodeBlockBackground(cornerRadius: CGFloat, color: VColorDescriptor, scale: CGFloat = 1) -> CGImage? {
    let side = codeBlockBackgroundTemplateSide(cornerRadius: cornerRadius, scale: scale)
    guard side > 0 else { return nil }

    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                      CGBitmapInfo.byteOrder32Little.rawValue   // BGRA8888
    let rect = CGRect(x: 0, y: 0, width: side, height: side)

    guard let ctx = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else { return nil }

    if cornerRadius > 0 {
        let scaledRadius = cornerRadius * scale
        let path = CGPath(roundedRect: rect, cornerWidth: scaledRadius, cornerHeight: scaledRadius, transform: nil)
        ctx.addPath(path)
        ctx.clip()
    }
    ctx.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    ctx.fill(rect)
    return ctx.makeImage()
}

/// `CALayer.contentsCenter` for the template `rasterizeCodeBlockBackground` produces at the same
/// `cornerRadius`/`scale` -- the one-point-wide flat strip at the template's center stretches to
/// fill the final frame while the rounded corners stay fixed size.
func codeBlockBackgroundContentsCenter(cornerRadius: CGFloat, scale: CGFloat = 1) -> CGRect {
    let side = codeBlockBackgroundTemplateSide(cornerRadius: cornerRadius, scale: scale)
    guard side > 1 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    let radiusPixels = pixelLength(cornerRadius, scale: scale)
    let unit = 1 / CGFloat(side)
    let origin = CGFloat(radiusPixels) / CGFloat(side)
    return CGRect(x: origin, y: origin, width: unit, height: unit)
}

/// Exact height for the code body's fixed-size background layer, without waiting on
/// `rasterizeCodeBlock`'s async TextKit measurement. The body always renders `.byClipping`
/// (no wrap), so a line's height depends only on the font's fixed metrics, never on its
/// glyphs -- `lineCount * font.uiFont.lineHeight` reproduces what TextKit itself would report
/// for the same non-wrapping content, so the background can size itself synchronously while
/// the body's own raster is still in flight.
func codeBlockBodyHeight(lineCount: Int, font: VFontDescriptor) -> CGFloat {
    guard lineCount > 0 else { return 0 }
    return CGFloat(lineCount) * font.uiFont.lineHeight
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
    guard let image = rasterizeText(
        descriptor, layoutWidth: size.width, outputSize: size, scale: scale, inkGuard: codeInkRightGuard
    ) else { return (nil, size) }
    // The bitmap's own width (not the typographic measure) feeds every downstream content-width
    // calculation, so the ink guard baked into the pixels is also reflected in the scrollable
    // content width -- otherwise the guarded pixels exist but can never be scrolled into view.
    let width = CGFloat(image.width) / scale
    return (image, CGSize(width: width, height: size.height))
}

/// Sync sibling of `rasterizeCodeBlock`, for call sites that can't `await` -- the scroll-adjacent
/// in-place block diff's `measureTextSync` and `RenderPipeline`'s nonisolated free-function
/// rasterize path both measure/rasterize synchronously by contract. Shares
/// `makeCodeTextDescriptor` with the async version (Section 3 cross-site consistency): only the
/// measurement hop differs (caller-supplied sync `measure` vs `textPool.withContext`).
func rasterizeCodeBlockSync(
    lines: ArraySlice<String>,
    colorRuns: [LineColorRuns],
    font: VFontDescriptor,
    theme: Theme,
    scale: CGFloat = 1,
    measure: (TextDescriptor, CGFloat) -> CGSize
) -> (image: CGImage?, size: CGSize) {
    let descriptor = makeCodeTextDescriptor(lines: lines, colorRuns: colorRuns, font: font, theme: theme)
    let size = measure(descriptor, .greatestFiniteMagnitude)
    guard size.width > 0, size.height > 0 else { return (nil, size) }
    guard let image = rasterizeText(
        descriptor, layoutWidth: size.width, outputSize: size, scale: scale, inkGuard: codeInkRightGuard
    ) else { return (nil, size) }
    let width = CGFloat(image.width) / scale
    return (image, CGSize(width: width, height: size.height))
}
#endif

// InlineMathRasterizer.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation
import SwaTex
import SwaTexRender

/// Padding (points) reserved around an inline formula's ink. Much smaller than
/// `mathBlockPadding` -- an inline formula sits directly against neighboring words, so a wide
/// guard would visibly shove them apart.
let mathInlinePadding: CGFloat = 1

/// Options an inline formula is always typeset with. Shared by `layoutInlineMath` (geometry)
/// and `rasterizeInlineMath` (paint) so the two can never disagree on metrics for the same
/// input -- same cross-site-consistency contract as `mathBlockRenderOptions`.
func mathInlineRenderOptions(fontSize: CGFloat) -> RenderOptions {
    RenderOptions(fontSize: fontSize, padding: mathInlinePadding, backgroundColor: nil)
}

/// One inline formula's typeset outcome: a real formula with baseline metrics, or a literal-text
/// fallback when SwaTex can't parse the source. Pure/`Sendable`, mirroring `MathBlockLayout`.
enum InlineMathLayout: Sendable {
    case formula(list: DisplayList, options: RenderOptions, metrics: RenderMetrics)
    /// Parse failed -- caller renders the run's own `content` span as ordinary literal text.
    case literal
}

/// Pure, nonisolated: TeX source + font/color in, layout decision out. Typeset in TeX's `.text`
/// style (not `.display`) -- matches how the character sits inline with surrounding prose rather
/// than a standalone block. A parse failure returns `.literal`, letting the caller fall back to
/// the same span of text `TextRun.mathSource`'s sibling `content` already carries -- a malformed
/// inline formula degrades to literal TeX text, never a blank run or a crash.
func layoutInlineMath(
    rawTeX: String,
    font: VFontDescriptor,
    color: VColorDescriptor,
    cache: FormulaCache?
) -> InlineMathLayout {
    guard let list = try? SwaTexEngine.displayList(
        for: rawTeX, style: .text, color: swaTexColor(color), cache: cache
    ) else {
        return .literal
    }
    let options = mathInlineRenderOptions(fontSize: font.size)
    let metrics = DisplayListRenderer.metrics(for: list, options: options)
    return .formula(list: list, options: options, metrics: metrics)
}

/// Rasterizes one inline formula's typeset display list into a BGRA8888 premultiplied
/// `CGImage`, sized exactly `metrics.width` x `metrics.height` -- no centering (unlike
/// `rasterizeMathBlock`): `InlineMathAttachment.attachmentBounds` positions the whole image
/// against the text baseline using the same `metrics`, so the canvas itself never needs padding
/// beyond what `mathInlineRenderOptions` already reserves.
func rasterizeInlineMath(
    list: DisplayList,
    options: RenderOptions,
    metrics: RenderMetrics,
    fontProvider: KaTeXFontProvider,
    scale: CGFloat
) -> CGImage? {
    let pixelWidth = pixelLength(metrics.width, scale: scale)
    let pixelHeight = pixelLength(metrics.height, scale: scale)
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }

    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                      CGBitmapInfo.byteOrder32Little.rawValue   // BGRA8888
    guard let ctx = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else { return nil }

    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    DisplayListRenderer.draw(list, in: ctx, options: options, fontProvider: fontProvider)
    return ctx.makeImage()
}
#endif

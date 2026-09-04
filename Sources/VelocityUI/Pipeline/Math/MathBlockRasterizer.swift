// MathBlockRasterizer.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation
import SwaTex
import SwaTexRender

/// Padding (points) reserved around a typeset formula's ink -- SwaTex's own `RenderOptions`
/// knob, mirroring `codeInkRightGuard`'s role for code-body rasters.
let mathBlockPadding: CGFloat = 8

/// Options a block formula is always typeset with. Shared by `layoutMathBlock` (geometry) and
/// `rasterizeMathBlock` (paint) so the two can never disagree on metrics for the same input --
/// same cross-site-consistency contract as `codeBlockBackgroundTemplateSide`.
func mathBlockRenderOptions(fontSize: CGFloat) -> RenderOptions {
    RenderOptions(fontSize: fontSize, padding: mathBlockPadding, backgroundColor: nil)
}

/// One block math node's measured/typeset outcome: a real formula, or a literal-text fallback
/// when SwaTex can't parse the source. `SwaTexEngine.displayList` is a pure deterministic
/// function of its inputs, so calling this from both `LayoutEngine`'s `.mathBlock` measure case
/// and `rasterizeMathArtifacts` can never let the two disagree on which branch applies.
enum MathBlockLayout: Sendable {
    /// `options` is retained (not just `metrics`) because `DisplayListRenderer.draw` re-derives
    /// every glyph position from `options.fontSize`/`options.padding` -- passing a different
    /// `RenderOptions` at raster time than the one `metrics` was computed with would silently
    /// mis-scale the drawn formula relative to the canvas `metrics.width`/`.height` sized for.
    case formula(list: DisplayList, options: RenderOptions, metrics: RenderMetrics)
    /// `size` is the literal text's measured (wrapped, block-width) size.
    case literal(TextDescriptor, size: CGSize)
}

func swaTexColor(_ color: VColorDescriptor) -> SwaTex.Color {
    SwaTex.Color(r: Float(color.red), g: Float(color.green), b: Float(color.blue), a: Float(color.alpha))
}

/// Pure, nonisolated: TeX source + font/color in, layout decision out. A parse failure degrades
/// to literal text measured at `width` with word-wrapping -- matching exactly how a `.mathBlock`
/// parsed-but-not-yet-rendered block already displayed before this rasterizer existed (see
/// `IncrementalMarkdownParser`'s `.mathBlock` style case, which strips delimiters and lets the
/// default `TextNode` branch show the bare TeX as wrapped literal text) -- a malformed formula
/// looks the same as "no math support," never a new broken state.
///
/// `allowFormula: false` skips the SwaTex attempt entirely and forces the literal fallback --
/// used while the block is `.hot` so a half-typed formula never flickers formula/literal/formula
/// as the partial TeX flickers valid/invalid, which would jitter every following block's height.
func layoutMathBlock(
    rawTeX: String,
    font: VFontDescriptor,
    color: VColorDescriptor,
    width: CGFloat,
    cache: FormulaCache?,
    allowFormula: Bool,
    measure: (TextDescriptor, CGFloat) -> CGSize
) -> MathBlockLayout {
    if allowFormula, let list = try? SwaTexEngine.displayList(
        for: rawTeX, style: .display, color: swaTexColor(color), cache: cache
    ) {
        let options = mathBlockRenderOptions(fontSize: font.size)
        let metrics = DisplayListRenderer.metrics(for: list, options: options)
        return .formula(list: list, options: options, metrics: metrics)
    }
    let descriptor = TextDescriptor(
        content: rawTeX, font: font, color: color, lineLimit: nil,
        lineBreakMode: VLineBreakMode.byWordWrapping.rawValue,
        layoutHash: 0, appearanceHash: 0
    )
    let size = measure(descriptor, width)
    return .literal(descriptor, size: size)
}

/// Rasterizes one math block's layout decision into a BGRA8888 premultiplied `CGImage`, mirroring
/// `TableRasterizer`'s "one raster, one CGContext" shape.
///
/// `blockWidth` is the container's proposed width -- the same value `LayoutEngine`'s `.mathBlock`
/// case measured against (Section 3 cross-site consistency). For the `.literal` branch it is
/// ONLY the text-wrap width (`rasterizeText`'s `layoutWidth`, matching what `measure` wrapped
/// against inside `layoutMathBlock`) -- the returned image's actual size is the tight measured
/// `size`, never `blockWidth` itself, or a fragment/bitmap width mismatch silently stretches the
/// image (`contentsGravity = .resize`'s default). For the `.formula` branch, the canvas is
/// `max(formula width, blockWidth)` and the formula is centered within it:
/// `dx = (canvasWidth - contentWidth) / 2`. When the formula is narrower than the block,
/// `canvasWidth == blockWidth` and `dx` pads both sides (the "centered in the block width"
/// acceptance criterion). When wider, `canvasWidth == contentWidth` and `dx == 0` -- nothing to
/// center against, the raster already fills the full scrollable width. Either way `RenderCell`'s
/// Variant B mount (always flush at local x=0) needs no centering logic of its own.
func rasterizeMathBlock(
    _ layout: MathBlockLayout,
    blockWidth: CGFloat,
    scale: CGFloat,
    fontProvider: KaTeXFontProvider
) -> (image: CGImage?, size: CGSize) {
    switch layout {
    case .literal(let descriptor, let size):
        guard let image = rasterizeText(descriptor, layoutWidth: blockWidth, outputSize: size, scale: scale)
        else { return (nil, size) }
        return (image, size)

    case .formula(let list, let options, let metrics):
        let contentWidth = metrics.width
        let canvasWidth = max(contentWidth, blockWidth)
        let canvasHeight = metrics.height
        let dx = max(0, (canvasWidth - contentWidth) / 2)

        let pixelWidth = pixelLength(canvasWidth, scale: scale)
        let pixelHeight = pixelLength(canvasHeight, scale: scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return (nil, .zero) }

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
        ) else { return (nil, .zero) }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // Shift right by the centering offset before drawing -- orientation-independent on the
        // x-axis, so this is correct whether or not DisplayListRenderer.draw's own internal
        // flip-to-top-left has already run (it operates after this translate is on the CTM).
        ctx.translateBy(x: dx, y: 0)
        DisplayListRenderer.draw(list, in: ctx, options: options, fontProvider: fontProvider)
        guard let image = ctx.makeImage() else { return (nil, .zero) }
        return (image, CGSize(width: canvasWidth, height: canvasHeight))
    }
}
#endif

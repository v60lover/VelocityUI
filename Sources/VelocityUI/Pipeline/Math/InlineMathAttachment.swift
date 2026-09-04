// InlineMathAttachment.swift

#if canImport(UIKit)
import UIKit
import SwaTex
import SwaTexRender

/// `NSTextAttachment` subclass carrying one inline formula's typeset `DisplayList`.
///
/// Splits geometry from pixels the same way `MathBlockRasterizer` splits `layoutMathBlock`
/// (measure) from `rasterizeMathBlock` (paint):
/// - `attachmentBounds(for:proposedLineFragment:glyphPosition:characterIndex:)` is pure --
///   derived from `metrics` alone, no drawing. TextKit calls this on every layout pass,
///   including `TextMeasurementContext.measure`'s fragment-frame enumeration, so a hot-typing
///   paragraph re-measuring on every keystroke never pays draw cost for a formula it's about
///   to discard.
/// - `image(forBounds:textContainer:characterIndex:)` only runs when a fragment is actually
///   painted (`NSTextLayoutFragment.draw(at:in:)`, called from `rasterizeText`'s render pass) --
///   `TextMeasurementContext.measure` never calls `fragment.draw`, so this never fires there.
///
/// Bounds use `RenderMetrics.baseline` (top-to-baseline distance) to place the image against the
/// surrounding text's baseline: `ascent = baseline`, `descent = height - baseline`, matching
/// `NSTextAttachment.bounds`'s "origin at the baseline, positive y up" convention.
final class InlineMathAttachment: NSTextAttachment {
    private let list: DisplayList
    private let options: RenderOptions
    private let metrics: RenderMetrics
    private let fontProvider: KaTeXFontProvider
    private let scale: CGFloat

    init(
        list: DisplayList, options: RenderOptions, metrics: RenderMetrics,
        fontProvider: KaTeXFontProvider, scale: CGFloat
    ) {
        self.list = list
        self.options = options
        self.metrics = metrics
        self.fontProvider = fontProvider
        self.scale = scale
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("InlineMathAttachment does not support NSCoding")
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint, characterIndex charIndex: Int
    ) -> CGRect {
        let descent = metrics.height - metrics.baseline
        return CGRect(x: 0, y: -descent, width: metrics.width, height: metrics.height)
    }

    override func image(
        forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int
    ) -> UIImage? {
        guard let cgImage = rasterizeInlineMath(
            list: list, options: options, metrics: metrics, fontProvider: fontProvider, scale: scale
        ) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
#endif

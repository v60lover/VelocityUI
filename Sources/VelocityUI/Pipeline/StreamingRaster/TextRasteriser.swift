// TextRasteriser.swift

#if canImport(UIKit)
import UIKit
import SwaTex
import SwaTexRender

// MARK: - VContentSizeCategory <-> UIContentSizeCategory

extension VContentSizeCategory {
    /// The real UIKit category, or `nil` for `.unspecified` — callers must skip
    /// `UIFontMetrics` entirely on `nil` rather than passing `.unspecified` through.
    var uiContentSizeCategory: UIContentSizeCategory? {
        switch self {
        case .unspecified: return nil
        case .extraSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .extraLarge: return .extraLarge
        case .extraExtraLarge: return .extraExtraLarge
        case .extraExtraExtraLarge: return .extraExtraExtraLarge
        case .accessibilityMedium: return .accessibilityMedium
        case .accessibilityLarge: return .accessibilityLarge
        case .accessibilityExtraLarge: return .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: return .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: return .accessibilityExtraExtraExtraLarge
        }
    }

    /// Reverse mapping, used where a live trait environment is read. Unrecognized or
    /// `.unspecified` values both map to `.unspecified`.
    init(_ uiCategory: UIContentSizeCategory) {
        switch uiCategory {
        case .extraSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .extraLarge: self = .extraLarge
        case .extraExtraLarge: self = .extraExtraLarge
        case .extraExtraExtraLarge: self = .extraExtraExtraLarge
        case .accessibilityMedium: self = .accessibilityMedium
        case .accessibilityLarge: self = .accessibilityLarge
        case .accessibilityExtraLarge: self = .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: self = .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: self = .accessibilityExtraExtraExtraLarge
        default: self = .unspecified
        }
    }
}

// MARK: - VFontDescriptor helpers

extension VFontDescriptor {
    /// Resolves to a concrete UIFont: named family if it loads, else system font at the same
    /// size/weight, with italic traits applied. No Dynamic Type scaling -- callers needing that
    /// go through `TextDescriptor.resolvedFont(for:)`, which layers `UIFontMetrics` on top.
    var uiFont: UIFont {
        let weightRaw = Double(bitPattern: UInt64(bitPattern: Int64(weight)))
        var resolved: UIFont
        if let family, let named = UIFont(name: family, size: size) {
            resolved = named
        } else {
            resolved = UIFont.systemFont(ofSize: size, weight: UIFont.Weight(rawValue: weightRaw))
        }
        if traits.contains(.italic) {
            let symbolic = resolved.fontDescriptor.symbolicTraits.union(.traitItalic)
            if let descriptor = resolved.fontDescriptor.withSymbolicTraits(symbolic) {
                resolved = UIFont(descriptor: descriptor, size: size)
            }
        }
        return resolved
    }
}

// MARK: - TextDescriptor helpers

extension TextDescriptor {
    /// Reconstructs UIFont.Weight from its bit-pattern-encoded Int storage.
    var uiFontWeight: UIFont.Weight {
        let raw = Double(bitPattern: UInt64(bitPattern: Int64(font.weight)))
        return UIFont.Weight(rawValue: raw)
    }

    /// Resolves `font` to a concrete UIFont, then layers Dynamic Type scaling on top —
    /// driven from `self.contentSizeCategory`, never a global read.
    private var resolvedFont: UIFont {
        resolvedFont(for: font)
    }

    /// Same as `resolvedFont`, generalized so a run's own font resolves through the same path.
    fileprivate func resolvedFont(for font: VFontDescriptor) -> UIFont {
        var uiFont = font.uiFont
        if let uiCategory = contentSizeCategory.uiContentSizeCategory {
            let traits = UITraitCollection(preferredContentSizeCategory: uiCategory)
            uiFont = UIFontMetrics.default.scaledFont(for: uiFont, compatibleWith: traits)
        }
        return uiFont
    }

    /// Total left margin `leadingBarColor` reserves for its bar + gap. Zero when no bar is set —
    /// the common case, so wrap geometry is untouched for every text block that isn't a blockquote.
    var leadingIndent: CGFloat {
        guard leadingBarColor != nil else { return 0 }
        return leadingBarWidth + leadingBarGap
    }

    /// Shared across every run so multi-run text wraps as one paragraph, not one per run.
    fileprivate var paragraphStyleIfNeeded: NSParagraphStyle? {
        guard lineBreakMode != NSLineBreakMode.byWordWrapping.rawValue || lineLimit != nil
            || lineSpacing != 0 || leadingIndent != 0
        else { return nil }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = NSLineBreakMode(rawValue: lineBreakMode) ?? .byWordWrapping
        para.lineSpacing = lineSpacing
        // Same indent on the first line and wrapped continuations, so a blockquote's bar sits
        // flush against every line, not just the ones after the first.
        para.firstLineHeadIndent = leadingIndent
        para.headIndent = leadingIndent
        return para
    }

    /// Single source of truth for the attribute dictionary, shared by measure and rasterizeText
    /// so they can't diverge. Color components are display-P3, so use the displayP3 UIColor
    /// initializer, not sRGB.
    func makeAttributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: UIColor(
                displayP3Red: color.red, green: color.green, blue: color.blue, alpha: color.alpha
            )
        ]
        // 0 means "no override", not "kerning disabled" — setting .kern to 0 would turn off
        // the font's own default kerning for callers who never asked for an override.
        if kerning != 0 {
            attrs[.kern] = kerning
        }
        if underlineStyle != 0 {
            attrs[.underlineStyle] = underlineStyle
        }
        if strikethroughStyle != 0 {
            attrs[.strikethroughStyle] = strikethroughStyle
        }
        if let paragraphStyleIfNeeded {
            attrs[.paragraphStyle] = paragraphStyleIfNeeded
        }
        return attrs
    }

    /// Single-style when `runs` is empty (legacy path), otherwise each run's own attributes
    /// laid end-to-end. Shared by `measure` and `rasterizeText`, so they can't diverge.
    ///
    /// Bypass convenience: no formula cache/font provider, so an inline math run (if any)
    /// still typesets (uncached -- mirrors `SwaTexEngine.displayList(for:cache:)`'s own
    /// nil-bypass convention) and, if ever actually drawn, falls back to a fresh
    /// `KaTeXFontProvider()` (mirrors `DisplayListRenderer.draw`'s own default parameter).
    /// Existing callers that don't care about math caching keep using this; production
    /// measure/raster call the cache-aware overload below.
    var attributedString: NSAttributedString {
        attributedString(formulaCache: nil, fontProvider: nil, scale: 1)
    }

    /// Same as `attributedString`, but threads a `FormulaCache`/`KaTeXFontProvider` through to
    /// any `TextRun.mathSource` span so inline formulas typeset through the shared cache and
    /// draw through the shared font/glyph cache instead of a fresh instance per call. `scale`
    /// only matters if an attachment is ever actually drawn (`InlineMathAttachment.image(forBounds:...)`),
    /// never during pure measurement.
    func attributedString(
        formulaCache: FormulaCache?, fontProvider: KaTeXFontProvider?, scale: CGFloat
    ) -> NSAttributedString {
        guard !runs.isEmpty else {
            return NSAttributedString(string: content, attributes: makeAttributes())
        }

        let result = NSMutableAttributedString()
        let ns = content as NSString
        var cursor = 0
        for run in runs {
            let length = min(run.length, ns.length - cursor)
            guard length > 0 else { continue }
            if let mathSource = run.mathSource,
               case .formula(let list, let options, let metrics) = layoutInlineMath(
                   rawTeX: mathSource, font: run.font, color: run.color, cache: formulaCache
               ) {
                let attachment = InlineMathAttachment(
                    list: list, options: options, metrics: metrics,
                    fontProvider: fontProvider ?? KaTeXFontProvider(), scale: scale
                )
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                // Attachments don't need `.font` for their own drawing (the image IS the glyph),
                // but TextKit still consults the run's font when a formula is the ONLY content on
                // its line (no neighboring text run to anchor line metrics to) -- without it,
                // TextKit falls back to an unspecified default font's line height instead of the
                // attachment's own `attachmentBounds`. `run.makeAttributes(base:)` also carries
                // `.link` when the run has one (a formula inside a markdown link stays tappable) --
                // the parts that would visibly double-paint under an opaque image, which is none
                // of them (foreground color/underline/background are simply unused for glyph
                // U+FFFC), keeps this consistent with every other run's attribute path.
                attachmentString.addAttributes(
                    run.makeAttributes(base: self),
                    range: NSRange(location: 0, length: attachmentString.length)
                )
                result.append(attachmentString)
            } else {
                let span = ns.substring(with: NSRange(location: cursor, length: length))
                result.append(NSAttributedString(string: span, attributes: run.makeAttributes(base: self)))
            }
            cursor += length
        }
        // Under-covering runs: append the remainder in base style instead of dropping it.
        if cursor < ns.length {
            let remainder = ns.substring(from: cursor)
            result.append(NSAttributedString(string: remainder, attributes: makeAttributes()))
        }
        return result
    }
}

extension TextRun {
    /// This run's own font/color/underline/strike/background/link, plus `base`'s shared
    /// kerning and paragraph style.
    fileprivate func makeAttributes(base: TextDescriptor) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: base.resolvedFont(for: font),
            .foregroundColor: UIColor(
                displayP3Red: color.red, green: color.green, blue: color.blue, alpha: color.alpha
            )
        ]
        if base.kerning != 0 {
            attrs[.kern] = base.kerning
        }
        if underlineStyle != 0 {
            attrs[.underlineStyle] = underlineStyle
        }
        if strikethroughStyle != 0 {
            attrs[.strikethroughStyle] = strikethroughStyle
        }
        if let backgroundColor {
            attrs[.backgroundColor] = UIColor(
                displayP3Red: backgroundColor.red, green: backgroundColor.green,
                blue: backgroundColor.blue, alpha: backgroundColor.alpha
            )
        }
        if let linkURL {
            attrs[.link] = linkURL
        }
        if let paragraphStyle = base.paragraphStyleIfNeeded {
            attrs[.paragraphStyle] = paragraphStyle
        }
        return attrs
    }
}

// MARK: - rasterizeText

/// Rasterise a TextDescriptor with line-breaking laid out at `layoutWidth`, drawn into a
/// canvas of `outputSize` (typically the tight measured size). Splitting layout width from
/// canvas size keeps bitmaps tight (memory win) while making the wrap identical to what was
/// measured at `layoutWidth` — the container never re-lays-out narrower than measurement, so
/// no line can shift below the canvas and clip. The canvas width is derived from the widest
/// laid-out line plus `inkGuard`, so `outputSize.width` is a floor, not the final width.
///
/// Thread-safe: creates all TextKit 2 objects fresh per call. Pass `scale` from a @MainActor
/// call site — `UIScreen.main.scale` is off-limits off-main.
public nonisolated func rasterizeText(
    _ descriptor: TextDescriptor,
    layoutWidth: CGFloat,
    outputSize: CGSize,
    scale: CGFloat = 1,
    inkGuard: CGFloat = 2,
    formulaCache: FormulaCache? = nil,
    fontProvider: KaTeXFontProvider? = nil
) -> CGImage? {
    TextRasterizeDebugCounter.increment()
    guard outputSize.width > 0, outputSize.height > 0, layoutWidth > 0 else { return nil }

    let storage = NSTextContentStorage()
    let container = NSTextContainer(size: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude))
    // Zero TextKit's legacy 5pt-per-side inset so wrap width and glyph origin match
    // TextMeasurementContext (which also zeroes it) -- otherwise render wraps/insets 10pt tighter
    // than measurement predicted.
    container.lineFragmentPadding = 0
    container.lineBreakMode = NSLineBreakMode(rawValue: descriptor.lineBreakMode) ?? .byWordWrapping
    container.maximumNumberOfLines = descriptor.lineLimit ?? 0
    let lm = NSTextLayoutManager()
    lm.textContainer = container
    storage.addTextLayoutManager(lm)
    storage.performEditingTransaction {
        storage.attributedString = descriptor.attributedString(
            formulaCache: formulaCache, fontProvider: fontProvider, scale: scale
        )
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false

    // Canvas width = widest laid-out line + `inkGuard`. A fragment's layoutFragmentFrame width
    // is the typographic advance, which can sit a hair inside the glyph ink (bold right-side
    // bearing); a canvas exactly that wide clips the last glyph's tail — the horizontal twin of
    // the vertical clip the layout/output split already fixes. `inkGuard` is 0 via the compat
    // wrapper for the hot-block (wrapping) text path, which redraws only a tail fragment against
    // a retained image and can't tolerate the canvas growing out from under it. Round up to a
    // whole device pixel so CoreGraphics can't shave a hair rounding down.
    var widestLine: CGFloat = 0
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { fragment in
        widestLine = max(widestLine, fragment.layoutFragmentFrame.maxX)
        return true
    }
    let canvasWidth = max(outputSize.width, widestLine + inkGuard)
    let safeWidth = scale > 0 ? (canvasWidth * scale).rounded(.up) / scale : canvasWidth
    let renderSize = CGSize(width: safeWidth, height: outputSize.height)

    let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
    let uiImage = renderer.image { ctx in
        // Bar first so its flat fill can never paint over a glyph that (at some future font
        // metric) reaches slightly left of the paragraph's headIndent margin.
        if let barColor = descriptor.leadingBarColor, descriptor.leadingBarWidth > 0 {
            ctx.cgContext.setFillColor(
                red: barColor.red, green: barColor.green, blue: barColor.blue, alpha: barColor.alpha
            )
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: descriptor.leadingBarWidth, height: renderSize.height))
        }
        lm.enumerateTextLayoutFragments(
            from: lm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx.cgContext)
            return true
        }
    }
    return uiImage.cgImage
}

/// Compatibility wrapper for callers that measured and rasterize at the same width (code
/// bodies at `.greatestFiniteMagnitude`, hot-path compositing already at the layout width).
public nonisolated func rasterizeText(
    _ descriptor: TextDescriptor,
    size: CGSize,
    scale: CGFloat = 1,
    formulaCache: FormulaCache? = nil,
    fontProvider: KaTeXFontProvider? = nil
) -> CGImage? {
    rasterizeText(
        descriptor, layoutWidth: size.width, outputSize: size, scale: scale, inkGuard: 0,
        formulaCache: formulaCache, fontProvider: fontProvider
    )
}
#endif

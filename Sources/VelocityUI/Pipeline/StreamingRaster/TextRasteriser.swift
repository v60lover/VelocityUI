// TextRasteriser.swift

#if canImport(UIKit)
import UIKit

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

    /// Shared across every run so multi-run text wraps as one paragraph, not one per run.
    fileprivate var paragraphStyleIfNeeded: NSParagraphStyle? {
        guard lineBreakMode != NSLineBreakMode.byWordWrapping.rawValue || lineLimit != nil || lineSpacing != 0
        else { return nil } 
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = NSLineBreakMode(rawValue: lineBreakMode) ?? .byWordWrapping
        para.lineSpacing = lineSpacing
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
    var attributedString: NSAttributedString {
        guard !runs.isEmpty else {
            return NSAttributedString(string: content, attributes: makeAttributes())
        }

        let result = NSMutableAttributedString()
        let ns = content as NSString
        var cursor = 0
        for run in runs {
            let length = min(run.length, ns.length - cursor)
            guard length > 0 else { continue }
            let span = ns.substring(with: NSRange(location: cursor, length: length))
            result.append(NSAttributedString(string: span, attributes: run.makeAttributes(base: self)))
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
    inkGuard: CGFloat = 2
) -> CGImage? {
    guard outputSize.width > 0, outputSize.height > 0, layoutWidth > 0 else { return nil }

    let storage = NSTextContentStorage()
    let container = NSTextContainer(size: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude))
    container.lineBreakMode = NSLineBreakMode(rawValue: descriptor.lineBreakMode) ?? .byWordWrapping
    container.maximumNumberOfLines = descriptor.lineLimit ?? 0
    let lm = NSTextLayoutManager()
    lm.textContainer = container
    storage.addTextLayoutManager(lm)
    storage.performEditingTransaction {
        storage.attributedString = descriptor.attributedString
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false

    // Canvas width = widest laid-out line + `inkGuard`. A fragment's layoutFragmentFrame width
    // is the typographic advance, which can sit a hair inside the glyph ink (bold right-side
    // bearing); a canvas exactly that wide clips the last glyph's tail — the horizontal twin of
    // the vertical clip the layout/output split already fixes. `inkGuard` is 0 via the
    // compat wrapper for non-wrapping callers (code bodies, hot compositing) that need an exact
    // fit. Round up to a whole device pixel so CoreGraphics can't shave a hair rounding down.
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
    scale: CGFloat = 1
) -> CGImage? {
    rasterizeText(descriptor, layoutWidth: size.width, outputSize: size, scale: scale, inkGuard: 0)
}
#endif

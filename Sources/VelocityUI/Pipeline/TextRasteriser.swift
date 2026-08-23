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

// MARK: - TextDescriptor helpers

extension TextDescriptor {
    /// Reconstructs UIFont.Weight from its bit-pattern-encoded Int storage.
    var uiFontWeight: UIFont.Weight {
        let raw = Double(bitPattern: UInt64(bitPattern: Int64(font.weight)))
        return UIFont.Weight(rawValue: raw)
    }

    /// Resolves `font` to a concrete UIFont: named family if it loads, else system font at the
    /// same size/weight. Italic traits layer on afterward, then Dynamic Type scaling — all
    /// driven from `self.contentSizeCategory`, never a global read.
    private var resolvedFont: UIFont {
        var uiFont: UIFont
        if let family = font.family, let named = UIFont(name: family, size: font.size) {
            uiFont = named
        } else {
            uiFont = UIFont.systemFont(ofSize: font.size, weight: uiFontWeight)
        }
        if font.traits.contains(.italic) {
            let symbolic = uiFont.fontDescriptor.symbolicTraits.union(.traitItalic)
            if let descriptor = uiFont.fontDescriptor.withSymbolicTraits(symbolic) {
                uiFont = UIFont(descriptor: descriptor, size: font.size)
            }
        }
        if let uiCategory = contentSizeCategory.uiContentSizeCategory {
            let traits = UITraitCollection(preferredContentSizeCategory: uiCategory)
            uiFont = UIFontMetrics.default.scaledFont(for: uiFont, compatibleWith: traits)
        }
        return uiFont
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
        // Without this branch, a lineBreakMode-only descriptor (no lineLimit/lineSpacing) would
        // silently fall back to NSMutableParagraphStyle's default, dropping the requested mode.
        if lineBreakMode != NSLineBreakMode.byWordWrapping.rawValue || lineLimit != nil || lineSpacing != 0 {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = NSLineBreakMode(rawValue: lineBreakMode) ?? .byWordWrapping
            para.lineSpacing = lineSpacing
            attrs[.paragraphStyle] = para
        }
        return attrs
    }

    /// NSAttributedString built from `makeAttributes()`, shared with `TextMeasurementContext.measure`.
    var attributedString: NSAttributedString {
        NSAttributedString(string: content, attributes: makeAttributes())
    }
}

// MARK: - rasterizeText

/// Rasterise a TextDescriptor into a CGImage at exactly `size`, using the same TextKit 2
/// pipeline as `TextMeasurementContext` so rendered height matches measured height.
///
/// Thread-safe: creates all TextKit 2 objects fresh per call. Pass `scale` from a @MainActor
/// call site — `UIScreen.main.scale` is off-limits off-main.
public nonisolated func rasterizeText(
    _ descriptor: TextDescriptor,
    size: CGSize,
    scale: CGFloat = 1
) -> CGImage? {
    guard size.width > 0, size.height > 0 else { return nil }

    let storage = NSTextContentStorage()
    let container = NSTextContainer(size: size)
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

    let renderer = UIGraphicsImageRenderer(size: size, format: format)
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
#endif

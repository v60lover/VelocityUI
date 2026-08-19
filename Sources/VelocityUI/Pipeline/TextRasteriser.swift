// TextRasteriser.swift

#if canImport(UIKit)
import UIKit

// MARK: - VContentSizeCategory <-> UIContentSizeCategory

extension VContentSizeCategory {
    /// The real UIKit category, or `nil` for `.unspecified` — callers must skip
    /// `UIFontMetrics` entirely on `nil` rather than passing `.unspecified` through (see
    /// `VContentSizeCategory`'s doc for why that would be a hidden global read).
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

    /// Reverse mapping — used at the one place a live trait environment is read
    /// (`FeedScrollView`'s content-size-category observer). `UIContentSizeCategory.unspecified`
    /// and any future/unrecognized raw value both map to `.unspecified`.
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
    /// same size/weight (deterministic fallback, never crashes on a bad family name). Symbolic
    /// traits (e.g. italic) layer on top afterward, so italic composes with custom families too.
    /// Scaled for Dynamic Type via `UIFontMetrics` when `contentSizeCategory` isn't
    /// `.unspecified` (VelocityUI-ezo.2.5) — built entirely from `self.contentSizeCategory`,
    /// never read from `UIApplication`/`UIScreen` (CLAUDE.md §4: no global reads).
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

    /// Single source of truth for the attribute dictionary. Both
    /// TextMeasurementContext.measure and rasterizeText build their NSAttributedString
    /// from this — the two paths can no longer diverge on font/paragraph/color attributes.
    /// VColorDescriptor's components are display-P3 (see NodeTable.swift docstring), so the
    /// conversion must go through the displayP3 UIColor initializer, not the sRGB one.
    func makeAttributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
            .foregroundColor: UIColor(
                displayP3Red: color.red, green: color.green, blue: color.blue, alpha: color.alpha
            )
        ]
        // 0 means "no override" — NOT "kerning disabled". Setting .kern explicitly to 0
        // would turn off the font's own default kerning, regressing every existing caller
        // that never asked for a kerning override. Only add the attribute for a real value.
        if kerning != 0 {
            attrs[.kern] = kerning
        }
        if underlineStyle != 0 {
            attrs[.underlineStyle] = underlineStyle
        }
        if strikethroughStyle != 0 {
            attrs[.strikethroughStyle] = strikethroughStyle
        }
        // A non-default lineBreakMode must reach the paragraph style even standalone --
        // without this branch a wrapping-mode-only descriptor (no lineLimit, no lineSpacing)
        // silently falls back to NSMutableParagraphStyle's own default (.byWordWrapping),
        // dropping the requested mode on both the measure and render paths (they share this
        // attributedString builder). lineBreakMode == 0 already matches that default, so this
        // is a no-op for every caller that never set lineBreakMode.
        if lineBreakMode != NSLineBreakMode.byWordWrapping.rawValue || lineLimit != nil || lineSpacing != 0 {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = NSLineBreakMode(rawValue: lineBreakMode) ?? .byWordWrapping
            para.lineSpacing = lineSpacing
            attrs[.paragraphStyle] = para
        }
        return attrs
    }

    /// NSAttributedString built from `makeAttributes()` — same attributes used in
    /// TextMeasurementContext.measure so rendered output matches measured size.
    var attributedString: NSAttributedString {
        NSAttributedString(string: content, attributes: makeAttributes())
    }
}

// MARK: - rasterizeText

/// Rasterise a TextDescriptor into a CGImage at exactly `size`.
/// Uses the same NSTextLayoutManager pipeline as TextMeasurementContext so
/// rendered height matches measured height — the core Spike 4 contract.
///
/// Thread-safe: creates all TextKit 2 objects fresh per call.
/// `scale`: pass from @MainActor call site — UIScreen.main.scale is off-limits off-main.
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

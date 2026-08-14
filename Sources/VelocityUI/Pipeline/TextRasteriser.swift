// TextRasteriser.swift

#if canImport(UIKit)
import UIKit

// MARK: - TextDescriptor helpers

extension TextDescriptor {
    /// Reconstructs UIFont.Weight from its bit-pattern-encoded Int storage.
    var uiFontWeight: UIFont.Weight {
        let raw = Double(bitPattern: UInt64(bitPattern: Int64(font.weight)))
        return UIFont.Weight(rawValue: raw)
    }

    /// Resolves `font` to a concrete UIFont: the named family if it loads, else the system
    /// font at the same size/weight — deterministic fallback, never crashes on a missing or
    /// misspelled family. Symbolic traits (e.g. italic) are then layered on top of whichever
    /// font was resolved, so italic composes with a custom family too.
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
        if lineLimit != nil || lineSpacing != 0 {
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

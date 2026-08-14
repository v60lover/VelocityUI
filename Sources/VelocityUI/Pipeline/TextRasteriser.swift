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

    /// Single source of truth for the attribute dictionary. Both
    /// TextMeasurementContext.measure and rasterizeText build their NSAttributedString
    /// from this — the two paths can no longer diverge on font/paragraph/color attributes.
    /// VColorDescriptor's components are display-P3 (see NodeTable.swift docstring), so the
    /// conversion must go through the displayP3 UIColor initializer, not the sRGB one.
    func makeAttributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: font.size, weight: uiFontWeight),
            .foregroundColor: UIColor(
                displayP3Red: color.red, green: color.green, blue: color.blue, alpha: color.alpha
            )
        ]
        if lineLimit != nil {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = NSLineBreakMode(rawValue: lineBreakMode) ?? .byWordWrapping
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

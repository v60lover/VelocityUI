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

    /// NSAttributedString built from this descriptor — same attributes used in
    /// TextMeasurementContext.measure so rendered output matches measured size.
    var attributedString: NSAttributedString {
        let f = UIFont.systemFont(ofSize: font.size, weight: uiFontWeight)
        var attrs: [NSAttributedString.Key: Any] = [.font: f]
        if lineLimit != nil {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = NSLineBreakMode(rawValue: lineBreakMode) ?? .byWordWrapping
            attrs[.paragraphStyle] = para
        }
        return NSAttributedString(string: content, attributes: attrs)
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

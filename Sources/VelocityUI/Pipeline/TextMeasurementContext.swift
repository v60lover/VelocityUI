// TextMeasurementContext.swift

#if canImport(UIKit)
import UIKit

/// Single-owner TextKit 2 measurement unit.
/// @unchecked Sendable is safe: TextMeasurementPool guarantees exclusive
/// access — only one Task holds a context at a time via the pool semaphore.
public final class TextMeasurementContext: @unchecked Sendable {
    private let layoutManager = NSTextLayoutManager()
    private let contentStorage = NSTextContentStorage()
    private let container: NSTextContainer

    public init() {
        container = NSTextContainer(size: .zero)
        container.lineBreakMode = .byWordWrapping
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
    }

    /// Synchronous measurement — called from within a pool checkout.
    public func measure(_ descriptor: TextDescriptor, width: CGFloat) -> CGSize {
        // Built from TextDescriptor.attributedString (TextRasteriser.swift) — the single
        // attribute-building source shared with rasterizeText, so measured size can never
        // drift from rendered pixels on font/paragraph/color attributes.
        contentStorage.performEditingTransaction {
            contentStorage.attributedString = descriptor.attributedString
        }

        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        container.maximumNumberOfLines = descriptor.lineLimit ?? 0
        // Mirrors rasterizeText's container setup (TextRasteriser.swift) for defensive
        // symmetry between the two NSTextContainer configurations. Has no effect on the
        // CGSize returned below: line-breaking geometry (wrap points, fragment frames) is
        // driven by the paragraphStyle.lineBreakMode already carried on descriptor.attributedString
        // (see TextRasteriser.makeAttributes()), not by this container-level property, which
        // only selects the truncation glyph (ellipsis vs. clip) rasterizeText draws for the
        // last line -- a rendering concern measure() never observes since it returns only a size.
        container.lineBreakMode = NSLineBreakMode(rawValue: descriptor.lineBreakMode) ?? .byWordWrapping

        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            totalHeight = max(totalHeight, frame.maxY)
            maxWidth = max(maxWidth, frame.width)
            return true
        }

        return CGSize(width: min(maxWidth, width), height: totalHeight)
    }
}
#endif

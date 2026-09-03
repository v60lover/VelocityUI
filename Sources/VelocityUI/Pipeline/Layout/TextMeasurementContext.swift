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
        // Drop TextKit's legacy 5pt-per-side inset: it silently shrinks the usable wrap width by
        // 10pt, so a natural width measured at an unbounded container (where the inset can't force
        // a wrap) no longer fits inside a container sized to that same width -- text wraps one
        // glyph. Must match rasterizeText's container, which also zeroes it, so measure == render.
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
    }

    /// Synchronous measurement — called from within a pool checkout.
    public func measure(_ descriptor: TextDescriptor, width: CGFloat) -> CGSize {
        // Uses the same attributedString builder as rasterizeText, so measured size never
        // drifts from rendered pixels.
        contentStorage.performEditingTransaction {
            contentStorage.attributedString = descriptor.attributedString
        }

        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        container.maximumNumberOfLines = descriptor.lineLimit ?? 0
        // Only affects the truncation glyph drawn by rasterizeText; wrap geometry comes from
        // paragraphStyle on the attributed string, not this property, so it doesn't change the size below.
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

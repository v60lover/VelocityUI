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
        // Reconstruct UIFont.Weight from its bit-pattern-encoded Int.
        let weightRaw = Double(bitPattern: UInt64(bitPattern: Int64(descriptor.font.weight)))
        let font = UIFont.systemFont(
            ofSize: descriptor.font.size,
            weight: UIFont.Weight(rawValue: weightRaw)
        )

        let attrString = NSAttributedString(string: descriptor.content, attributes: [.font: font])
        contentStorage.performEditingTransaction {
            contentStorage.attributedString = attrString
        }

        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        container.maximumNumberOfLines = descriptor.lineLimit ?? 0

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

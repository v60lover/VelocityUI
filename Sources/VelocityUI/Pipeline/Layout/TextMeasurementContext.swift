// TextMeasurementContext.swift

#if canImport(UIKit)
import UIKit
import SwaTex

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

    /// Synchronous measurement — called from within a pool checkout. `formulaCache` threads
    /// through to any inline math run (`TextRun.mathSource`) so its typeset geometry is cached
    /// the same way a `.mathBlock` node's is (`layoutMathBlock`'s nil-bypass convention) --
    /// `nil` still typesets, just uncached. `scale: 1` is a placeholder: this context's
    /// attachments are never drawn (only their pure `attachmentBounds` are read), so the value
    /// can't affect the returned size.
    public func measure(_ descriptor: TextDescriptor, width: CGFloat, formulaCache: FormulaCache? = nil) -> CGSize {
        // Uses the same attributedString builder as rasterizeText, so measured size never
        // drifts from rendered pixels.
        contentStorage.performEditingTransaction {
            contentStorage.attributedString = descriptor.attributedString(
                formulaCache: formulaCache, fontProvider: nil, scale: 1
            )
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
            // maxX, not frame.width: a nonzero headIndent (blockquote's leading bar reservation)
            // shifts the fragment's origin right without widening its box, so width alone would
            // under-report by exactly that indent -- same measurement rasterizeText's own
            // widestLine tracking uses, so the two never disagree on how wide the text box is.
            maxWidth = max(maxWidth, frame.maxX)
            return true
        }

        return CGSize(width: min(maxWidth, width), height: totalHeight)
    }
}
#endif

// HotBlockMeasurer.swift

#if canImport(UIKit)
import UIKit

/// Measures one still-growing hot text block. On a pure append, re-measures only the
/// new suffix (O(appended)) instead of the whole block; anything else falls back to a
/// full re-measure. One instance per hot block — discard on freeze or cell recycle.
final class HotBlockMeasurer {
    /// Every `TextDescriptor` field that affects geometry except `content`. Can't use
    /// `descriptor.layoutHash` for this — it folds `content` in, so an appended suffix
    /// always changes it. This isolates "did anything besides the content change."
    private struct AttributeFingerprint: Equatable {
        let font: VFontDescriptor
        let color: VColorDescriptor
        let lineLimit: Int?
        let lineBreakMode: Int
        let underlineStyle: Int
        let strikethroughStyle: Int
        let kerning: CGFloat
        let lineSpacing: CGFloat
        let contentSizeCategory: VContentSizeCategory

        init(_ descriptor: TextDescriptor) {
            font = descriptor.font
            color = descriptor.color
            lineLimit = descriptor.lineLimit
            lineBreakMode = descriptor.lineBreakMode
            underlineStyle = descriptor.underlineStyle
            strikethroughStyle = descriptor.strikethroughStyle
            kerning = descriptor.kerning
            lineSpacing = descriptor.lineSpacing
            contentSizeCategory = descriptor.contentSizeCategory
        }
    }

    /// `internal`, not `private`: `_debugFragmentRanges()` in HotBlockMeasurer+TestHooks.swift
    /// reads this. Read-only in practice — every edit still goes through `measure(_:width:)`.
    let contentStorage = NSTextContentStorage()
    /// `internal`, not `private`: `HotBlockRasterizer` reads this to enumerate fragments
    /// for its tail-strip composite, reusing this layout manager instead of standing up
    /// a duplicate. Read-only in practice — every edit still goes through `measure(_:width:)`.
    let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer
    /// Legacy `NSTextStorage` bridge every edit goes through. Never reassigned —
    /// reassigning it tears the bridge to nil for the instance's life.
    private let storage: NSTextStorage

    private var lastContent: String = ""
    private var lastWidth: CGFloat = -1
    private var lastAttributes: AttributeFingerprint?

    init() {
        container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        // Match TextMeasurementContext and rasterizeText: zero the legacy 5pt-per-side inset so
        // the hot (streaming) measure agrees with the sealed measure and the rendered bitmap.
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        guard let storage = contentStorage.textStorage else {
            fatalError("contentStorage.textStorage is nil immediately after addTextLayoutManager — TextKit2's legacy bridge contract changed")
        }
        self.storage = storage
    }

    /// True if the next `measure(_:width:)` call for these arguments would take the
    /// incremental append path.
    func isAppendOnly(_ descriptor: TextDescriptor, width: CGFloat) -> Bool {
        guard let lastAttributes,
              lastAttributes == AttributeFingerprint(descriptor),
              width == lastWidth
        else { return false }
        return descriptor.content.hasPrefix(lastContent)
    }

    /// Measures `descriptor` at `width`, taking the O(appended) path when
    /// `isAppendOnly(_:width:)` is true. Returns height only, not tight width — a tight
    /// width needs walking every fragment; use `TextMeasurementContext` for that.
    @discardableResult
    func measure(_ descriptor: TextDescriptor, width: CGFloat) -> (height: CGFloat, appended: Bool) {
        let appended = isAppendOnly(descriptor, width: width)
        // KNOWN GAP: `makeAttributes()` uses the base font only and IGNORES `descriptor.runs`,
        // whereas TextMeasurementContext / rasterizeText measure via the run-aware
        // `attributedString`. For a block whose runs differ from the base font (e.g. a monospace
        // inline-`code` run), this hot height can diverge from the sealed/layout height — the
        // height-axis twin of the heading width bug. Not yet observed, but latent: switch this to
        // `descriptor.attributedString` if a styled hot block ever measures/paints at the wrong height.
        let attributes = descriptor.makeAttributes()

        if appended {
            // Append into existing storage so TextKit2 invalidates only the edited range.
            // Never touch container geometry here — even a same-value assignment risks
            // TextKit2 treating it as a change and invalidating everything, silently
            // reintroducing the O(block) cost this type exists to avoid.
            let delta = String(descriptor.content.dropFirst(lastContent.count))
            let attributedDelta = NSAttributedString(string: delta, attributes: attributes)
            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: attributedDelta)
            }
        } else {
            // Non-append fallback: replace the whole range. Correct here because the
            // block genuinely changed everywhere (or this is the first call).
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            container.maximumNumberOfLines = descriptor.lineLimit ?? 0
            container.lineBreakMode = NSLineBreakMode(rawValue: descriptor.lineBreakMode) ?? .byWordWrapping
            let full = NSAttributedString(string: descriptor.content, attributes: attributes)
            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: full)
            }
        }

        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let height = layoutManager.usageBoundsForTextContainer.height

        lastContent = descriptor.content
        lastWidth = width
        lastAttributes = AttributeFingerprint(descriptor)

        return (height, appended)
    }
}
#endif

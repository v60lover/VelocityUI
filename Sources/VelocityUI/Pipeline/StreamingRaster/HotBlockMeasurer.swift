// HotBlockMeasurer.swift

#if canImport(UIKit)
import UIKit
import SwaTex
import SwaTexRender

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

    /// True if `descriptor` carries any run the flat append-delta path can't handle: an
    /// attachment-bearing math run (can't be spliced across a chunk boundary — a formula may
    /// arrive as `'$x^'` then `'2$'`), or a run whose font diverges from the base font (e.g. an
    /// inline-`code` monospace span, which needs the run-aware attributed string to measure at
    /// its own height).
    private func hasAttachmentOrDivergentStyleRun(_ descriptor: TextDescriptor) -> Bool {
        descriptor.runs.contains { $0.mathSource != nil || $0.font != descriptor.font }
    }

    /// True if the next `measure(_:width:)` call for these arguments would take the
    /// incremental append path.
    func isAppendOnly(_ descriptor: TextDescriptor, width: CGFloat) -> Bool {
        guard let lastAttributes,
              lastAttributes == AttributeFingerprint(descriptor),
              width == lastWidth,
              !hasAttachmentOrDivergentStyleRun(descriptor)
        else { return false }
        return descriptor.content.hasPrefix(lastContent)
    }

    /// Measures `descriptor` at `width`, taking the O(appended) path when
    /// `isAppendOnly(_:width:)` is true. Returns height only, not tight width — a tight
    /// width needs walking every fragment; use `TextMeasurementContext` for that.
    ///
    /// `formulaCache`/`fontProvider` thread the same instances the sealed path uses
    /// (`RenderEnvironment.formulaCache`/`.mathFontProvider`) into the non-append branch's
    /// run-aware attributed string, so a hot inline formula typesets identically to its sealed
    /// render — no jump when the block freezes. `scale` is fixed at 1: attachments are never
    /// drawn during pure measurement, only sized.
    @discardableResult
    func measure(
        _ descriptor: TextDescriptor, width: CGFloat,
        formulaCache: FormulaCache? = nil, fontProvider: KaTeXFontProvider? = nil
    ) -> (height: CGFloat, appended: Bool) {
        let appended = isAppendOnly(descriptor, width: width)

        if appended {
            // Append into existing storage so TextKit2 invalidates only the edited range.
            // Never touch container geometry here — even a same-value assignment risks
            // TextKit2 treating it as a change and invalidating everything, silently
            // reintroducing the O(block) cost this type exists to avoid.
            //
            // Safe to build with the flat base-font attributes: `isAppendOnly` already ruled
            // out any attachment-bearing or divergently-styled run for this descriptor.
            let attributes = descriptor.makeAttributes()
            let delta = String(descriptor.content.dropFirst(lastContent.count))
            let attributedDelta = NSAttributedString(string: delta, attributes: attributes)
            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: attributedDelta)
            }
        } else {
            // Non-append fallback: replace the whole range. Correct here because the
            // block genuinely changed everywhere (or this is the first call, or the
            // descriptor carries a math/styled run isAppendOnly rejected above).
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            container.maximumNumberOfLines = descriptor.lineLimit ?? 0
            container.lineBreakMode = NSLineBreakMode(rawValue: descriptor.lineBreakMode) ?? .byWordWrapping
            let full = descriptor.attributedString(formulaCache: formulaCache, fontProvider: fontProvider, scale: 1)
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

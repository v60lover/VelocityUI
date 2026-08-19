// HotBlockMeasurer.swift

#if canImport(UIKit)
import UIKit

/// Incremental measure path for ONE still-growing hot text block (VelocityUI-c1uc).
///
/// `TextMeasurementContext.measure` (pooled cold/first-paint path) reassigns
/// `contentStorage.attributedString` wholesale and enumerates every fragment for height —
/// O(block size) per call, so a block growing one token at a time pays cost proportional to
/// everything measured so far, not what changed (the D1/D2/D3 problem,
/// TEXTKIT2_INCREMENTAL_RASTERIZATION_RESEARCH.md §1).
///
/// Keeps one `NSTextLayoutManager`/`NSTextContentStorage`/`NSTextContainer` alive for the
/// block's whole streaming life. A pure append (same width, same non-content attributes, new
/// content == old + suffix) appends only the delta via `replaceCharacters(in:with:)`, so
/// TextKit 2 invalidates just the edited range and keeps every earlier fragment's cached
/// geometry — O(appended). Height reads from `usageBoundsForTextContainer` after
/// `ensureLayout` (confirmed to match brute enumeration within 0.01pt — VelocityUI-q87l spike).
///
/// Falls back to a full re-measure for anything that isn't a pure append — mid-string edit,
/// width change, or any attribute change including Dynamic Type (see `AttributeFingerprint`).
/// TextKit 2 has no incremental path for these; full re-measure is correct, not a missed
/// optimization.
///
/// Lifetime is ONE hot block: construct fresh per block, discard on freeze or cell recycle to
/// a different item (no singleton, no global lookup). Pooling instances across a cell's
/// lifetime is the incremental rasterizer's job (VelocityUI-x4q0), not this type's — and this
/// type never touches `TextMeasurementContext`, the route for cold blocks and first paint.
///
/// `internal`, not `public`: only VelocityUI-x4q0 (same module) consumes it so far.
final class HotBlockMeasurer {
    /// Every `TextDescriptor` field that affects geometry EXCEPT `content` — comparing
    /// this instead of `descriptor.layoutHash` matters: `layoutHash` folds `content`
    /// itself into the hash (`TextNode.layoutHash`, Nodes.swift), so two descriptors that
    /// differ only by an appended suffix always have different `layoutHash`. This
    /// fingerprint isolates "did anything OTHER than the content change" — exactly what
    /// append-only detection needs.
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

    private let contentStorage = NSTextContentStorage()
    /// `internal` (not `private`): `HotBlockRasterizer` (VelocityUI-x4q0) reads this to enumerate
    /// ensured fragments for its tail-strip composite after each `measure(_:width:)` call, so it
    /// can reuse THIS persistent layout manager instead of standing up a second, duplicate one per
    /// hot block. Read-only in practice — no type outside this file may mutate layout manager
    /// state directly; every edit must still go through `measure(_:width:)`.
    let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer
    /// The legacy `NSTextStorage` bridge every edit goes through. Captured ONCE right after
    /// `addTextLayoutManager`, never reassigned via `contentStorage.attributedString =`
    /// afterward — confirmed on-device this deterministically tears the bridge to nil for the
    /// instance's life (real TextKit2 behavior, not a timing race). The alternative,
    /// `NSTextContentStorage.replaceContents(in:with:)`, was also rejected: it throws inserting
    /// a fresh `NSTextParagraph` at exactly `documentRange.endLocation`. Routing every edit
    /// through captured `storage` via `replaceCharacters` sidesteps both problems.
    private let storage: NSTextStorage

    private var lastContent: String = ""
    private var lastWidth: CGFloat = -1
    private var lastAttributes: AttributeFingerprint?

    init() {
        container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineBreakMode = .byWordWrapping
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        guard let storage = contentStorage.textStorage else {
            fatalError("contentStorage.textStorage is nil immediately after addTextLayoutManager — TextKit2's legacy bridge contract changed")
        }
        self.storage = storage
    }

    /// True iff the next `measure(_:width:)` call for these arguments would take the
    /// incremental append path. No side effects.
    func isAppendOnly(_ descriptor: TextDescriptor, width: CGFloat) -> Bool {
        guard let lastAttributes,
              lastAttributes == AttributeFingerprint(descriptor),
              width == lastWidth
        else { return false }
        return descriptor.content.hasPrefix(lastContent)
    }

    /// Measures `descriptor` at `width`. Takes the O(appended) path when
    /// `isAppendOnly(_:width:)` is true; otherwise full re-measure, resyncing internal state so
    /// the next call can resume incrementally.
    ///
    /// - Returns: `(height, appended)` — height only. A tight width needs walking every
    ///   fragment (the O(block) cost this type avoids); the only caller
    ///   (`FeedScrollView.applyInPlaceBlockDiff`) reads just `.height` — callers needing a
    ///   tight width use `TextMeasurementContext`.
    @discardableResult
    func measure(_ descriptor: TextDescriptor, width: CGFloat) -> (height: CGFloat, appended: Bool) {
        let appended = isAppendOnly(descriptor, width: width)
        let attributes = descriptor.makeAttributes()

        if appended {
            // The load-bearing edit: append INTO existing storage so TextKit2 invalidates
            // only the edited range. Never re-touch container geometry on this branch —
            // an equal-value `container.size` assignment risks TextKit2 treating it as a
            // geometry change and invalidating everything, silently reintroducing the
            // O(block) cost this type removes. Mirrors the q87l spike's
            // IncrementalTextProbe, which never re-touches container geometry after init
            // either.
            let delta = String(descriptor.content.dropFirst(lastContent.count))
            let attributedDelta = NSAttributedString(string: delta, attributes: attributes)
            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: attributedDelta)
            }
        } else {
            // Non-append fallback: replace the WHOLE existing range (D1-equivalent full
            // invalidation) — correct here because the block genuinely changed
            // everywhere (or this is the first call, where storage is already empty).
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

#if canImport(XCTest)
extension HotBlockMeasurer {
    /// Test-only: (rangeStart, rangeLength) UTF-16 offsets for every fragment after a
    /// full ensured walk — mirrors `FragmentInfo` in the VelocityUI-q87l spike
    /// (HotBlockRasterizerSpikeTests.swift). Lets tests compute stable-prefix /
    /// re-laid-out counts against this PRODUCTION type, not just the spike's own probe.
    func _debugFragmentRanges() -> [(start: Int, length: Int)] {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var ranges: [(Int, Int)] = []
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let start = self.contentStorage.offset(
                from: self.layoutManager.documentRange.location, to: fragment.rangeInElement.location
            )
            let length = self.contentStorage.offset(
                from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation
            )
            ranges.append((start, length))
            return true
        }
        return ranges
    }

    /// Test-only: brute enumerate-from-top height — compared against
    /// `usageBoundsForTextContainer` in the height-parity test.
    func _debugEnumerateSumHeight() -> CGFloat {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return maxY
    }
}
#endif
#endif

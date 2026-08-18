// HotBlockMeasurer.swift

#if canImport(UIKit)
import UIKit

/// Incremental measure path for ONE still-growing hot text block (VelocityUI-c1uc).
///
/// `TextMeasurementContext.measure` (the pooled, pure cold/first-paint path) reassigns
/// `contentStorage.attributedString` wholesale on every call and reads height by
/// enumerating every `NSTextLayoutFragment` from the top — both cost O(block size) per
/// call. For a block that grows one token at a time while still hot, that makes every
/// token's measure cost proportional to how much of the block already exists, not to
/// what changed (the D1/D2/D3 problem — see TEXTKIT2_INCREMENTAL_RASTERIZATION_RESEARCH.md §1).
///
/// This type keeps ONE `NSTextLayoutManager` / `NSTextContentStorage` / `NSTextContainer`
/// alive for the block's whole streaming life. When a call is a pure append of what it
/// last measured — same width, same non-content attributes, new content == old content
/// plus a suffix — it appends only the delta via `replaceCharacters(in:with:)` inside
/// `performEditingTransaction`. TextKit 2 then invalidates layout only for the edited
/// range and keeps every earlier fragment's cached geometry, so the per-token cost is
/// O(appended). Height is read via `usageBoundsForTextContainer` after
/// `ensureLayout(for: documentRange)` — a maintained running bound, not an enumeration —
/// confirmed to match a brute enumerate-from-top height within 0.01pt on an offscreen
/// container (VelocityUI-q87l spike, all 10 claims CONFIRMED).
///
/// Falls back to a full re-measure (whole-string replace, the same shape
/// `TextMeasurementContext.measure` already uses conceptually) whenever the call is NOT
/// a pure append: a non-append edit (new content doesn't start with what was last
/// measured — e.g. a mid-string insert), a container width change, or any other
/// attribute change (covers Dynamic Type: `contentSizeCategory` is one of the fields
/// compared — see `AttributeFingerprint`). All three genuinely invalidate the whole
/// block; TextKit 2 has no incremental path for them, so a full re-measure is correct,
/// not a missed optimization.
///
/// Lifetime is ONE hot block, not the process — construct a fresh instance per block
/// while it is hot, and discard it once the block freezes or the cell recycles to a
/// different item. No `static let shared`, no global lookup (CLAUDE.md: no singletons).
/// Owning/pooling instances across a cell's hot-block lifetime and wiring this into the
/// live scroll-path call site is the incremental rasterizer's job (VelocityUI-x4q0), not
/// this type's.
///
/// Does NOT touch `TextMeasurementContext` — that pooled, pure path is unchanged and
/// stays the measure route for cold blocks and first paint.
///
/// `internal`, not `public`: nothing outside this module consumes it yet. The
/// incremental rasterizer (VelocityUI-x4q0) that will own/pool these per hot block also
/// lives in `Sources/VelocityUI`, so this stays module-internal until an external call
/// site actually needs it (CLAUDE.md §7: default `internal`, promote only on demand).
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
    /// The legacy `NSTextStorage` bridge every edit (append AND full-replace alike) goes
    /// through. Captured ONCE, right after `addTextLayoutManager`, and never reassigned
    /// via `contentStorage.attributedString = ` afterward — confirmed on-device that
    /// doing so tears the bridge back down to nil for the rest of this instance's life
    /// (a real, reproducible TextKit2 behavior, not a timing race: reading
    /// `contentStorage.textStorage` a second time after a whole-string `attributedString`
    /// reassignment deterministically returns nil, even after spinning the run loop).
    /// `NSTextContentStorage.replaceContents(in:with:)` — the "no legacy bridge"
    /// alternative — was tried and rejected too: it throws an internal NSString range
    /// exception when inserting a fresh `NSTextParagraph` at exactly
    /// `documentRange.endLocation` right after an existing paragraph, an Apple-side
    /// TextKit2 edge case this type can't safely paper over. Routing every edit through
    /// this captured `storage` (both branches use `replaceCharacters`, never the
    /// `attributedString` setter) sidesteps both problems.
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

    /// Measures `descriptor` at `width`. Takes the O(appended) incremental path when
    /// `isAppendOnly(_:width:)` is true; otherwise performs a full re-measure and resyncs
    /// internal state to the new baseline so the NEXT call can resume incrementally.
    ///
    /// - Returns: `(height, appended)` — height only, no measured-width component. A
    ///   tight measured width (narrower than `width` for short lines, the way
    ///   `TextMeasurementContext.measure` computes it) requires walking every fragment,
    ///   which is exactly the O(block) enumeration cost this type exists to avoid on the
    ///   append path. The only current caller of a hot block's measured size
    ///   (`FeedScrollView.applyInPlaceBlockDiff`) already reads only `.height` from its
    ///   measure result — callers that need a tight width use `TextMeasurementContext`.
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

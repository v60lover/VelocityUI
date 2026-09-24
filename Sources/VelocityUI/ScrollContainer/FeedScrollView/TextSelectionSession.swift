// TextSelectionSession.swift

#if canImport(UIKit)
import UIKit
import SwaTex
import SwaTexRender

/// One text selection on one text node. Rebuilds a live `NSTextLayoutManager` from the same
/// attributed-string builder the rasterizer uses, so its geometry matches the pixels. Dies with
/// the selection; never touches the pooled off-main measurement path.
@MainActor
final class TextSelectionSession {
    let itemIndex: Int
    let nodeIndex: Int
    let descriptor: TextDescriptor
    /// Text draw origin in content coordinates.
    private(set) var origin: CGPoint

    private let storage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let offsetMap: TextSelectionOffsetMap
    private var anchor = NSRange(location: 0, length: 0)
    private(set) var range = NSRange(location: 0, length: 0)

    /// `wrapWidth` must be the width the rasterizer wrapped at (`textWrapWidth`).
    init(
        itemIndex: Int, nodeIndex: Int, descriptor: TextDescriptor, origin: CGPoint, wrapWidth: CGFloat,
        scale: CGFloat, formulaCache: FormulaCache?, fontProvider: KaTeXFontProvider?
    ) {
        self.itemIndex = itemIndex
        self.nodeIndex = nodeIndex
        self.descriptor = descriptor
        self.origin = origin
        let container = NSTextContainer(size: CGSize(width: wrapWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = NSLineBreakMode(rawValue: descriptor.lineBreakMode) ?? .byWordWrapping
        container.maximumNumberOfLines = descriptor.lineLimit ?? 0
        layoutManager.textContainer = container
        storage.addTextLayoutManager(layoutManager)
        var map: TextSelectionOffsetMap? = TextSelectionOffsetMap()
        let attributed = descriptor.attributedString(
            formulaCache: formulaCache, fontProvider: fontProvider, scale: scale, offsetMap: &map
        )
        offsetMap = map ?? TextSelectionOffsetMap()
        storage.attributedString = attributed
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    var isEmpty: Bool { range.length == 0 }

    /// Moves the draw origin when the hosting item shifts in content space.
    func shift(by delta: CGPoint) {
        origin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
    }

    /// Starts a selection on the word under `contentPoint`. Returns false if the point is not on text.
    func begin(at contentPoint: CGPoint) -> Bool {
        guard let index = characterIndex(at: contentPoint) else { return false }
        anchor = wordRange(containing: index)
        range = anchor
        return !isEmpty
    }

    /// Grows the selection from the initial word to the character under `contentPoint`.
    func extend(to contentPoint: CGPoint) {
        guard let index = characterIndex(at: contentPoint) else { return }
        let current = NSRange(location: index, length: 0)
        let lo = min(anchor.location, current.location)
        let hi = max(NSMaxRange(anchor), index)
        range = NSRange(location: lo, length: hi - lo)
    }

    /// Selection highlight rects in content coordinates, one per line segment.
    var selectionRects: [CGRect] {
        guard !isEmpty, let textRange = textRange(for: range) else { return [] }
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .selection, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: self.origin.x, dy: self.origin.y))
            return true
        }
        return rects
    }

    /// Raw text of the selection (never a screenshot); formulas copy as `$source$`.
    var copiedText: String {
        offsetMap.copiedText(kitRange: range, content: descriptor.content)
    }

    // MARK: - Geometry

    private func characterIndex(at contentPoint: CGPoint) -> Int? {
        // Clamp so a drag past the last line (or above the first) still lands on the nearest line.
        let usedHeight = layoutManager.usageBoundsForTextContainer.height
        let local = CGPoint(
            x: contentPoint.x - origin.x, y: min(max(contentPoint.y - origin.y, 0), max(usedHeight - 1, 0))
        )
        guard let fragment = layoutManager.textLayoutFragment(for: local) else { return nil }
        let inFragment = CGPoint(
            x: local.x - fragment.layoutFragmentFrame.minX, y: local.y - fragment.layoutFragmentFrame.minY
        )
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.maxY >= inFragment.y })
                ?? fragment.textLineFragments.last else { return nil }
        let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
        return start + line.characterIndex(for: inFragment)
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        let doc = storage.documentRange.location
        guard let lo = storage.location(doc, offsetBy: range.location),
              let hi = storage.location(doc, offsetBy: NSMaxRange(range)) else { return nil }
        return NSTextRange(location: lo, end: hi)
    }

    private func wordRange(containing index: Int) -> NSRange {
        let text = (storage.attributedString?.string ?? "") as NSString
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let i = min(index, text.length - 1)
        var found = text.rangeOfComposedCharacterSequence(at: i)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { _, r, _, stop in
            if NSLocationInRange(i, r) { found = r; stop.pointee = true }
        }
        return found
    }
}
#endif

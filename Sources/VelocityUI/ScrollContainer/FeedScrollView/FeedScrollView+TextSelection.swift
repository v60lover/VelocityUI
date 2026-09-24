// FeedScrollView+TextSelection.swift

#if canImport(UIKit)
import UIKit

extension FeedScrollView {

    /// Adds the shared long-press recognizer, the Copy menu and the highlight host layer.
    func installTextSelection() {
        textSelection.onLongPress = { [weak self] gesture in self?.handleTextLongPress(gesture) }
        addGestureRecognizer(UILongPressGestureRecognizer(
            target: textSelection, action: #selector(TextSelectionController.handleLongPress(_:))
        ))
        addInteraction(textSelection.menuInteraction)
        layer.addSublayer(textSelection.highlightLayer)
    }

    /// Non-`@objc` body so tests can drive it without a real recognizer.
    func handleTextLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began: beginLongPress(at: point)
        case .changed: textSelection.extend(to: point)
        case .ended: textSelection.presentMenu()
        case .cancelled, .failed: textSelection.clear()
        default: break
        }
    }

    /// Selectable text starts a selection; anything else goes to `onNodeLongPress`.
    func beginLongPress(at point: CGPoint) {
        textSelection.clear()
        guard let index = resolveTappedIndex(at: point), index < items.count, index < tables.count,
              let cellFrame = frameMap[index] else { return }
        let table = tables[index]
        if let hit = resolveTextNode(at: point, in: index) {
            let session = TextSelectionSession(
                itemIndex: index, nodeIndex: hit.nodeIndex, descriptor: hit.descriptor,
                origin: hit.drawRect.origin,
                wrapWidth: textWrapWidth(hit.descriptor, columnWidth: measureWidth(for: containerWidth)),
                scale: max(1, traitCollection.displayScale),
                formulaCache: environment.formulaCache, fontProvider: environment.mathFontProvider
            )
            if textSelection.begin(
                session, itemID: table.itemID, layoutHash: table.layoutHash,
                cellOrigin: cellFrame.origin, width: containerWidth, at: point
            ) { return }
        }
        let action = resolveTappedAction(at: point, in: index)
        onNodeLongPress?(items[index], action?.actionID, convert(action?.rect ?? cellFrame, to: nil))
    }

    /// Runs every layout pass (a nil check when idle). Drops the selection if its block was
    /// replaced, removed or re-wrapped; otherwise follows the item if it moved.
    func revalidateTextSelection() {
        guard textSelection.isActive, let itemID = textSelection.itemID else { return }
        guard textSelection.width == containerWidth,
              let index = tables.firstIndex(where: { $0.itemID == itemID }),
              tables[index].layoutHash == textSelection.layoutHash,
              index < resolvedFrames.count else {
            textSelection.clear()
            return
        }
        textSelection.move(toCellOrigin: resolvedFrames[index].origin)
    }
}
#endif

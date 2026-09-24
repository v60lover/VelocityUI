// TextSelectionController.swift

#if canImport(UIKit)
import UIKit

/// Owns the one active text selection of a `FeedScrollView`: the session, the highlight layers
/// and the Copy menu. Non-generic so it can be an `@objc` gesture target and menu delegate.
@MainActor
final class TextSelectionController: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
    private(set) var session: TextSelectionSession?
    private(set) var itemID: AnyHashable?
    private(set) var layoutHash = 0
    /// Container width the session wrapped at; a change means the lines re-wrapped.
    private(set) var width: CGFloat = 0
    private var cellOrigin = CGPoint.zero
    private let pasteboard: UIPasteboard

    /// Plain CALayer host for the highlight rects, added above the cells by the feed.
    let highlightLayer = CALayer()
    private(set) lazy var menuInteraction = UIEditMenuInteraction(delegate: self)
    /// Set by the feed; the long-press recognizer targets this controller.
    var onLongPress: ((UILongPressGestureRecognizer) -> Void)?

    init(pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init()
        highlightLayer.zPosition = 100
    }

    var isActive: Bool { session != nil }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) { onLongPress?(gesture) }

    /// Starts `session` on the word under `point`. Returns false (and stays inactive) if nothing selectable.
    func begin(
        _ session: TextSelectionSession, itemID: AnyHashable, layoutHash: Int, cellOrigin: CGPoint,
        width: CGFloat, at point: CGPoint
    ) -> Bool {
        guard session.begin(at: point) else { return false }
        self.session = session
        self.width = width
        self.itemID = itemID
        self.layoutHash = layoutHash
        self.cellOrigin = cellOrigin
        refreshHighlights()
        return true
    }

    func extend(to point: CGPoint) {
        guard let session else { return }
        session.extend(to: point)
        refreshHighlights()
    }

    /// Follows the item when refined heights above it move it.
    func move(toCellOrigin origin: CGPoint) {
        guard let session, origin != cellOrigin else { return }
        session.shift(by: CGPoint(x: origin.x - cellOrigin.x, y: origin.y - cellOrigin.y))
        cellOrigin = origin
        refreshHighlights()
    }

    func clear() {
        guard session != nil else { return }
        session = nil
        itemID = nil
        refreshHighlights()
        menuInteraction.dismissMenu()
    }

    /// Tap while a selection is active: inside re-opens the menu, outside deselects.
    func handleTap(at point: CGPoint) {
        if selectionBounds.insetBy(dx: -8, dy: -8).contains(point) { presentMenu() } else { clear() }
    }

    func presentMenu() {
        guard isActive else { return }
        let bounds = selectionBounds
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: bounds.midX, y: bounds.minY))
        menuInteraction.presentEditMenu(with: config)
    }

    /// Puts the raw selected text (never an image) on the pasteboard.
    func copySelection() {
        guard let session, !session.isEmpty else { return }
        pasteboard.string = session.copiedText
    }

    var selectionBounds: CGRect {
        (session?.selectionRects ?? []).reduce(CGRect.null) { $0.union($1) }
    }

    // MARK: - Highlight layers

    private func refreshHighlights() {
        let rects = session?.selectionRects ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var layers = highlightLayer.sublayers ?? []
        while layers.count > rects.count { layers.removeLast().removeFromSuperlayer() }
        while layers.count < rects.count {
            let layer = CALayer()
            layer.backgroundColor = UIColor.tintColor.withAlphaComponent(0.3).cgColor
            highlightLayer.addSublayer(layer)
            layers.append(layer)
        }
        for (layer, rect) in zip(layers, rects) { layer.frame = rect }
        CATransaction.commit()
    }

    // MARK: - UIEditMenuInteractionDelegate

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.copySelection()
        }
        return UIMenu(children: [copy])
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        selectionBounds
    }
}
#endif

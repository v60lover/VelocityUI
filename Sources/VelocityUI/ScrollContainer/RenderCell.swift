// RenderCell.swift

#if canImport(UIKit)
import UIKit

/// A CALayer-backed cell. Zero UIView. Zero CATextLayer. Zero cornerRadius/masksToBounds.
/// Rounding is done at decode time in normaliseAndRound — never on the layer.
@MainActor
public final class RenderCell {
    public let layer = CALayer()
    private var sublayers: [String: CALayer] = [:]
    private(set) var currentItemID: AnyHashable?

    public init() {
        layer.masksToBounds = false  // explicit — never implicit
    }

    // MARK: - Layout (synchronous, zero allocation on hot path)

    /// Apply pre-computed frames. Called on the scroll path — must never await.
    public func applyLayout(_ frames: [String: CGRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // no implicit animations during scroll
        for (id, frame) in frames {
            let sub: CALayer
            if let existing = sublayers[id] {
                sub = existing
            } else {
                let l = CALayer()
                l.masksToBounds = false  // NEVER masksToBounds
                l.cornerRadius = 0       // NEVER cornerRadius — round at decode time
                layer.addSublayer(l)
                sublayers[id] = l
                sub = l
            }
            sub.frame = frame
        }
        CATransaction.commit()
    }

    // MARK: - Content

    /// Apply a pre-decoded, BGRA8888-normalised image. CA will not copy_image.
    public func applyContent(id: String, image: CGImage) {
        guard let sub = sublayers[id] else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        sub.contents = image
        CATransaction.commit()
    }

    // MARK: - Reuse

    /// Called before recycling this cell to a new item.
    /// isSameItem = true: keep contents, just reposition.
    /// isSameItem = false: clear all contents and placeholder-fill.
    public func prepareForReuse(isSameItem: Bool) {
        guard !isSameItem else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in sublayers.values {
            sub.contents = nil
            sub.backgroundColor = UIColor.systemGray5.cgColor
        }
        CATransaction.commit()
        currentItemID = nil
    }

    public func bind(to itemID: AnyHashable) {
        currentItemID = itemID
    }
}
#endif

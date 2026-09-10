// InteractionOverlay.swift

#if canImport(UIKit)
import UIKit

/// Transparent view hosting tap routing and VoiceOver accessibility elements for a
/// `FeedScrollView`'s visible cells. Bare CALayer cells carry no touch or accessibility
/// support on their own — this overlay is the one UIView in the cell area that does.
///
/// Not itself an accessibility element (`isAccessibilityElement = false`); its
/// `accessibilityElements` array is populated by `FeedScrollView` with one
/// `UIAccessibilityElement` per mounted item.
final class InteractionOverlay: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(frame:)") }
}
#endif

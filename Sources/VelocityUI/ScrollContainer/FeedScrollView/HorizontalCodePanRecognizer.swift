// HorizontalCodePanRecognizer.swift

#if canImport(UIKit)
import UIKit

/// A `UIPanGestureRecognizer` that only wins on a clearly-horizontal drag; it concedes to
/// vertical scroll on everything else (vertical, diagonal, or still-ambiguous). Installed on
/// `FeedScrollView` alongside the inherited vertical `panGestureRecognizer`, wired via
/// `require(toFail:)`. A non-generic type, so it carries none of the `@objc`-in-extension
/// restrictions that apply to `FeedScrollView<Item>` itself.
///
/// Direction judging lives in `HorizontalCodePanDirectionDelegate.gestureRecognizerShouldBegin`,
/// not in a `touchesMoved` override: UIKit calls that delegate method right before the
/// recognizer transitions out of `.possible`, so returning `false` there is always a clean
/// `.possible -> .failed` move. A `touchesMoved` override that sets `state = .failed` races
/// `super.touchesMoved`'s own `.possible -> .began` transition -- once `super` has already
/// begun the gesture, `.failed` is not a legal next state for a continuous recognizer, and the
/// vertical `panGestureRecognizer` waiting on `require(toFail:)` can stay blocked.
final class HorizontalCodePanRecognizer: UIPanGestureRecognizer {
    /// Reports whether a scrollable code body sits under `point` (in the recognizer's view's
    /// coordinate space). Checked once on `.began` so a touch-down outside any code body fails
    /// immediately, instead of waiting on the direction check below.
    var hitTest: ((CGPoint) -> Bool)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state != .failed, let touch = touches.first, let view else { return }
        if hitTest?(touch.location(in: view)) != true {
            state = .failed
        }
    }
}

/// Non-generic so `FeedScrollView<Item>` (which can't host `@objc` conformances in an
/// extension of a generic class) can still own gesture-recognizer delegation. Owned as a
/// stored property on `FeedScrollView` since `UIGestureRecognizer.delegate` is `weak`.
final class HorizontalCodePanDirectionDelegate: NSObject, UIGestureRecognizerDelegate {
    /// `gestureRecognizerShouldBegin` fires right before the recognizer would leave `.possible`,
    /// once UIKit has already accumulated enough movement to consider starting -- `translation`
    /// is meaningful here without an extra hand-rolled noise threshold. Returning `false` wins
    /// vertical scroll on every non-clearly-horizontal drag (vertical, diagonal, or a tie).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
        return Self.isHorizontallyDominant(pan.translation(in: view))
    }

    /// Split out from `gestureRecognizerShouldBegin` so the direction math is unit-testable —
    /// `UIPanGestureRecognizer.setTranslation(_:in:)` is a no-op without a live touch-tracking
    /// session behind it, so a test can't drive `translation(in:)` directly; it can drive this.
    static func isHorizontallyDominant(_ translation: CGPoint) -> Bool {
        abs(translation.x) > abs(translation.y)
    }
}
#endif

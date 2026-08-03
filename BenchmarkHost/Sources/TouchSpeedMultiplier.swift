// TouchSpeedMultiplier.swift

import UIKit

/// Amplifies real finger-drag scrolling by an extra multiplier, riding alongside
/// the scroll view's own native pan gesture rather than replacing it — so real
/// momentum/deceleration and bounce still come from an actual touch, just faster
/// than a thumb alone can drag. Lets a hand-scroll reach speeds a synthetic
/// CADisplayLink-driven scroll couldn't reproduce naturally (see
/// LaunchArguments.touchSpeedMultiplier / VelocityUI-hbe item 5).
///
/// Only the direct-drag portion is amplified: momentum after the finger lifts
/// still decelerates at the scroll view's native (un-amplified) release velocity.
@MainActor
final class TouchSpeedMultiplier: NSObject, UIGestureRecognizerDelegate {

    private weak var scrollView: UIScrollView?
    private var recognizer: UIPanGestureRecognizer?
    private let extraFactor: CGFloat
    private var lastTranslationY: CGFloat = 0

    /// - Parameter multiplier: total desired speed relative to real finger movement
    ///   (e.g. 3 for 3x). Values <= 1 are a no-op — callers should skip constructing
    ///   this type entirely in that case rather than attach a dead-weight recognizer.
    init(multiplier: CGFloat) {
        self.extraFactor = multiplier - 1
    }

    func attach(to scrollView: UIScrollView) {
        self.scrollView = scrollView
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        scrollView.addGestureRecognizer(pan)
        recognizer = pan
    }

    func detach() {
        if let recognizer, let scrollView {
            scrollView.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        scrollView = nil
    }

    deinit {
        MainActor.assumeIsolated { detach() }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Must recognize alongside the scroll view's own pan gesture — this
    /// recognizer only ever adds extra offset on top, never drives on its own.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    // MARK: - Pan handling

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let scrollView else { return }
        switch gesture.state {
        case .began:
            lastTranslationY = 0
        case .changed:
            let translation = gesture.translation(in: scrollView).y
            let delta = translation - lastTranslationY
            lastTranslationY = translation
            // Native scrolling moves content opposite the finger's translation
            // delta; add extraFactor's worth of that same movement on top.
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let proposed = scrollView.contentOffset.y - delta * extraFactor
            scrollView.contentOffset.y = min(max(proposed, 0), maxY)
        default:
            break
        }
    }
}

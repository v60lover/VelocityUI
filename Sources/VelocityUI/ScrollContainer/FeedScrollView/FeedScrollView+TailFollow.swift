// FeedScrollView+TailFollow.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// How a `FeedScrollView` behaves at the tail of its content. `.off` (default) is unchanged
/// top-down scrolling. `.llmChat` adds two behaviors for an LLM-chat transcript, on top of the
/// same top-down layout — no inverted/bottom-anchored layout, no coordinate flip:
///
/// - A reserved-height tail spacer: after `pinTailSpacer()`, `contentSize.height` is floored at
///   the pinned index's top plus one viewport, so a freshly sent turn has room to rise toward the
///   top and grow into. The floor collapses on its own once real content height exceeds it.
/// - Scroll-to-bottom follow: the viewport tracks the content bottom as it grows, until the user
///   scrolls away from it, and resumes once they scroll back down.
public enum TailFollowMode: Sendable, Equatable {
    case off
    case llmChat
}

extension FeedScrollView {

    // MARK: - Reserved-height tail spacer

    /// Call once the app has appended a new turn's items (e.g. right after `items = messages`
    /// with the new user message as the last item). Reserves ~1 viewport of trailing space
    /// measured from the CURRENT last item's top, and re-engages scroll-to-bottom follow so the
    /// next layout pass scrolls there. No-op when `tailFollowMode == .off`.
    @MainActor
    public func pinTailSpacer() {
        _testHooks.pinTailSpacerCallCount += 1
        guard tailFollowMode != .off else { return }
        _tailSpacerPinIndex = items.isEmpty ? nil : items.count - 1
        _isFollowingTail = true
        setNeedsLayout()
    }

    /// Floors `naturalHeight` at the pinned turn's top plus one viewport. Returns `naturalHeight`
    /// verbatim when `tailFollowMode == .off`, no pin is active, or the pin index has no resolved
    /// frame yet — the floor only ever grows `contentSize.height`, never shrinks real content.
    /// O(1): one array index into `resolvedFrames`, no allocation — safe every layout pass.
    func tailSpacerFloor(naturalHeight: CGFloat) -> CGFloat {
        guard tailFollowMode != .off,
              let pinIndex = _tailSpacerPinIndex,
              pinIndex >= 0, pinIndex < resolvedFrames.count
        else { return naturalHeight }
        return max(naturalHeight, resolvedFrames[pinIndex].minY + bounds.height)
    }

    // MARK: - Scroll-to-bottom follow

    /// Slack, in points, within which the viewport counts as "at the bottom" — absorbs
    /// floating-point settle so a rubber-band-perfect landing doesn't read as "scrolled away".
    private var tailFollowReengageThreshold: CGFloat { 24 }

    /// Forces the viewport to the content bottom when tail-follow is engaged and nothing
    /// user-driven is in flight. Called from `layoutSubviews`, after `refineKnownFrames` commits
    /// this pass's height growth and before `updateVisibleCells` reads `contentOffset.y` — so the
    /// same pass mounts cells at the followed position instead of lagging a frame behind.
    func applyTailFollowIfNeeded() {
        guard tailFollowMode != .off, _isFollowingTail, isScrollAtRest else { return }
        let maxOffset = max(0, contentSize.height - bounds.height)
        guard contentOffset.y != maxOffset else { return }
        contentOffset.y = maxOffset
    }

    /// The `scrollViewDidScroll(_:)` delegate callback itself lives on `FeedScrollView` directly
    /// (`FeedScrollView.swift`) — `UIScrollViewDelegate` methods are `@objc`, and extensions of a
    /// generic class can't declare `@objc` members. This is the non-`@objc` body it forwards to:
    /// the one place tail-follow reads real user-scroll motion. Gated on
    /// `isDragging || isDecelerating` so `applyTailFollowIfNeeded`'s own programmatic
    /// `contentOffset` writes (neither dragging nor decelerating) never re-enter here — otherwise
    /// every followed frame would immediately read itself as "user scrolled away".
    func updateTailFollowFromUserScroll() {
        guard tailFollowMode != .off, isUserScrollMotion else { return }
        let maxOffset = max(0, contentSize.height - bounds.height)
        let distanceFromBottom = maxOffset - contentOffset.y
        _isFollowingTail = distanceFromBottom <= tailFollowReengageThreshold
    }

    /// `isDragging || isDecelerating`, overridable for tests — see
    /// `FeedScrollViewTestHooks.userScrollMotionOverride`.
    private var isUserScrollMotion: Bool {
        if let override = _testHooks.userScrollMotionOverride { return override }
        return isDragging || isDecelerating
    }
}
#endif

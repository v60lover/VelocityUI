// FeedScrollView+TailFollow.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics
import QuartzCore

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

struct FollowAnimator {
    private static let angularFrequency: CGFloat = 12
    private static let epsilon: CGFloat = 0.5
    private static let maximumFrameInterval: CFTimeInterval = 1 / 30

    private(set) var velocity: CGFloat = 0
    private var position: CGFloat?
    private var lastTick: CFTimeInterval = 0

    mutating func step(
        current: CGFloat,
        target: CGFloat,
        now: CFTimeInterval
    ) -> (offset: CGFloat, settled: Bool) {
        let boundedTarget = max(0, target)
        let boundedCurrent = min(max(0, position ?? current), boundedTarget)
        let elapsed = lastTick == 0
            ? Self.maximumFrameInterval
            : min(max(0, now - lastTick), Self.maximumFrameInterval)
        lastTick = now

        guard abs(boundedTarget - boundedCurrent) > Self.epsilon else {
            velocity = 0
            position = nil
            return (boundedTarget, true)
        }

        let displacement = boundedCurrent - boundedTarget
        let frequency = Self.angularFrequency
        let decay = exp(-frequency * elapsed)
        let velocityTerm = velocity + frequency * displacement
        let nextDisplacement = (displacement + velocityTerm * elapsed) * decay
        let nextVelocity = (velocity - frequency * velocityTerm * elapsed) * decay
        let nextOffset = boundedTarget + nextDisplacement

        guard nextOffset > 0, nextOffset < boundedTarget else {
            velocity = 0
            position = nil
            return (min(max(0, nextOffset), boundedTarget), true)
        }

        if abs(boundedTarget - nextOffset) <= Self.epsilon {
            velocity = 0
            position = nil
            return (boundedTarget, true)
        }

        velocity = nextVelocity
        position = nextOffset
        return (nextOffset, false)
    }

    mutating func reset() {
        velocity = 0
        position = nil
        lastTick = 0
    }
}

@MainActor
final class TailFollowDisplayLinkDriver {
    private var displayLink: CADisplayLink?
    private var proxy: TailFollowDisplayLinkProxy?
    private var onTick: (@MainActor (CFTimeInterval) -> Void)?

    var isRunning: Bool { displayLink != nil }

    func start(onTick: @escaping @MainActor (CFTimeInterval) -> Void) {
        guard displayLink == nil else { return }
        self.onTick = onTick
        let proxy = TailFollowDisplayLinkProxy(driver: self)
        let link = CADisplayLink(target: proxy, selector: #selector(TailFollowDisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        displayLink = link
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        onTick = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        onTick?(link.timestamp)
    }
}

@MainActor
private final class TailFollowDisplayLinkProxy: NSObject {
    private weak var driver: TailFollowDisplayLinkDriver?

    init(driver: TailFollowDisplayLinkDriver) {
        self.driver = driver
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let driver else {
            link.invalidate()
            return
        }
        driver.tick(link)
    }
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
        cancelTailFollowAnimation(resetAnimator: true)
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

    /// Starts a display-paced arc after this layout pass has committed the latest content height.
    /// Repeated layout passes only expose a fresher target; they do not drive extra spring steps.
    func applyTailFollowIfNeeded(now: CFTimeInterval = CACurrentMediaTime()) {
        guard tailFollowMode != .off, _isFollowingTail, isScrollAtRest else {
            cancelTailFollowAnimation(resetAnimator: false)
            return
        }
        guard _tailFollowDisplayLink?.isRunning != true else { return }
        let result = stepTailFollow(now: now)
        guard !result.settled else { return }
        startTailFollowDisplayLink()
    }

    /// One spring step per display refresh keeps layout work bounded by the screen cadence.
    func advanceTailFollowFromDisplayLink(now: CFTimeInterval) {
        guard tailFollowMode != .off, _isFollowingTail, isScrollAtRest else {
            cancelTailFollowAnimation(resetAnimator: false)
            return
        }
        let oldOffset = contentOffset.y
        let result = stepTailFollow(now: now)
        if result.settled { cancelTailFollowAnimation(resetAnimator: false) }
        if contentOffset.y != oldOffset { setNeedsLayout() }
    }

    private func stepTailFollow(now: CFTimeInterval) -> (offset: CGFloat, settled: Bool) {
        let maxOffset = max(0, contentSize.height - bounds.height)
        let result = _followAnimator.step(current: contentOffset.y, target: maxOffset, now: now)
        contentOffset.y = result.offset
        return result
    }

    private func startTailFollowDisplayLink() {
        let driver = _tailFollowDisplayLink ?? TailFollowDisplayLinkDriver()
        _tailFollowDisplayLink = driver
        driver.start { [weak self] timestamp in
            self?.advanceTailFollowFromDisplayLink(now: timestamp)
        }
    }

    private func cancelTailFollowAnimation(resetAnimator: Bool) {
        _tailFollowDisplayLink?.cancel()
        _tailFollowDisplayLink = nil
        if resetAnimator { _followAnimator.reset() }
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
        if isUserTracking { cancelTailFollowAnimation(resetAnimator: true) }
        let maxOffset = max(0, contentSize.height - bounds.height)
        let distanceFromBottom = maxOffset - contentOffset.y
        _isFollowingTail = distanceFromBottom <= tailFollowReengageThreshold
        if !_isFollowingTail { cancelTailFollowAnimation(resetAnimator: false) }
    }

    /// `isDragging || isDecelerating`, overridable for tests — see
    /// `FeedScrollViewTestHooks.userScrollMotionOverride`.
    private var isUserScrollMotion: Bool {
        if let override = _testHooks.userScrollMotionOverride { return override }
        return isDragging || isDecelerating
    }

    private var isUserTracking: Bool {
        if let override = _testHooks.userTrackingOverride { return override }
        return isTracking
    }
}
#endif

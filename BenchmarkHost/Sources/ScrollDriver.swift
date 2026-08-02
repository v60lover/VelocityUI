// ScrollDriver.swift

import UIKit

/// CADisplayLink-driven programmatic scroll driver for BenchmarkHost.
///
/// Drives scrollView.setContentOffset(_:animated:false) on a deterministic
/// offset trajectory using estimated velocity profiles:
/// slow-read ~300 pt/s, medium fling ~1500 pt/s, max fling ~4500 pt/s.
/// Values are chosen estimates; calibrate on first device run.
/// Note: setContentOffset bypasses UIKit gesture velocity clamping — these
/// do not correspond to UIKit's internal gesture-recognizer velocity limits.
///
/// Contract (callers must):
/// - Call start(…) and stop() on the main actor only.
/// - Not attach two ScrollDrivers to the same UIScrollView simultaneously.
///
/// Performance: sole UIKit mutation is setContentOffset(_:animated:false).
/// No UIKit animator, no gesture recognizer interference.
@MainActor
final class ScrollDriver {

    enum Profile {
        case slowRead    // 300 pt/s constant
        case mediumFling // 1500 pt/s easeOut 4 s + 1 s idle, repeat
        case maxFling    // 4500 pt/s easeOut 2 s + 0.5 s idle, repeat
    }

    private weak var scrollView: UIScrollView?
    private var profile: Profile = .mediumFling
    private var isLooping: Bool = false
    private var onEnd: (() -> Void)?
    private var displayLink: CADisplayLink?
    private var passStartTimestamp: CFTimeInterval = .nan
    private var baseOffsetY: CGFloat = 0
    private var boundedMaxOffset: CGFloat?

    // MARK: - Public API

    /// Start driving scrollView with the given profile.
    /// - Parameters:
    ///   - looping: When true the driver jumps back to the top on reaching the
    ///     bottom and continues; when false it stops and calls onEnd.
    ///   - maxOffset: When non-nil, bounds the driven range to
    ///     `min(maxOffset, contentSize.height - bounds.height)` instead of the
    ///     full content height — lets a caller confine scrolling to a sub-range
    ///     (e.g. the `replay` scenario's cache-fitting window) without a
    ///     dataset or library change.
    ///   - onEnd: Called once when !looping and the bound is reached.
    func start(
        scrollView: UIScrollView,
        profile: Profile,
        looping: Bool = true,
        maxOffset: CGFloat? = nil,
        onEnd: (() -> Void)? = nil
    ) {
        stop()
        self.scrollView = scrollView
        self.profile = profile
        self.isLooping = looping
        self.boundedMaxOffset = maxOffset
        self.onEnd = onEnd
        passStartTimestamp = .nan
        baseOffsetY = scrollView.contentOffset.y
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onEnd = nil
        boundedMaxOffset = nil
    }

    deinit {
        // @MainActor class — deinit always runs on the main actor.
        MainActor.assumeIsolated { stop() }
    }

    // MARK: - CADisplayLink tick

    @objc private func tick(_ link: CADisplayLink) {
        guard let sv = scrollView else { stop(); return }

        if passStartTimestamp.isNaN {
            passStartTimestamp = link.timestamp
        }

        let contentMaxY = max(0, sv.contentSize.height - sv.bounds.height)
        let maxY = boundedMaxOffset.map { min($0, contentMaxY) } ?? contentMaxY
        guard maxY > 0 else { return }

        let elapsed = link.timestamp - passStartTimestamp
        let targetY = min(baseOffsetY + scrollDriverOffset(profile: profile, elapsed: elapsed), maxY)
        sv.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)

        if targetY >= maxY {
            if isLooping {
                sv.setContentOffset(.zero, animated: false)
                baseOffsetY = 0
                passStartTimestamp = link.timestamp
            } else {
                let cb = onEnd
                stop()
                cb?()
            }
        }
    }
}

// MARK: - UIView scroll view search

extension UIView {
    /// Depth-first search for the first UIScrollView in the receiver's subview tree.
    /// Used by SwiftUI runtime VCs to locate the UIHostingController's inner scroll view.
    var firstScrollView: UIScrollView? {
        if let sv = self as? UIScrollView { return sv }
        for sub in subviews {
            if let found = sub.firstScrollView { return found }
        }
        return nil
    }
}

// MARK: - Pure offset functions (nonisolated — unit-testable without UIKit)

/// Returns the Y offset for elapsed time into the current pass.
/// Monotonically non-decreasing, starts at 0. Callers clamp to maxContentOffset.
nonisolated func scrollDriverOffset(profile: ScrollDriver.Profile, elapsed: CFTimeInterval) -> CGFloat {
    switch profile {
    case .slowRead:
        return CGFloat(300.0 * max(0, elapsed))
    case .mediumFling:
        return scrollDriverEaseOutOffset(elapsed: elapsed, v0: 1500, accelDuration: 4, cycleDuration: 5)
    case .maxFling:
        return scrollDriverEaseOutOffset(elapsed: elapsed, v0: 4500, accelDuration: 2, cycleDuration: 2.5)
    }
}

/// Repeating easeOut profile: v(t) = v0 * (1 − t/accelDuration) over the accel
/// phase, then idle for the remainder of each cycle.
///
/// Integral: x(t_in_phase) = v0*t − v0*t²/(2*accelDuration)
/// Distance per cycle: v0 * accelDuration / 2
nonisolated func scrollDriverEaseOutOffset(
    elapsed: CFTimeInterval,
    v0: Double,
    accelDuration: Double,
    cycleDuration: Double
) -> CGFloat {
    guard elapsed >= 0 else { return 0 }
    let distancePerCycle = v0 * accelDuration / 2.0
    let cycleIndex = floor(elapsed / cycleDuration)
    let tInCycle = elapsed - cycleIndex * cycleDuration
    let phaseOffset: Double
    if tInCycle < accelDuration {
        phaseOffset = v0 * tInCycle - v0 * tInCycle * tInCycle / (2.0 * accelDuration)
    } else {
        phaseOffset = distancePerCycle
    }
    return CGFloat(cycleIndex * distancePerCycle + phaseOffset)
}

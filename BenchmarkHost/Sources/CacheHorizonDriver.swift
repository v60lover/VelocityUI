// CacheHorizonDriver.swift

import UIKit

/// Scrolls to the bottom, then back up through the same content. Each display-link tick reports
/// the current phase so the caller can attribute events to forward or reverse scrolling.
@MainActor
final class CacheHorizonDriver {
    nonisolated static let forwardVelocity: CGFloat = 6_000
    nonisolated static let reverseVelocity: CGFloat = 3_000

    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = .nan
    private var phase: CacheHorizonPhase = .forward
    private var onPhaseChange: ((CacheHorizonPhase) -> Void)?
    private var onTick: (() -> Void)?
    private var onEnd: (() -> Void)?

    func start(
        scrollView: UIScrollView,
        onPhaseChange: @escaping (CacheHorizonPhase) -> Void,
        onTick: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        stop()
        self.scrollView = scrollView
        self.onPhaseChange = onPhaseChange
        self.onTick = onTick
        self.onEnd = onEnd
        phase = .forward
        lastTimestamp = .nan
        onPhaseChange(.forward)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onPhaseChange = nil
        onTick = nil
        onEnd = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let sv = scrollView else { stop(); return }
        defer { onTick?() }
        let dt = lastTimestamp.isNaN ? 0 : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp

        let maxY = max(0, sv.contentSize.height - sv.bounds.height)
        guard maxY > 0 else { return }
        let step = cacheHorizonStep(phase: phase, offset: sv.contentOffset.y, maxOffset: maxY, dt: dt)
        sv.setContentOffset(CGPoint(x: 0, y: step.offset), animated: false)
        if step.phase != phase {
            phase = step.phase
            onPhaseChange?(phase)
        }
        if step.finished {
            let cb = onEnd
            stop()
            cb?()
        }
    }
}

/// Pure per-tick transition: forward until the bottom, flip to reverse, finish at the top.
nonisolated func cacheHorizonStep(
    phase: CacheHorizonPhase,
    offset: CGFloat,
    maxOffset: CGFloat,
    dt: CFTimeInterval
) -> (offset: CGFloat, phase: CacheHorizonPhase, finished: Bool) {
    switch phase {
    case .forward:
        let next = min(maxOffset, offset + CacheHorizonDriver.forwardVelocity * CGFloat(dt))
        return (next, next >= maxOffset ? .reverse : .forward, false)
    case .reverse:
        let next = max(0, offset - CacheHorizonDriver.reverseVelocity * CGFloat(dt))
        return (next, .reverse, next <= 0)
    }
}

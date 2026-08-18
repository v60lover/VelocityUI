// StreamGestureCoalescer.swift

import UIKit
import VelocityUI

/// CADisplayLink-driven per-token coalescer for the `stream` scenario's "gesture-gated deferral"
/// toggle (VelocityUI-0tbi) — sibling of `StreamDriver`/`ScrollDriver`, not a modification of
/// either. Validates zgdg's proposed fix direction: while a scroll gesture is active, buffer
/// per-token parser updates instead of republishing them into SwiftUI state (which would trigger
/// `FeedScrollView.itemsDidChange` on the scroll path — the H2 root cause), then flush exactly
/// once when the gesture ends.
///
/// `isGestureActive` is injected rather than reading `UIScrollView.isTracking`/`isDragging`/
/// `isDecelerating` directly — those are read-only, gesture-recognizer-driven properties that
/// can't be set on a plain `UIScrollView` instance in a unit test, so the injection point is what
/// makes `submit`/the idle-flush transition deterministically testable without a live touch.
///
/// Contract (callers must):
/// - Call start(…)/submit(_:)/stop() on the main actor only.
/// - Not attach two coalescers driving the same token stream simultaneously.
@MainActor
final class StreamGestureCoalescer {
    private var isGestureActive: (() -> Bool)?
    private var flush: ((IncrementalMarkdownParser) -> Void)?
    private var pending: IncrementalMarkdownParser?
    private var wasGestureActive = false
    private var displayLink: CADisplayLink?

    /// Starts polling `isGestureActive` once per frame to catch the gesture-end transition even
    /// when no `submit(_:)` call lands exactly on that frame — tokens arrive at a fixed cadence
    /// (up to 20/s), and a gesture can end between two of them.
    func start(isGestureActive: @escaping () -> Bool, flush: @escaping (IncrementalMarkdownParser) -> Void) {
        stop()
        self.isGestureActive = isGestureActive
        self.flush = flush
        wasGestureActive = isGestureActive()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isGestureActive = nil
        flush = nil
        pending = nil
    }

    deinit {
        // @MainActor class — deinit always runs on the main actor.
        MainActor.assumeIsolated { stop() }
    }

    /// Submits the latest accumulated parser state. Flushes immediately when no gesture is
    /// active; otherwise buffers it (overwriting any earlier pending value) — the caller keeps
    /// accumulating the parser on every token regardless of whether this flushes.
    func submit(_ parser: IncrementalMarkdownParser) {
        guard let isGestureActive else { return }
        if isGestureActive() {
            pending = parser
        } else {
            pending = nil
            flush?(parser)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let isGestureActive else { return }
        let active = isGestureActive()
        if streamGestureCoalescerShouldFlushOnIdle(wasActive: wasGestureActive, isActive: active),
           let pending {
            self.pending = nil
            flush?(pending)
        }
        wasGestureActive = active
    }
}

// MARK: - Pure computation (nonisolated — unit-testable without CADisplayLink)

/// True exactly on the frame a gesture transitions from active to inactive — the single moment
/// `StreamGestureCoalescer` should flush a pending value. Exposed at module scope so tests can
/// drive the transition table directly, mirroring `streamDriverDueTokenCount`.
nonisolated func streamGestureCoalescerShouldFlushOnIdle(wasActive: Bool, isActive: Bool) -> Bool {
    wasActive && !isActive
}

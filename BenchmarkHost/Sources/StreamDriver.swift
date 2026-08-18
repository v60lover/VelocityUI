// StreamDriver.swift

import UIKit

/// CADisplayLink-driven token emitter for BenchmarkHost's `stream` scenario (VelocityUI-xxf7) —
/// sibling of `ScrollDriver`, not a modification of it. Tells the caller WHEN to append the next
/// token via `onToken`; holds no reference to `AsyncFeed`/`RenderEnvironment`/the parser itself —
/// the caller owns mutating its `IncrementalMarkdownParser` and pushing the update into SwiftUI
/// state, the same "Option A" pattern `StreamingMarkdownFeedIntegrationTests` exercises directly
/// against the library, feeding it through the public streaming DSL surface (VelocityUI-zuot)
/// rather than a private hook.
///
/// Contract (callers must):
/// - Call start(…) and stop() on the main actor only.
/// - Not attach two StreamDrivers concurrently (mirrors ScrollDriver's single-attachment contract).
@MainActor
final class StreamDriver {
    private var displayLink: CADisplayLink?
    private var tokens: [String] = []
    private var tokensPerSecond: Double = 20
    private var emittedCount = 0
    private var passStartTimestamp: CFTimeInterval = .nan
    private var onToken: ((String) -> Void)?
    private var onEnd: (() -> Void)?

    /// Starts emitting `tokens` at `tokensPerSecond`, calling `onToken` for each one in order as
    /// it becomes due, then `onEnd` exactly once after the last token is emitted.
    func start(
        tokens: [String],
        tokensPerSecond: Double,
        onToken: @escaping (String) -> Void,
        onEnd: @escaping () -> Void
    ) {
        stop()
        self.tokens = tokens
        self.tokensPerSecond = max(0.1, tokensPerSecond)
        self.emittedCount = 0
        self.onToken = onToken
        self.onEnd = onEnd
        passStartTimestamp = .nan
        guard !tokens.isEmpty else {
            self.onEnd = nil
            onEnd()
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onToken = nil
        onEnd = nil
    }

    deinit {
        // @MainActor class — deinit always runs on the main actor.
        MainActor.assumeIsolated { stop() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if passStartTimestamp.isNaN {
            passStartTimestamp = link.timestamp
        }
        let elapsed = link.timestamp - passStartTimestamp
        let dueCount = streamDriverDueTokenCount(elapsed: elapsed, tokensPerSecond: tokensPerSecond, totalTokens: tokens.count)
        guard dueCount > emittedCount else { return }
        for i in emittedCount..<dueCount {
            onToken?(tokens[i])
        }
        emittedCount = dueCount

        if emittedCount >= tokens.count {
            let cb = onEnd
            stop()
            cb?()
        }
    }
}

// MARK: - Pure computation (nonisolated — unit-testable without UIKit)

/// Returns how many of `totalTokens` are due to have been emitted by `elapsed` seconds into the
/// pass at a constant `tokensPerSecond` cadence. Monotonically non-decreasing, clamped to
/// `totalTokens`. A guaranteed-positive `tokensPerSecond` gate mirrors `start(...)`'s own
/// `max(0.1, …)` clamp, so this function's own contract holds even if called directly.
nonisolated func streamDriverDueTokenCount(elapsed: CFTimeInterval, tokensPerSecond: Double, totalTokens: Int) -> Int {
    guard elapsed >= 0, tokensPerSecond > 0, totalTokens > 0 else { return 0 }
    return min(totalTokens, Int(elapsed * tokensPerSecond))
}

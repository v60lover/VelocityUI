// BenchmarkOrchestrator.swift

import UIKit

/// Subset of BenchmarkHarness used by the orchestrator — lets tests inject a mock.
@MainActor
protocol BenchmarkHarnessProtocol: AnyObject {
    func startCapture(discardFirstSeconds: Double)
    func stopCapture() -> BenchmarkReport
}

extension BenchmarkHarnessProtocol {
    func startCapture() {
        startCapture(discardFirstSeconds: 0)
    }
}

/// Wires the cold/warm scenario protocol to ScrollDriver and BenchmarkHarness.
///
/// Each runtime VC calls scrollViewReady(_:) in viewDidAppear. The orchestrator
/// is only created when running headless (--runtime set via launch args); in
/// the manual RuntimePickerViewController flow, runtime VCs receive nil.
///
/// Termination: the measurement pass runs for `args.measurementDuration` seconds
/// then self-terminates via a Timer. If the driver reaches the bottom of the
/// content before the timer fires, termination happens then instead. Either way
/// `onComplete` is called once with the final BenchmarkReport.
@MainActor
final class BenchmarkOrchestrator {
    private let args: LaunchArguments
    private let harness: any BenchmarkHarnessProtocol
    private let driver = ScrollDriver()
    private var didStart = false
    private var captureTimer: Timer?
    private var captureFinished = false

    /// Called exactly once when the measurement pass ends (timer or driver reaching bottom).
    var onComplete: ((BenchmarkReport) -> Void)?

    init(args: LaunchArguments, harness: any BenchmarkHarnessProtocol) {
        self.args = args
        self.harness = harness
    }

    func scrollViewReady(_ scrollView: UIScrollView) {
        guard !didStart else { return }
        didStart = true
        switch args.scenario {
        case .cold:
            startMeasurementPass(scrollView: scrollView)
        case .warm:
            // Warm = process is warm (frameworks loaded, no first-launch jitter),
            // but viewport content is FRESH — same production path the user sees in
            // normal feed scroll. A 1s process-settle delay precedes capture; the
            // first second of frames is then discarded to absorb scroll-start transients.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.captureFinished else { return }
                self.startMeasurementPass(scrollView: scrollView, discardFirstSeconds: 1.0)
            }
        case .slowScrollFirstThreeItems:
            // Drive at slow-read velocity until item 3 becomes visible, then stop.
            // Measurement window: from start until driver reaches ~1700pt offset
            // (≈3 items at 375pt width, 1.5 AR). Gray→image transitions are counted
            // via BenchmarkHarness.recordGrayToImageTransition() wired in the runtime VC.
            // VelocityUI should show grayToImageTransitionCount = 0 once prefetch lands.
            harness.startCapture(discardFirstSeconds: 0)
            driver.start(scrollView: scrollView, profile: .slowRead, looping: false) { [weak self] in
                self?.finishCapture()
            }
            // Stop after 10s max (covers slow-read to offset ~3000pt which includes item 3).
            captureTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                self?.finishCapture()
            }
        case .maxFlingNoGray:
            // Drive at max-fling velocity (~4500 pt/s) — the physics-limited regime where
            // prefetch cannot keep up (see VelocityUI-1su.3). Decode-guaranteed placeholders
            // should keep grayToImageTransitionCount at 0 even here; thumbnailToImageTransitionCount
            // documents how often the physics fallback engaged (a perf signal, not a regression).
            harness.startCapture(discardFirstSeconds: 0)
            driver.start(scrollView: scrollView, profile: .maxFling, looping: false) { [weak self] in
                self?.finishCapture()
            }
            captureTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                self?.finishCapture()
            }
        }
    }

    /// Interrupt an in-progress measurement and return the partial report.
    /// Sets captureFinished so any pending asyncAfter warm-settle closure sees the
    /// interruption and suppresses its deferred startMeasurementPass call.
    /// Also called by tests that want to clean up after assertion.
    @discardableResult
    func stopCapture() -> BenchmarkReport {
        captureFinished = true
        captureTimer?.invalidate()
        captureTimer = nil
        driver.stop()
        return harness.stopCapture()
    }

    // MARK: - Private

    private func startMeasurementPass(scrollView: UIScrollView, discardFirstSeconds: Double = 0) {
        let profile = args.velocityProfile.driverProfile

        // Warn if the dataset is too short to fill the full measurement window.
        let required = scrollDriverOffset(profile: profile, elapsed: args.measurementDuration)
        let available = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        if CGFloat(required) > available {
            print(
                "⚠️  BenchmarkOrchestrator: content height \(Int(available))pt < required"
                + " \(Int(required))pt for \(args.measurementDuration)s at \(args.velocityProfile)"
                + " — measurement ends early; add more items with --items."
            )
        }

        harness.startCapture(discardFirstSeconds: discardFirstSeconds)

        // Single non-looping pass — no wrap-teleport, no deterministic hitch injection.
        driver.start(scrollView: scrollView, profile: profile, looping: false) { [weak self] in
            self?.finishCapture()
        }

        // Timer backstop: terminate after measurementDuration even if content is tall.
        captureTimer = Timer.scheduledTimer(
            withTimeInterval: args.measurementDuration,
            repeats: false
        ) { [weak self] _ in
            self?.finishCapture()
        }
    }

    private func finishCapture() {
        guard !captureFinished else { return }
        captureFinished = true
        let report = stopCapture()
        onComplete?(report)
    }
}

// MARK: - LaunchArguments mapping

extension LaunchArguments.VelocityProfile {
    var driverProfile: ScrollDriver.Profile {
        switch self {
        case .slow: .slowRead
        case .medium: .mediumFling
        case .max: .maxFling
        }
    }
}

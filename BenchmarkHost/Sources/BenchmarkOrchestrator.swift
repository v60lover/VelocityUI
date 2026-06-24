// BenchmarkOrchestrator.swift

import UIKit

/// Subset of BenchmarkHarness used by the orchestrator — lets tests inject a mock.
@MainActor
protocol BenchmarkHarnessProtocol: AnyObject {
    func startCapture()
    func stopCapture() -> BenchmarkReport
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
            // Priming pass at slow-read scrolls the dataset once end-to-end so
            // image caches, layout caches, and the GPU are warm before capture starts.
            driver.start(scrollView: scrollView, profile: .slowRead, looping: false) { [weak self] in
                guard let self else { return }
                scrollView.setContentOffset(.zero, animated: false)
                self.startMeasurementPass(scrollView: scrollView)
            }
        }
    }

    /// Interrupt an in-progress measurement and return the partial report.
    /// Also called by tests that want to clean up after assertion.
    @discardableResult
    func stopCapture() -> BenchmarkReport {
        captureTimer?.invalidate()
        captureTimer = nil
        driver.stop()
        return harness.stopCapture()
    }

    // MARK: - Private

    private func startMeasurementPass(scrollView: UIScrollView) {
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

        harness.startCapture()

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

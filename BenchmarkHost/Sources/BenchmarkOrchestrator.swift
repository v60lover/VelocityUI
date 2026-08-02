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
    /// Items the `replay` scenario's bounded range targets — chosen to fit
    /// inside NSCache totalCostLimit (64 MB) at the 2× decode ceiling
    /// (~1.8 MB/image ⇒ ~30 items headroom). See VelocityUI-ah8.4.
    static let replayItemCount = 30
    /// Fixed profile for the replay scenario's (uncaptured) warm-up pass,
    /// regardless of the matrix's requested velocity profile. At `.maxFling`
    /// the driver can outrun decode completion — the pipeline's deep-cancel
    /// (ImageActor.cancelInFlightPrefetches) then kills in-flight decodes of
    /// already-passed items, leaving cache holes that force decodes during the
    /// MEASURED pass — chronic no-decode violations for instrument reasons,
    /// not real regressions. `.mediumFling` keeps decode comfortably ahead of
    /// the scroll. The measured pass still uses the matrix's requested profile
    /// (args.velocityProfile). See VelocityUI-ah8.4 review finding F3.
    static let replayWarmupProfile: ScrollDriver.Profile = .mediumFling
    /// Generous, matrix-profile-independent cap on the warm-up pass — deliberately
    /// NOT derived from args.measurementDuration (which governs the MEASURED pass
    /// and can be far shorter than what a full warm-up over the bounded range
    /// needs — see VelocityUI-ah8.4 review finding F2). At replayWarmupProfile's
    /// ~600 pt/s average velocity, the realistic bound (~30 items, typically a
    /// few thousand pt) completes in ~15s; 60s leaves ~4x margin before this
    /// concludes the driver has stalled and aborts.
    static let replayWarmupBackstopSeconds: TimeInterval = 60.0
    /// Minimum wall-clock settle before the `replay` scenario's measured pass,
    /// regardless of footprint stability.
    static let replaySettleSeconds: TimeInterval = 2.0
    /// Consecutive non-growing 60 Hz footprint samples required to call the
    /// quiesce wait stable (~0.5 s of a flat/declining footprint).
    static let replayStableSampleCount = 30
    /// Hard cap on total quiesce-wait time — if in-flight work never drains,
    /// proceed anyway rather than hang the run forever.
    static let replayMaxQuiesceWaitSeconds: TimeInterval = 10.0

    private let args: LaunchArguments
    private let harness: any BenchmarkHarnessProtocol
    private let driver = ScrollDriver()
    private var didStart = false
    private var captureTimer: Timer?
    private var quiesceTimer: Timer?
    private var captureFinished = false

    // Replay-scenario quiesce-wait state, set once before scheduling quiesceTimer
    // and read only from replayQuiesceTick. Target/selector (not a Timer block
    // closure) deliberately — Timer's block parameter is @Sendable in modern
    // Foundation, which would force scrollView/bound/tracker through
    // Sendable-capture diagnostics for no runtime benefit (the timer only ever
    // fires on the main run loop this @MainActor type schedules it on). Mirrors
    // the @objc target/selector idiom already used for CADisplayLink elsewhere
    // in this file, BenchmarkHarness, and LiveMetricsCollector.
    private weak var replayScrollView: UIScrollView?
    private var replayBound: CGFloat = 0
    private var replaySettleDeadline: Date = .distantPast
    private var replayHardDeadline: Date = .distantPast
    private var replayQuiesceTracker = FootprintQuiesceTracker(requiredStableSamples: BenchmarkOrchestrator.replayStableSampleCount)

    /// Called exactly once when the measurement pass ends (timer or driver reaching bottom).
    var onComplete: ((BenchmarkReport) -> Void)?

    /// Called when the replay scenario's (uncaptured) warm-up pass fails to
    /// complete — a zero-height content size at ready time, or the driver
    /// stalling past replayWarmupBackstopSeconds. Distinct from onComplete:
    /// no harness.startCapture() has happened yet at this point, so there is
    /// no real BenchmarkReport to hand back — calling finishCapture() here
    /// would make harness.stopCapture() synthesize a garbage report (zero
    /// samples, a duration computed against an unset captureStartTime) and
    /// hand it to the caller as if it were a legitimate result. Callers
    /// (AppDelegate) should treat this as a hard failure — print and exit
    /// non-zero — not attempt to salvage a report. See VelocityUI-ah8.4
    /// review finding F2.
    var onAbort: ((String) -> Void)?

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
        case .replay:
            startReplayWarmup(scrollView: scrollView)
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
        quiesceTimer?.invalidate()
        quiesceTimer = nil
        driver.stop()
        return harness.stopCapture()
    }

    // MARK: - Private — replay scenario (VelocityUI-ah8.4)

    /// Step 1: warm-up pass over the bounded range using the normal driver —
    /// the production decode path fills each runtime's own caches. NOT
    /// captured (no harness.startCapture) since this pass is expected to decode.
    /// Always drives at replayWarmupProfile, never the matrix's requested
    /// profile — see its docstring (F3).
    private func startReplayWarmup(scrollView: UIScrollView) {
        let bound = replayRangeMaxOffset(
            contentHeight: scrollView.contentSize.height,
            itemCount: args.itemCount,
            replayItemCount: Self.replayItemCount
        )
        guard bound > 0 else {
            // contentSize.height == 0 at ready time (scrollView not yet laid
            // out) — ScrollDriver's own maxY>0 guard would otherwise leave the
            // driver spinning inert forever with onEnd never firing (F2).
            abortReplay(
                "replay bound computed as 0pt (contentSize=\(scrollView.contentSize), "
                + "itemCount=\(args.itemCount)) — scrollView not laid out yet, or itemCount invalid"
            )
            return
        }
        driver.start(scrollView: scrollView, profile: Self.replayWarmupProfile, looping: false, maxOffset: bound) { [weak self] in
            self?.beginReplayQuiesceWait(scrollView: scrollView, bound: bound)
        }
        // Captured as locals (not referenced via `Self.` inside the closure below) —
        // Timer.scheduledTimer's block parameter is @Sendable in modern Foundation,
        // and static properties on this @MainActor type carry MainActor isolation,
        // so referencing them directly from inside the closure is a genuine
        // strict-concurrency diagnostic. Local `let` copies of Sendable value types
        // sidestep it. Same rationale as the quiesce timer's target/selector idiom above.
        let backstopSeconds = Self.replayWarmupBackstopSeconds
        let warmupProfile = Self.replayWarmupProfile
        captureTimer = Timer.scheduledTimer(
            withTimeInterval: backstopSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.abortReplay(
                "replay warm-up pass did not complete within "
                + "\(Int(backstopSeconds))s (bound=\(Int(bound))pt, "
                + "profile=\(warmupProfile)) — driver stall or bound far exceeds expectations"
            )
        }
    }

    /// Step 2: return to top, then wait for BOTH a fixed 2s settle AND
    /// footprint stability (30 consecutive non-growing 60 Hz samples) before
    /// starting the measured pass — absorbs in-flight prefetches draining.
    private func beginReplayQuiesceWait(scrollView: UIScrollView, bound: CGFloat) {
        guard !captureFinished else { return }
        captureTimer?.invalidate()
        captureTimer = nil
        scrollView.setContentOffset(.zero, animated: false)

        replayScrollView = scrollView
        replayBound = bound
        replaySettleDeadline = Date().addingTimeInterval(Self.replaySettleSeconds)
        replayHardDeadline = Date().addingTimeInterval(Self.replayMaxQuiesceWaitSeconds)
        replayQuiesceTracker = FootprintQuiesceTracker(requiredStableSamples: Self.replayStableSampleCount)

        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(replayQuiesceTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        quiesceTimer = timer
    }

    @objc private func replayQuiesceTick(_ timer: Timer) {
        guard !captureFinished, let scrollView = replayScrollView else {
            timer.invalidate()
            return
        }
        let now = Date()
        if now >= replayHardDeadline {
            print(
                "⚠️  BenchmarkOrchestrator: replay quiesce wait exceeded "
                + "\(Int(Self.replayMaxQuiesceWaitSeconds))s — proceeding with capture anyway."
            )
            timer.invalidate()
            beginReplayMeasuredPass(scrollView: scrollView, bound: replayBound)
            return
        }
        let stable = replayQuiesceTracker.record(AllocationProbe.currentPhysFootprint())
        if stable && now >= replaySettleDeadline {
            timer.invalidate()
            beginReplayMeasuredPass(scrollView: scrollView, bound: replayBound)
        }
    }

    /// Step 3: the measured pass — SAME bounded range as the warm-up, this
    /// time captured, and at the matrix's requested profile (not the fixed
    /// warm-up profile). A clean replay should decode nothing (everything is
    /// already cached), so grayToImageTransitionCount/thumbnailToImageTransitionCount
    /// should read 0 for velocityui; the reporter surfaces violations in NOTES.
    private func beginReplayMeasuredPass(scrollView: UIScrollView, bound: CGFloat) {
        guard !captureFinished else { return }
        let profile = args.velocityProfile.driverProfile
        harness.startCapture(discardFirstSeconds: 0)
        driver.start(scrollView: scrollView, profile: profile, looping: false, maxOffset: bound) { [weak self] in
            self?.finishCapture()
        }
        captureTimer = Timer.scheduledTimer(
            withTimeInterval: args.measurementDuration,
            repeats: false
        ) { [weak self] _ in
            self?.finishCapture()
        }
    }

    /// Aborts the replay scenario before any real capture has started —
    /// invokes onAbort instead of finishCapture()/onComplete, since there is
    /// no BenchmarkReport worth handing back at this point (see onAbort's
    /// docstring). Idempotent against the same captureFinished guard the rest
    /// of the class uses.
    private func abortReplay(_ message: String) {
        guard !captureFinished else { return }
        captureFinished = true
        captureTimer?.invalidate()
        captureTimer = nil
        quiesceTimer?.invalidate()
        quiesceTimer = nil
        driver.stop()
        onAbort?(message)
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

// MARK: - Pure computation (internal for unit tests, replay scenario — VelocityUI-ah8.4)

/// Geometric estimate of the Y offset spanning `replayItemCount` items, derived
/// from the actual rendered content height and total item count — runtime-agnostic,
/// no dependency on per-item aspect-ratio math or library internals. Used to bound
/// the `replay` scenario's warm-up/measured range to fit inside the image cache.
nonisolated func replayRangeMaxOffset(contentHeight: CGFloat, itemCount: Int, replayItemCount: Int) -> CGFloat {
    guard itemCount > 0, contentHeight > 0 else { return 0 }
    let avgItemHeight = contentHeight / CGFloat(itemCount)
    return avgItemHeight * CGFloat(replayItemCount)
}

/// Tracks whether phys_footprint samples have stopped growing for
/// `requiredStableSamples` consecutive observations. Pure/stateful, no UIKit
/// dependency — used by the `replay` scenario's quiesce wait (BenchmarkOrchestrator).
struct FootprintQuiesceTracker {
    private var lastSample: Int?
    private(set) var consecutiveStableSamples = 0
    let requiredStableSamples: Int

    init(requiredStableSamples: Int) {
        self.requiredStableSamples = requiredStableSamples
    }

    /// Feed one new footprint sample. Returns true once `requiredStableSamples`
    /// consecutive non-growing samples have been observed in a row. Growth
    /// resets the streak; equal-or-shrinking extends it.
    @discardableResult
    mutating func record(_ sample: Int) -> Bool {
        defer { lastSample = sample }
        if let last = lastSample, sample > last {
            consecutiveStableSamples = 0
        } else {
            consecutiveStableSamples += 1
        }
        return consecutiveStableSamples >= requiredStableSamples
    }
}

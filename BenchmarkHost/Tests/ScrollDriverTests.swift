// ScrollDriverTests.swift

import XCTest
@testable import BenchmarkHost

final class ScrollDriverTests: XCTestCase {

    // MARK: - slow-read profile

    func testSlowReadZeroAtStart() {
        XCTAssertEqual(scrollDriverOffset(profile: .slowRead, elapsed: 0), 0, accuracy: 0.01)
    }

    func testSlowReadLinearRate() {
        XCTAssertEqual(scrollDriverOffset(profile: .slowRead, elapsed: 1), 300, accuracy: 0.01)
        XCTAssertEqual(scrollDriverOffset(profile: .slowRead, elapsed: 3), 900, accuracy: 0.01)
        XCTAssertEqual(scrollDriverOffset(profile: .slowRead, elapsed: 10), 3000, accuracy: 0.01)
    }

    func testSlowReadNegativeElapsedClampsToZero() {
        XCTAssertEqual(scrollDriverOffset(profile: .slowRead, elapsed: -1), 0)
    }

    func testSlowReadIsMonotonic() {
        var prev: CGFloat = -1
        for i in 0...60 {
            let t = CFTimeInterval(i) * 0.5
            let v = scrollDriverOffset(profile: .slowRead, elapsed: t)
            XCTAssertGreaterThanOrEqual(v, prev, "Non-monotonic at t=\(t)")
            prev = v
        }
    }

    // MARK: - medium-fling profile
    // v0=1500, accelDuration=4, cycleDuration=5, distancePerCycle=3000

    func testMediumFlingZeroAtStart() {
        XCTAssertEqual(scrollDriverOffset(profile: .mediumFling, elapsed: 0), 0, accuracy: 0.01)
    }

    func testMediumFlingMidAccelPhase() {
        // x(2) = 1500*2 - 1500*4/(2*4) = 3000 - 375 = 2625 … wait
        // x(t) = v0*t - v0*t^2/(2*d) = 1500*2 - 1500*4/8 = 3000 - 750 = 2250
        XCTAssertEqual(scrollDriverOffset(profile: .mediumFling, elapsed: 2), 2250, accuracy: 1.0)
    }

    func testMediumFlingEndOfAccelPhase() {
        // x(4) = 1500*4 - 1500*16/8 = 6000 - 3000 = 3000
        XCTAssertEqual(scrollDriverOffset(profile: .mediumFling, elapsed: 4), 3000, accuracy: 1.0)
    }

    func testMediumFlingIdlePhaseHoldsPosition() {
        let at4  = scrollDriverOffset(profile: .mediumFling, elapsed: 4.0)
        let at4_5 = scrollDriverOffset(profile: .mediumFling, elapsed: 4.5)
        let at4_99 = scrollDriverOffset(profile: .mediumFling, elapsed: 4.99)
        XCTAssertEqual(Double(at4), Double(at4_5),  accuracy: 0.01)
        XCTAssertEqual(Double(at4), Double(at4_99), accuracy: 0.01)
    }

    func testMediumFlingSecondCycleStart() {
        // t=5: cycleIndex=1, tInCycle=0 → offset = 1*3000 + 0 = 3000
        XCTAssertEqual(scrollDriverOffset(profile: .mediumFling, elapsed: 5), 3000, accuracy: 1.0)
    }

    func testMediumFlingSecondCycleEnd() {
        // t=9: cycleIndex=1, tInCycle=4 → offset = 1*3000 + 3000 = 6000
        XCTAssertEqual(scrollDriverOffset(profile: .mediumFling, elapsed: 9), 6000, accuracy: 1.0)
    }

    func testMediumFlingIsMonotonic() {
        var prev: CGFloat = -1
        for i in 0...200 {
            let t = CFTimeInterval(i) * 0.1
            let v = scrollDriverOffset(profile: .mediumFling, elapsed: t)
            XCTAssertGreaterThanOrEqual(v, prev - 0.001, "Non-monotonic at t=\(t)")
            prev = v
        }
    }

    // MARK: - max-fling profile
    // v0=4500, accelDuration=2, cycleDuration=2.5, distancePerCycle=4500

    func testMaxFlingZeroAtStart() {
        XCTAssertEqual(scrollDriverOffset(profile: .maxFling, elapsed: 0), 0, accuracy: 0.01)
    }

    func testMaxFlingEndOfAccelPhase() {
        // x(2) = 4500*2 - 4500*4/4 = 9000 - 4500 = 4500
        XCTAssertEqual(scrollDriverOffset(profile: .maxFling, elapsed: 2), 4500, accuracy: 1.0)
    }

    func testMaxFlingIdlePhaseHoldsPosition() {
        let at2   = scrollDriverOffset(profile: .maxFling, elapsed: 2.0)
        let at2_25 = scrollDriverOffset(profile: .maxFling, elapsed: 2.25)
        XCTAssertEqual(Double(at2), Double(at2_25), accuracy: 0.01)
    }

    func testMaxFlingSecondCycleEnd() {
        // t=5: cycleIndex=2, tInCycle=0 → base=2*4500=9000; tInCycle=0 → phaseOffset=0 → 9000
        // Actually t=5: 5/2.5=2.0 cycles, tInCycle=0 → 2*4500 + 0 = 9000
        XCTAssertEqual(scrollDriverOffset(profile: .maxFling, elapsed: 5), 9000, accuracy: 1.0)
    }

    func testMaxFlingIsMonotonic() {
        var prev: CGFloat = -1
        for i in 0...300 {
            let t = CFTimeInterval(i) * 0.05
            let v = scrollDriverOffset(profile: .maxFling, elapsed: t)
            XCTAssertGreaterThanOrEqual(v, prev - 0.001, "Non-monotonic at t=\(t)")
            prev = v
        }
    }

    // MARK: - easeOut helper — table-driven

    func testEaseOutOffsetTableDriven() {
        // v0=100, accelDuration=2, cycleDuration=3
        // x(t_in_phase) = 100t − 100t²/4 = 100t − 25t²
        // distancePerCycle = 100*2/2 = 100
        struct Case {
            let elapsed: Double
            let expected: Double
            let description: String
        }
        let cases: [Case] = [
            Case(elapsed: 0,   expected: 0,   description: "start"),
            Case(elapsed: 1,   expected: 75,  description: "t=1 in accel: 100-25=75"),
            Case(elapsed: 2,   expected: 100, description: "t=2 end of accel: 200-100=100"),
            Case(elapsed: 2.5, expected: 100, description: "t=2.5 idle: held at 100"),
            Case(elapsed: 3,   expected: 100, description: "t=3 start of cycle 2: base=100, tInCycle=0"),
            Case(elapsed: 4,   expected: 175, description: "t=4 cycle2 t=1: 100+75"),
            Case(elapsed: 5,   expected: 200, description: "t=5 cycle2 t=2: 100+100"),
        ]
        for c in cases {
            let result = scrollDriverEaseOutOffset(
                elapsed: c.elapsed,
                v0: 100,
                accelDuration: 2,
                cycleDuration: 3
            )
            XCTAssertEqual(Double(result), c.expected, accuracy: 0.1, c.description)
        }
    }

    func testEaseOutNegativeElapsedReturnsZero() {
        let result = scrollDriverEaseOutOffset(elapsed: -1, v0: 1500, accelDuration: 4, cycleDuration: 5)
        XCTAssertEqual(result, 0)
    }

    // MARK: - Canary: per-frame delta stays within expected velocity bounds

    func testSlowReadPerFrameDeltaAtSixtyHz() {
        // At 60 Hz, dt = 1/60 s. slow-read moves 300/60 = 5 pt per frame.
        let dt: CFTimeInterval = 1.0 / 60.0
        let delta = scrollDriverOffset(profile: .slowRead, elapsed: dt) -
                    scrollDriverOffset(profile: .slowRead, elapsed: 0)
        XCTAssertEqual(Double(delta), 300.0 / 60.0, accuracy: 0.01)
    }

    func testMediumFlingPeakDeltaAtSixtyHz() {
        // Peak velocity is v0=1500 pt/s at t=0+. Per-frame delta < 1500/60 = 25 pt.
        let dt: CFTimeInterval = 1.0 / 60.0
        let delta = scrollDriverOffset(profile: .mediumFling, elapsed: dt) -
                    scrollDriverOffset(profile: .mediumFling, elapsed: 0)
        XCTAssertLessThanOrEqual(Double(delta), 25.5, "Peak per-frame delta must not exceed v0/60")
    }

    func testMaxFlingPeakDeltaAtSixtyHz() {
        // Peak v0=4500 pt/s → per-frame delta ≤ 4500/60 = 75 pt.
        let dt: CFTimeInterval = 1.0 / 60.0
        let delta = scrollDriverOffset(profile: .maxFling, elapsed: dt) -
                    scrollDriverOffset(profile: .maxFling, elapsed: 0)
        XCTAssertLessThanOrEqual(Double(delta), 76.0, "Peak per-frame delta must not exceed v0/60")
    }
}

// MARK: - BenchmarkOrchestrator state-machine tests (T1 + T2 + L2)

/// Mock harness that counts startCapture() calls — verifies orchestration order.
@MainActor
private final class MockBenchmarkHarness: BenchmarkHarnessProtocol {
    var startCaptureCount = 0
    var lastDiscardSeconds: Double = 0

    func startCapture(discardFirstSeconds: Double) {
        startCaptureCount += 1
        lastDiscardSeconds = discardFirstSeconds
    }

    func stopCapture() -> BenchmarkReport {
        BenchmarkReport(
            runtime: "mock",
            captureDurationSeconds: 0,
            frameStats: .init(totalFrames: 0, hitchCount: 0, hitchesPerThousand: 0,
                              p50FrameTimeMs: 0, p99FrameTimeMs: 0, maxFrameTimeMs: 0,
                              sustainedFrameRateHz: 0),
            memoryStats: .init(peakPhysFootprintBytes: 0, avgAllocDeltaPerFrameBytes: 0, netAllocDeltaPerFrameBytes: 0),
            taskSpawnCount: 0,
            metricKitSnapshots: []
        )
    }
}

@MainActor
final class BenchmarkOrchestratorTests: XCTestCase {

    // T1 — cold: harness.startCapture() called synchronously on scrollViewReady
    func testColdScenarioStartsCaptureImmediately() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(
            args: LaunchArguments(scenario: .cold),
            harness: harness
        )
        let sv = makeScrollView(contentHeight: 2_000)
        orchestrator.scrollViewReady(sv)
        XCTAssertEqual(harness.startCaptureCount, 1, "cold: startCapture must fire on scrollViewReady")
        orchestrator.stopCapture()
    }

    // T1 — warm: startCapture deferred by 1s settle delay; must be zero immediately after scrollViewReady
    func testWarmScenarioDefersCaptureBySettleDelay() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(
            args: LaunchArguments(scenario: .warm),
            harness: harness
        )
        let sv = makeScrollView(contentHeight: 2_000)
        orchestrator.scrollViewReady(sv)
        XCTAssertEqual(harness.startCaptureCount, 0,
            "warm: startCapture must not fire synchronously — 1s settle delay is pending")
        // Advance past the 1s asyncAfter.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        XCTAssertEqual(harness.startCaptureCount, 1,
            "warm: startCapture must fire after the 1s settle delay")
        XCTAssertEqual(harness.lastDiscardSeconds, 1.0, accuracy: 0.001,
            "warm: discardFirstSeconds must be 1.0 so the first-second of scroll is discarded")
        orchestrator.stopCapture()
    }

    // Cancellation during the warm settle window: stopCapture called before the 1s
    // asyncAfter fires must suppress the deferred measurement pass entirely.
    func testWarmScenarioStopCaptureBeforeSettleDelaySuppressesMeasurement() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(args: LaunchArguments(scenario: .warm), harness: harness)
        let sv = makeScrollView(contentHeight: 2_000)
        orchestrator.scrollViewReady(sv)
        XCTAssertEqual(harness.startCaptureCount, 0, "precondition: warm defers capture")
        orchestrator.stopCapture()                       // caller interrupts during settle
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))  // past 1s asyncAfter
        XCTAssertEqual(harness.startCaptureCount, 0,
            "warm: stopCapture during settle must suppress the deferred measurement pass")
    }

    // L2 — idempotency: second scrollViewReady is a no-op after the guard
    func testScrollViewReadyIsIdempotent() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(
            args: LaunchArguments(scenario: .cold),
            harness: harness
        )
        let sv = makeScrollView(contentHeight: 2_000)
        orchestrator.scrollViewReady(sv)
        orchestrator.scrollViewReady(sv)
        XCTAssertEqual(harness.startCaptureCount, 1, "second scrollViewReady must not restart capture")
        orchestrator.stopCapture()
    }

    // T2 — empty-scroll canary: driver guard maxY > 0 keeps offset at zero
    func testDriverInertOnEmptyScrollView() {
        // contentHeight == bounds.height → maxY = 0 → tick() guard returns early
        let sv = makeScrollView(contentHeight: 200)
        let driver = ScrollDriver()
        driver.start(scrollView: sv, profile: .mediumFling, looping: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(sv.contentOffset.y, 0, accuracy: 0.01, "driver must not move a scroll view with maxY=0")
        driver.stop()
    }

    // MARK: - stream scenario (VelocityUI-xxf7)

    func testStreamReadyStartsCaptureAndEmitsTokensInOrder() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(args: LaunchArguments(scenario: .stream), harness: harness)
        var received: [String] = []
        orchestrator.streamReady(tokens: ["a", "b", "c"], tokensPerSecond: 1_000) { received.append($0) }
        XCTAssertEqual(harness.startCaptureCount, 1, "stream: startCapture must fire synchronously on streamReady")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(received, ["a", "b", "c"])
        orchestrator.stopCapture()
    }

    func testStreamReadyIsIdempotent() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(args: LaunchArguments(scenario: .stream), harness: harness)
        orchestrator.streamReady(tokens: ["a"], tokensPerSecond: 1_000) { _ in }
        orchestrator.streamReady(tokens: ["a"], tokensPerSecond: 1_000) { _ in }
        XCTAssertEqual(harness.startCaptureCount, 1, "second streamReady must not restart capture")
        orchestrator.stopCapture()
    }

    // Regression guard for the didStartStream/didStart split: streamReady must not be blocked by
    // a prior scrollViewReady call (and vice versa) — the two entry points are independent so a
    // StreamBenchmarkViewController that only ever calls streamReady can't accidentally be
    // starved by a `didStart` some other code path already flipped.
    func testStreamReadyIsIndependentOfScrollViewReadyGuard() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(args: LaunchArguments(scenario: .cold), harness: harness)
        let sv = makeScrollView(contentHeight: 2_000)
        orchestrator.scrollViewReady(sv)
        XCTAssertEqual(harness.startCaptureCount, 1)
        orchestrator.streamReady(tokens: ["a"], tokensPerSecond: 1_000) { _ in }
        XCTAssertEqual(harness.startCaptureCount, 2,
            "streamReady must not be blocked by scrollViewReady's separate didStart guard")
        orchestrator.stopCapture()
    }

    // MARK: - replay scenario (VelocityUI-ah8.4): startCapture must not fire synchronously

    // Warm-up must complete (and quiesce-wait pass) before the measured
    // harness.startCapture — verifying only the synchronous precondition here;
    // full Timer-driven sequencing is exercised by the bead's simulator
    // integration pass, not a fast unit test (see design notes).
    func testReplayScenarioDoesNotStartCaptureImmediately() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(
            args: LaunchArguments(scenario: .replay),
            harness: harness
        )
        let sv = makeScrollView(contentHeight: 20_000)
        orchestrator.scrollViewReady(sv)
        XCTAssertEqual(harness.startCaptureCount, 0,
            "replay: startCapture must not fire synchronously — warm-up + quiesce wait precede it")
        orchestrator.stopCapture()
    }

    // MARK: - replay scenario warm-up backstop + abort (VelocityUI-ah8.4 review F2)

    // Regression guard for review finding F2: the warm-up backstop timer was
    // originally sized to args.measurementDuration, which deterministically
    // fired mid-warm-up for slow×replay at defaults (~30.8s of warm-up vs a
    // 30s measurementDuration), calling finishCapture() -> harness.stopCapture()
    // with NO prior startCapture and silently writing a garbage report to disk
    // as if it were a legitimate result. A short measurementDuration here would
    // have fired the OLD buggy backstop almost immediately; the fixed backstop
    // must ignore it entirely.
    func testReplayWarmupBackstopIsIndependentOfMeasurementDuration() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(
            args: LaunchArguments(scenario: .replay, measurementDuration: 0.05),
            harness: harness
        )
        var abortMessage: String?
        orchestrator.onAbort = { abortMessage = $0 }
        let sv = makeScrollView(contentHeight: 20_000)
        orchestrator.scrollViewReady(sv)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertNil(abortMessage,
            "warm-up backstop must not be keyed to measurementDuration — it fired within 0.3s of a 0.05s duration")
        XCTAssertEqual(harness.startCaptureCount, 0,
            "no capture should have started — warm-up + quiesce wait still pending")
        orchestrator.stopCapture()
    }

    // Regression guard for review finding F2's contentSize==0 edge: the driver's
    // own maxY>0 guard leaves it permanently inert when contentSize.height is 0
    // at ready time (not yet laid out), so onEnd never fires and the OLD code
    // would silently wait out the entire backstop before emitting garbage. The
    // fix must detect this synchronously and abort immediately.
    func testReplayAbortsImmediatelyWhenContentSizeIsZero() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(args: LaunchArguments(scenario: .replay), harness: harness)
        var abortMessage: String?
        orchestrator.onAbort = { abortMessage = $0 }
        let sv = makeScrollView(contentHeight: 0)  // not yet laid out
        orchestrator.scrollViewReady(sv)
        XCTAssertNotNil(abortMessage,
            "zero contentSize must abort immediately, not hang until the 60s backstop")
        XCTAssertEqual(harness.startCaptureCount, 0)
    }

    // onAbort (not onComplete) must fire for the abort path — asserting this
    // distinguishes the fix from a version that merely calls finishCapture()
    // with better messaging (which would still hand back a garbage report).
    func testReplayAbortDoesNotInvokeOnComplete() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(args: LaunchArguments(scenario: .replay), harness: harness)
        var completedReport: BenchmarkReport?
        var abortMessage: String?
        orchestrator.onComplete = { completedReport = $0 }
        orchestrator.onAbort = { abortMessage = $0 }
        let sv = makeScrollView(contentHeight: 0)
        orchestrator.scrollViewReady(sv)
        XCTAssertNotNil(abortMessage)
        XCTAssertNil(completedReport, "abort must not synthesize a BenchmarkReport via onComplete")
    }

    // MARK: - replay scenario fixed warm-up profile (VelocityUI-ah8.4 review F3)

    // Regression guard for review finding F3: the warm-up pass must always
    // drive at replayWarmupProfile (mediumFling), never args.velocityProfile.
    // At maxFling the warm-up would outrun decode completion, and the
    // pipeline's deep-cancel would leave cache holes that force decodes during
    // the MEASURED pass — chronic no-decode violations for instrument reasons.
    // Asserted by distance traveled: mediumFling and maxFling diverge sharply
    // within their shared accel phase (v0=1500 vs v0=4500), so if the matrix's
    // .max profile leaked into the warm-up, the driven offset at t=1.0s would
    // land far above what mediumFling alone produces.
    func testReplayWarmupAlwaysUsesFixedProfileRegardlessOfMatrixProfile() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(
            args: LaunchArguments(scenario: .replay, velocityProfile: .max, itemCount: 1_000),
            harness: harness
        )
        // contentHeight/itemCount=1000 * replayItemCount=30 → bound=6_000pt —
        // comfortably beyond what either profile covers by t=1.0s, so the
        // sampled offset reflects in-flight velocity, not a completed pass.
        let sv = makeScrollView(contentHeight: 200_000)
        orchestrator.scrollViewReady(sv)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))

        // mediumFling@t=1.0 ≈ 1312.5pt (v0=1500, accelDuration=4: 1500·1 − 1500·1²/8).
        // maxFling@t=1.0   ≈ 3375pt   (v0=4500, accelDuration=2: 4500·1 − 4500·1²/4).
        XCTAssertGreaterThan(sv.contentOffset.y, 0, "warm-up must have started moving")
        XCTAssertLessThan(sv.contentOffset.y, 2_500,
            "warm-up offset at t=1.0s is consistent with maxFling leaking into the warm-up pass — "
            + "expected mediumFling's ~1312pt, not maxFling's ~3375pt")
        orchestrator.stopCapture()
    }

    // MARK: - maxOffset bounding (VelocityUI-ah8.4)

    func testMaxOffsetBoundsDriverBelowFullContentHeight() {
        // contentHeight=20_000, bounds.height=200 → full maxY=19_800. Bound to 1_000.
        let sv = makeScrollView(contentHeight: 20_000)
        let driver = ScrollDriver()
        var didEnd = false
        driver.start(scrollView: sv, profile: .maxFling, looping: false, maxOffset: 1_000) {
            didEnd = true
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        XCTAssertTrue(didEnd, "driver must call onEnd on reaching the bounded maxOffset")
        XCTAssertEqual(sv.contentOffset.y, 1_000, accuracy: 1.0,
            "driver must stop at maxOffset, not the full content height")
        driver.stop()
    }

    func testMaxOffsetLargerThanContentClampsToContentHeight() {
        // Full maxY = 800. A maxOffset larger than that must not push past content bounds.
        let sv = makeScrollView(contentHeight: 1_000)
        let driver = ScrollDriver()
        var didEnd = false
        driver.start(scrollView: sv, profile: .maxFling, looping: false, maxOffset: 50_000) {
            didEnd = true
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
        XCTAssertTrue(didEnd)
        XCTAssertEqual(sv.contentOffset.y, 800, accuracy: 1.0)
        driver.stop()
    }

    private func makeScrollView(contentHeight: CGFloat) -> UIScrollView {
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        sv.contentSize = CGSize(width: 100, height: contentHeight)
        return sv
    }
}

// MARK: - replayRangeMaxOffset (VelocityUI-ah8.4)

final class ReplayRangeMaxOffsetTests: XCTestCase {
    func testComputesProportionalOffset() {
        // 1000 items over 100_000pt content → 100pt/item avg. 30 items → 3_000pt.
        let offset = replayRangeMaxOffset(contentHeight: 100_000, itemCount: 1_000, replayItemCount: 30)
        XCTAssertEqual(offset, 3_000, accuracy: 0.01)
    }

    func testZeroItemCountReturnsZero() {
        XCTAssertEqual(replayRangeMaxOffset(contentHeight: 1_000, itemCount: 0, replayItemCount: 30), 0)
    }

    func testZeroContentHeightReturnsZero() {
        XCTAssertEqual(replayRangeMaxOffset(contentHeight: 0, itemCount: 100, replayItemCount: 30), 0)
    }

    func testReplayItemCountLargerThanDatasetStillScalesLinearly() {
        // 10 items over 1_000pt content → 100pt/item. Asking for 30 (> itemCount)
        // is the caller's choice — the function just scales, callers/driver clamp
        // to actual content height separately (ScrollDriver.maxOffset already does).
        let offset = replayRangeMaxOffset(contentHeight: 1_000, itemCount: 10, replayItemCount: 30)
        XCTAssertEqual(offset, 3_000, accuracy: 0.01)
    }
}

// MARK: - FootprintQuiesceTracker (VelocityUI-ah8.4)

final class FootprintQuiesceTrackerTests: XCTestCase {
    func testStableAfterRequiredNonGrowingSamples() {
        var tracker = FootprintQuiesceTracker(requiredStableSamples: 3)
        XCTAssertFalse(tracker.record(100))
        XCTAssertFalse(tracker.record(100))
        XCTAssertTrue(tracker.record(100), "third non-growing sample must report stable")
    }

    func testGrowthResetsStreak() {
        var tracker = FootprintQuiesceTracker(requiredStableSamples: 3)
        XCTAssertFalse(tracker.record(100))
        XCTAssertFalse(tracker.record(100))
        XCTAssertFalse(tracker.record(150), "growth must reset the streak")
        // Reset lands the streak at 0 (not 1) — 3 more non-growing calls are
        // needed to reach requiredStableSamples again, same as a fresh tracker.
        XCTAssertFalse(tracker.record(150))
        XCTAssertFalse(tracker.record(150))
        XCTAssertTrue(tracker.record(150), "streak must rebuild after the reset")
    }

    func testShrinkingSamplesCountAsStable() {
        var tracker = FootprintQuiesceTracker(requiredStableSamples: 2)
        XCTAssertFalse(tracker.record(1_000))
        XCTAssertTrue(tracker.record(900), "a shrinking sample (eviction) must count toward stability")
    }

    func testFirstSampleNeverStableForMultiSampleRequirement() {
        var tracker = FootprintQuiesceTracker(requiredStableSamples: 2)
        XCTAssertFalse(tracker.record(42), "a single sample can't satisfy a 2-sample requirement")
    }
}

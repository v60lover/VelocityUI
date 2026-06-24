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

    func startCapture() { startCaptureCount += 1 }

    func stopCapture() -> BenchmarkReport {
        BenchmarkReport(
            runtime: "mock",
            captureDurationSeconds: 0,
            frameStats: .init(totalFrames: 0, hitchCount: 0, hitchesPerThousand: 0,
                              p50FrameTimeMs: 0, p99FrameTimeMs: 0, maxFrameTimeMs: 0,
                              sustainedFrameRateHz: 0),
            memoryStats: .init(peakPhysFootprintBytes: 0, avgAllocDeltaPerFrameBytes: 0),
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

    // T1 — warm: startCapture deferred; must be zero immediately after scrollViewReady
    func testWarmScenarioDefersCaptureUntilPrimingPassEnds() {
        let harness = MockBenchmarkHarness()
        let orchestrator = BenchmarkOrchestrator(
            args: LaunchArguments(scenario: .warm),
            harness: harness
        )
        // contentHeight=210, bounds=200 → maxY=10; slow-read covers 10pt in ~1 frame
        let sv = makeScrollView(contentHeight: 210)
        orchestrator.scrollViewReady(sv)
        XCTAssertEqual(harness.startCaptureCount, 0, "warm: startCapture must be deferred past priming pass")
        // Run the main run loop until the priming pass fires (≤ 200 ms)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(harness.startCaptureCount, 1, "warm: startCapture must fire after priming pass")
        orchestrator.stopCapture()
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

    private func makeScrollView(contentHeight: CGFloat) -> UIScrollView {
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        sv.contentSize = CGSize(width: 100, height: contentHeight)
        return sv
    }
}

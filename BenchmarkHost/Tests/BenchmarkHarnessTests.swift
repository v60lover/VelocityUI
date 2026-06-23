// BenchmarkHarnessTests.swift

import Darwin
import os
import XCTest
@testable import BenchmarkHost

final class BenchmarkHarnessTests: XCTestCase {

    // MARK: - Hitch counter

    func testHitchCounterDetectsSyntheticStall() {
        // 60 Hz baseline with a single 10 ms stall injected at frame 5.
        let frameIntervalSec: CFTimeInterval = 1.0 / 60.0
        var timestamps: [(ts: CFTimeInterval, target: CFTimeInterval)] = []

        var t: CFTimeInterval = 0
        for i in 0..<60 {
            let target = Double(i) * frameIntervalSec
            // Frame 5 arrives 10 ms late.
            let ts = target + (i == 5 ? 0.010 : 0)
            timestamps.append((ts: t + ts, target: t + target))
        }

        let stats = benchmarkComputeFrameStats(timestamps: timestamps, hitchSlack: 0.004)
        XCTAssertEqual(stats.hitchCount, 1, "Expected exactly 1 hitch for the 10 ms stall")
        XCTAssertGreaterThan(stats.p99FrameTimeMs, 20, "p99 must reflect the 10 ms late frame")
        XCTAssertEqual(stats.totalFrames, 59)
        XCTAssertEqual(stats.hitchesPerThousand, 1.0 / 59.0 * 1000.0, accuracy: 0.01)
    }

    func testNoHitchesOnPerfectFrames() {
        let frameIntervalSec: CFTimeInterval = 1.0 / 60.0
        var timestamps: [(ts: CFTimeInterval, target: CFTimeInterval)] = []
        for i in 0..<120 {
            let t = Double(i) * frameIntervalSec
            timestamps.append((ts: t, target: t))
        }
        let stats = benchmarkComputeFrameStats(timestamps: timestamps, hitchSlack: 0.004)
        XCTAssertEqual(stats.hitchCount, 0)
        XCTAssertEqual(stats.sustainedFrameRateHz, 60.0, accuracy: 1.0)
    }

    func testEmptyTimestampsReturnsZero() {
        let stats = benchmarkComputeFrameStats(timestamps: [], hitchSlack: 0.004)
        XCTAssertEqual(stats.totalFrames, 0)
        XCTAssertEqual(stats.hitchCount, 0)
    }

    // MARK: - Allocation probe

    func testAllocationProbeDetectsKnownAllocation() {
        let before = AllocationProbe.currentPhysFootprint()
        // Allocate ~1 MB and keep it alive until the assertion.
        var buffer = [UInt8](repeating: 0xFF, count: 1_024 * 1_024)
        let after = AllocationProbe.currentPhysFootprint()
        XCTAssertGreaterThan(after - before, 512 * 1_024,
            "phys_footprint delta must be > 512 KB after a 1 MB allocation")
        _ = buffer.count  // keep buffer alive
    }

    func testSummarizeEmpty() {
        let (peak, avg) = AllocationProbe.summarize(samples: [])
        XCTAssertEqual(peak, 0)
        XCTAssertEqual(avg, 0.0)
    }

    func testSummarizePositiveDeltasOnly() {
        // Samples: 100, 150, 120, 200 — positive deltas are 50 and 80.
        let (peak, avg) = AllocationProbe.summarize(samples: [100, 150, 120, 200])
        XCTAssertEqual(peak, 200)
        XCTAssertEqual(avg, (50.0 + 80.0) / 2.0, accuracy: 0.01)
    }

    // MARK: - Percentile helper

    func testPercentileEdgeCases() {
        XCTAssertEqual(benchmarkPercentile([], 0.5), 0)
        XCTAssertEqual(benchmarkPercentile([42], 0.5), 42)
        XCTAssertEqual(benchmarkPercentile([1, 2, 3, 4, 5], 0.0), 1)
        XCTAssertEqual(benchmarkPercentile([1, 2, 3, 4, 5], 1.0), 5)
        XCTAssertEqual(benchmarkPercentile([1, 2, 3, 4, 5], 0.5), 3)
    }

    // MARK: - BenchmarkReport Codable round-trip (VelocityUI-n2v)

    func testReportCodableRoundTrip() throws {
        let syntheticPayload = "eyJmb28iOiJiYXIifQ=="  // base64 of {"foo":"bar"}
        let report = BenchmarkReport(
            runtime: "VelocityUI",
            captureDurationSeconds: 30.0,
            frameStats: BenchmarkReport.FrameStats(
                totalFrames: 1800,
                hitchCount: 3,
                hitchesPerThousand: 1.66,
                p50FrameTimeMs: 16.6,
                p99FrameTimeMs: 22.0,
                maxFrameTimeMs: 35.0,
                sustainedFrameRateHz: 60.2
            ),
            memoryStats: BenchmarkReport.MemoryStats(
                peakPhysFootprintBytes: 64_000_000,
                avgAllocDeltaPerFrameBytes: 128.5
            ),
            taskSpawnCount: 7,
            metricKitSnapshots: [
                BenchmarkReport.MetricKitSnapshot(
                    deliveredAtTimestamp: 1_000_000.0,
                    payloadJSONBase64: syntheticPayload
                )
            ]
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: data)

        // top-level
        XCTAssertEqual(decoded.runtime, "VelocityUI")
        XCTAssertEqual(decoded.captureDurationSeconds, 30.0, accuracy: 0.001)
        XCTAssertEqual(decoded.taskSpawnCount, 7)

        // FrameStats — all leaf fields
        XCTAssertEqual(decoded.frameStats.totalFrames, 1800)
        XCTAssertEqual(decoded.frameStats.hitchCount, 3)
        XCTAssertEqual(decoded.frameStats.hitchesPerThousand, 1.66, accuracy: 0.001)
        XCTAssertEqual(decoded.frameStats.p50FrameTimeMs, 16.6, accuracy: 0.001)
        XCTAssertEqual(decoded.frameStats.p99FrameTimeMs, 22.0, accuracy: 0.001)
        XCTAssertEqual(decoded.frameStats.maxFrameTimeMs, 35.0, accuracy: 0.001)
        XCTAssertEqual(decoded.frameStats.sustainedFrameRateHz, 60.2, accuracy: 0.001)

        // MemoryStats
        XCTAssertEqual(decoded.memoryStats.peakPhysFootprintBytes, 64_000_000)
        XCTAssertEqual(decoded.memoryStats.avgAllocDeltaPerFrameBytes, 128.5, accuracy: 0.001)

        // MetricKitSnapshot round-trip
        XCTAssertEqual(decoded.metricKitSnapshots.count, 1)
        XCTAssertEqual(decoded.metricKitSnapshots[0].deliveredAtTimestamp, 1_000_000.0, accuracy: 0.001)
        XCTAssertEqual(decoded.metricKitSnapshots[0].payloadJSONBase64, syntheticPayload)
    }

    // MARK: - Task-spawn counter (VelocityUI-i76)

    @MainActor
    func testTaskSpawnCounterResetsOnStart() {
        let harness = BenchmarkHarness()
        harness.startCapture()
        let report = harness.stopCapture()
        XCTAssertEqual(report.taskSpawnCount, 0, "Fresh capture must start with zero spawn count")
    }

    @MainActor
    func testTaskSpawnCounterIncrements() {
        let harness = BenchmarkHarness()
        harness.startCapture()
        let n = 5
        for _ in 0..<n { harness.recordScrollPathTaskSpawn() }
        let report = harness.stopCapture()
        XCTAssertEqual(report.taskSpawnCount, n)
    }

    @MainActor
    func testTaskSpawnCounterResetsAcrossRuns() {
        let harness = BenchmarkHarness()

        // First run — spawn 3 times.
        harness.startCapture()
        harness.recordScrollPathTaskSpawn()
        harness.recordScrollPathTaskSpawn()
        harness.recordScrollPathTaskSpawn()
        let report1 = harness.stopCapture()
        XCTAssertEqual(report1.taskSpawnCount, 3)

        // Second run — must start fresh at 0.
        harness.startCapture()
        let report2 = harness.stopCapture()
        XCTAssertEqual(report2.taskSpawnCount, 0, "Counter must reset between captures")
    }

    @MainActor
    func testTaskSpawnCounterIsNonisolated() async {
        // Verify recordScrollPathTaskSpawn() can be called from a detached Task
        // without crossing @MainActor isolation or deadlocking.
        let harness = BenchmarkHarness()
        harness.startCapture()

        await Task.detached {
            harness.recordScrollPathTaskSpawn()
        }.value

        let report = harness.stopCapture()
        XCTAssertEqual(report.taskSpawnCount, 1)
    }

    // MARK: - Harness per-frame overhead microbenchmark (VelocityUI-11q)

    func testHarnessPerFrameOverheadIsUnder0Point1ms() {
        // Measures the per-frame main-thread cost of the CADisplayLink callback body:
        // a single Array.append on a pre-reserved buffer. This is the only harness
        // work that runs synchronously on the scroll path every frame.
        //
        // Two 3 600-iteration loops (no-op vs harness append) are timed with
        // mach_absolute_time. Delta p99 must be < 0.1 ms. Results are always
        // logged so CI can track the trend across iOS / device generations.
        let n = 3_600  // 30 s at 120 Hz

        // Convert mach ticks → nanoseconds once.
        var tbInfo = mach_timebase_info_data_t()
        mach_timebase_info(&tbInfo)
        let toNs = Double(tbInfo.numer) / Double(tbInfo.denom)

        // Warmup — prime the branch predictor and array internal storage.
        var warmupBuf: [(ts: CFTimeInterval, target: CFTimeInterval)] = []
        warmupBuf.reserveCapacity(128)
        for i in 0..<128 { warmupBuf.append((ts: CFTimeInterval(i), target: CFTimeInterval(i))) }

        // Baseline: tight loop with only the loop overhead (no append).
        var noopNs: [Double] = []
        noopNs.reserveCapacity(n)
        var sink = 0
        for i in 0..<n {
            let t0 = mach_absolute_time()
            sink &+= i
            let t1 = mach_absolute_time()
            noopNs.append(Double(t1 - t0) * toNs)
        }

        // Harness path: pre-reserved Array append, mirrors displayLinkTick body.
        var harnessBuf: [(ts: CFTimeInterval, target: CFTimeInterval)] = []
        harnessBuf.reserveCapacity(n)
        var harnessNs: [Double] = []
        harnessNs.reserveCapacity(n)
        for i in 0..<n {
            let ts = CFTimeInterval(i) / 120.0
            let t0 = mach_absolute_time()
            harnessBuf.append((ts: ts, target: ts))
            let t1 = mach_absolute_time()
            harnessNs.append(Double(t1 - t0) * toNs)
        }

        let baselineP99Ms = benchmarkPercentile(noopNs.sorted(), 0.99) / 1_000_000
        let harnessP99Ms  = benchmarkPercentile(harnessNs.sorted(), 0.99) / 1_000_000
        let baselineMedMs = benchmarkPercentile(noopNs.sorted(), 0.50) / 1_000_000
        let harnessMedMs  = benchmarkPercentile(harnessNs.sorted(), 0.50) / 1_000_000
        let overheadP99Ms = max(0, harnessP99Ms - baselineP99Ms)

        print(String(format: """
            [11q] Harness per-frame overhead — \
            median: %.4f ms (baseline %.4f ms), \
            p99: %.4f ms (baseline %.4f ms), \
            overhead p99: %.4f ms
            """,
            harnessMedMs, baselineMedMs,
            harnessP99Ms, baselineP99Ms,
            overheadP99Ms))

        _ = sink  // keep baseline loop live

        XCTAssertLessThan(overheadP99Ms, 0.1,
            "Harness per-frame overhead p99 must be < 0.1 ms; got \(String(format: "%.4f", overheadP99Ms)) ms")
    }

    // MARK: - XCTOSSignpostMetric canary (VelocityUI-p5z)

    func testScrollFrameSignpostCanary() {
        // Emits 60 synthetic scroll-frame signpost intervals — one per "frame" —
        // with a 10 ms stall injected at frame 5. XCTOSSignpostMetric observes the
        // intervals; the hitch-detection formula must flag exactly one hitch.
        //
        // On a physical device, Instruments can confirm these spans via the
        // "com.velocityui.benchmark / BenchmarkHost" filter. On Simulator the
        // metric still collects data but display-link timing may be imprecise.
        let signposter = OSSignposter(subsystem: "com.velocityui.benchmark",
                                       category: "BenchmarkHost")

        let metric = XCTOSSignpostMetric(subsystem: "com.velocityui.benchmark",
                                          category: "BenchmarkHost",
                                          name: "scroll-frame")

        let frameInterval: CFTimeInterval = 1.0 / 60.0
        var capturedStats: BenchmarkReport.FrameStats?

        measure(metrics: [metric]) {
            var syntheticTimestamps: [(ts: CFTimeInterval, target: CFTimeInterval)] = []
            syntheticTimestamps.reserveCapacity(60)

            for i in 0..<60 {
                let target = Double(i) * frameInterval
                // Frame 5 arrives 10 ms late in the synthetic timeline.
                let ts = target + (i == 5 ? 0.010 : 0)
                syntheticTimestamps.append((ts: ts, target: target))

                let state = signposter.beginInterval("scroll-frame")
                if i == 5 { Thread.sleep(forTimeInterval: 0.010) }
                signposter.endInterval("scroll-frame", state)
            }

            capturedStats = benchmarkComputeFrameStats(
                timestamps: syntheticTimestamps,
                hitchSlack: 0.004
            )
        }

        let stats = try! XCTUnwrap(capturedStats)
        XCTAssertEqual(stats.hitchCount, 1,
            "Hitch counter must detect the injected 10 ms stall (hitchCount must be 1)")
        XCTAssertEqual(stats.totalFrames, 59)
        XCTAssertGreaterThan(stats.p99FrameTimeMs, 20,
            "p99 must reflect the late frame")
    }
}

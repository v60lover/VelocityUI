// BenchmarkHarness.swift

@preconcurrency import MetricKit
import os
import UIKit

/// Central measurement harness. One instance per benchmark run.
/// Runtime screens call begin/end signpost methods; the orchestrator calls
/// startCapture() / stopCapture() around each timed scroll profile.
@MainActor
final class BenchmarkHarness: NSObject {

    /// Label written into every BenchmarkReport.runtime.
    var runtimeLabel: String = "unknown"

    /// Frame delta must exceed expected by this many seconds to count as a hitch.
    /// Default 4 ms matches Apple's Hangs heuristic.
    var hitchSlack: TimeInterval = 0.004

    // MARK: - Nonisolated shared state (accessed from any isolation)

    /// Subsystem "com.velocityui.benchmark", category "BenchmarkHost" — matches Instruments filter.
    nonisolated let signposter = OSSignposter(subsystem: "com.velocityui.benchmark", category: "BenchmarkHost")

    // Nonisolated let allows access from nonisolated methods (MetricKit delegate, recordScrollPathTaskSpawn).
    nonisolated private let spawnCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    nonisolated private let metricPayloadsLock = OSAllocatedUnfairLock<[MXMetricPayload]>(initialState: [])

    // MARK: - MainActor-isolated state

    private let allocationProbe = AllocationProbe()
    private var displayLink: CADisplayLink?
    private var captureStartTime: CFAbsoluteTime = 0
    private var frameTimestamps: [(ts: CFTimeInterval, target: CFTimeInterval)] = []

    // MARK: - Capture lifecycle

    func startCapture() {
        // F4: invalidate any prior link before overwriting — prevents orphaned link
        // firing into the new capture's frameTimestamps across sequential runs.
        displayLink?.invalidate()
        displayLink = nil

        frameTimestamps.removeAll()
        // F7: pre-size to 120 Hz × 60 s max; removes all CoW-resize jitter from the
        // @MainActor scroll path that this harness is supposed to measure cleanly.
        frameTimestamps.reserveCapacity(7_200)
        spawnCounter.withLock { $0 = 0 }
        metricPayloadsLock.withLock { $0.removeAll() }
        captureStartTime = CFAbsoluteTimeGetCurrent()

        allocationProbe.start()
        MXMetricManager.shared.add(self)

        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopCapture() -> BenchmarkReport {
        displayLink?.invalidate()
        displayLink = nil
        let duration = CFAbsoluteTimeGetCurrent() - captureStartTime

        let (peakFootprint, avgAllocDelta) = allocationProbe.stop()
        MXMetricManager.shared.remove(self)

        let taskSpawnCount = spawnCounter.withLock { $0 }
        let payloads = metricPayloadsLock.withLock { $0 }

        let mkSnapshots: [BenchmarkReport.MetricKitSnapshot] = payloads.map { payload in
            BenchmarkReport.MetricKitSnapshot(
                deliveredAtTimestamp: payload.timeStampBegin.timeIntervalSince1970,
                payloadJSONBase64: payload.jsonRepresentation.base64EncodedString()
            )
        }

        return BenchmarkReport(
            runtime: runtimeLabel,
            captureDurationSeconds: duration,
            frameStats: benchmarkComputeFrameStats(
                timestamps: frameTimestamps,
                hitchSlack: hitchSlack
            ),
            memoryStats: BenchmarkReport.MemoryStats(
                peakPhysFootprintBytes: peakFootprint,
                avgAllocDeltaPerFrameBytes: avgAllocDelta
            ),
            taskSpawnCount: taskSpawnCount,
            metricKitSnapshots: mkSnapshots
        )
    }

    // MARK: - Signpost spans

    /// Call at the start of each scroll frame; pass returned state to endScrollFrame.
    func beginScrollFrame() -> OSSignpostIntervalState {
        signposter.beginInterval("scroll-frame")
    }

    func endScrollFrame(_ state: OSSignpostIntervalState) {
        signposter.endInterval("scroll-frame", state)
    }

    func beginCellMount() -> OSSignpostIntervalState {
        signposter.beginInterval("cell-mount")
    }

    func endCellMount(_ state: OSSignpostIntervalState) {
        signposter.endInterval("cell-mount", state)
    }

    func beginCellRecycle() -> OSSignpostIntervalState {
        signposter.beginInterval("cell-recycle")
    }

    func endCellRecycle(_ state: OSSignpostIntervalState) {
        signposter.endInterval("cell-recycle", state)
    }

    func beginImageDecodeCommit() -> OSSignpostIntervalState {
        signposter.beginInterval("image-decode-commit")
    }

    func endImageDecodeCommit(_ state: OSSignpostIntervalState) {
        signposter.endInterval("image-decode-commit", state)
    }

    // MARK: - Scroll-path Task-spawn counter (VelocityUI contract gate)

    /// Increment when any Task { } is spawned from a path reachable by updateVisibleCells.
    /// Must remain 0 for VelocityUI; other runtimes are free to spawn.
    nonisolated func recordScrollPathTaskSpawn() {
        spawnCounter.withLock { $0 += 1 }
    }

    // MARK: - CADisplayLink

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        frameTimestamps.append((ts: link.timestamp, target: link.targetTimestamp))
    }
}

// MARK: - BenchmarkHarnessProtocol

extension BenchmarkHarness: BenchmarkHarnessProtocol {}

// MARK: - MetricKit subscriber

extension BenchmarkHarness: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        metricPayloadsLock.withLock { $0.append(contentsOf: payloads) }
    }
}

// MARK: - Pure computation (internal for unit tests)

/// Computes frame statistics from a raw timestamp array.
/// Exposed at module scope so unit tests can call it without a live CADisplayLink.
func benchmarkComputeFrameStats(
    timestamps: [(ts: CFTimeInterval, target: CFTimeInterval)],
    hitchSlack: TimeInterval
) -> BenchmarkReport.FrameStats {
    guard timestamps.count > 1 else {
        return BenchmarkReport.FrameStats(
            totalFrames: max(0, timestamps.count - 1),
            hitchCount: 0,
            hitchesPerThousand: 0,
            p50FrameTimeMs: 0,
            p99FrameTimeMs: 0,
            maxFrameTimeMs: 0,
            sustainedFrameRateHz: 0
        )
    }

    var frameTimes: [Double] = []
    var hitchCount = 0

    for i in 1..<timestamps.count {
        let actualDelta   = timestamps[i].ts     - timestamps[i - 1].ts
        let expectedDelta = timestamps[i].target - timestamps[i - 1].target
        frameTimes.append(actualDelta * 1_000)
        if actualDelta - expectedDelta > hitchSlack {
            hitchCount += 1
        }
    }

    let sorted = frameTimes.sorted()
    let total  = frameTimes.count
    let p50    = benchmarkPercentile(sorted, 0.50)
    let p99    = benchmarkPercentile(sorted, 0.99)
    let maxMs  = sorted.last ?? 0

    return BenchmarkReport.FrameStats(
        totalFrames: total,
        hitchCount: hitchCount,
        hitchesPerThousand: total > 0 ? Double(hitchCount) / Double(total) * 1_000.0 : 0,
        p50FrameTimeMs: p50,
        p99FrameTimeMs: p99,
        maxFrameTimeMs: maxMs,
        sustainedFrameRateHz: p50 > 0 ? 1_000.0 / p50 : 0
    )
}

/// Nearest-rank percentile on a pre-sorted array.
func benchmarkPercentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(Int((Double(sorted.count - 1) * p).rounded()), sorted.count - 1)
    return sorted[idx]
}

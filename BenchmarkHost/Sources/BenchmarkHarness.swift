// BenchmarkHarness.swift

@preconcurrency import MetricKit
import os
import UIKit

/// Central measurement harness. One instance per benchmark run.
/// Runtime screens call begin/end signpost methods; the orchestrator calls
/// startCapture() / stopCapture() around each timed scroll profile.
///
/// Captured by the `@Sendable` `RenderEnvironment.contentDeliveryObserver` closure in
/// `VelocityUIRuntimeViewController.init` — verified to compile without `Sendable`
/// conformance on this type, since the closure only calls the `nonisolated`,
/// `OSAllocatedUnfairLock`-protected `recordGrayToImageTransition`/
/// `recordThumbnailToImageTransition` (see their docstrings). Do not add
/// `@unchecked Sendable` here without re-deriving the need — it would silently disable
/// the checking that protects the `@MainActor`-isolated members below (displayLink,
/// frameTimestamps, allocationProbe, capture timestamps).
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
    nonisolated private let grayTransitionLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    nonisolated private let thumbnailTransitionLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Cumulative count of `RenderEnvironment.pipelineTaskSpawnObserver` firings — VelocityUI-let
    /// suspect 3 (pipeline Task storm). Drained at stopCapture, peeked (non-draining) for the live HUD.
    nonisolated private let pipelineTaskSpawnLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    // MARK: - Per-frame suspect-attribution counters (VelocityUI-let Phase 1)

    /// Events since the last CADisplayLink tick — drained and reset every tick into
    /// `perFrameApplyContentCounts`/`perFramePipelineTaskSpawnCounts` so `stopCapture` can pair
    /// each frame's duration with the suspect-event counts that landed during it (suspects 1/2
    /// vs suspect 3 — see `benchmarkComputeFrameAttribution`). Separate from the cumulative
    /// locks above, which track the whole-capture totals surfaced in `BenchmarkReport`.
    nonisolated private let perFrameApplyContentCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    nonisolated private let perFramePipelineTaskSpawnCounter = OSAllocatedUnfairLock<Int>(initialState: 0)

    // MARK: - MainActor-isolated state

    private let allocationProbe = AllocationProbe()
    private var displayLink: CADisplayLink?
    private var captureStartTime: CFAbsoluteTime = 0
    private var captureDiscardSeconds: Double = 0
    private var frameTimestamps: [(ts: CFTimeInterval, target: CFTimeInterval)] = []
    /// Kept in lockstep with `frameTimestamps` (same length, appended together every tick) —
    /// index i holds the suspect-event counts drained at the i-th tick. See
    /// `benchmarkComputeFrameAttribution`, which pairs these with `frameTimestamps` at stopCapture.
    private var perFrameApplyContentCounts: [Int] = []
    private var perFramePipelineTaskSpawnCounts: [Int] = []

    // MARK: - Capture lifecycle

    func startCapture(discardFirstSeconds: Double) {
        captureDiscardSeconds = discardFirstSeconds

        // F4: invalidate any prior link before overwriting — prevents orphaned link
        // firing into the new capture's frameTimestamps across sequential runs.
        displayLink?.invalidate()
        displayLink = nil

        frameTimestamps.removeAll()
        // F7: pre-size to 120 Hz × 60 s max; removes all CoW-resize jitter from the
        // @MainActor scroll path that this harness is supposed to measure cleanly.
        frameTimestamps.reserveCapacity(7_200)
        perFrameApplyContentCounts.removeAll()
        perFrameApplyContentCounts.reserveCapacity(7_200)
        perFramePipelineTaskSpawnCounts.removeAll()
        perFramePipelineTaskSpawnCounts.reserveCapacity(7_200)
        spawnCounter.withLock { $0 = 0 }
        metricPayloadsLock.withLock { $0.removeAll() }
        grayTransitionLock.withLock { $0 = 0 }
        thumbnailTransitionLock.withLock { $0 = 0 }
        pipelineTaskSpawnLock.withLock { $0 = 0 }
        perFrameApplyContentCounter.withLock { $0 = 0 }
        perFramePipelineTaskSpawnCounter.withLock { $0 = 0 }
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

        let (peakFootprint, avgAllocDelta, netAllocDelta, allocSamples) = allocationProbe.stop()
        let earlyLate = AllocationProbe.summarizeEarlyLate(samples: allocSamples)
        // Epsilon guards a near-zero/negative early baseline from producing an unstable ratio —
        // see MemoryStats.lateOverEarlyAllocRatio's doc.
        let lateOverEarlyRatio: Double? = earlyLate.early > 1.0 ? earlyLate.late / earlyLate.early : nil
        MXMetricManager.shared.remove(self)

        let taskSpawnCount = spawnCounter.withLock { $0 }
        let payloads = metricPayloadsLock.withLock { $0 }

        let mkSnapshots: [BenchmarkReport.MetricKitSnapshot] = payloads.map { payload in
            BenchmarkReport.MetricKitSnapshot(
                deliveredAtTimestamp: payload.timeStampBegin.timeIntervalSince1970,
                payloadJSONBase64: payload.jsonRepresentation().base64EncodedString()
            )
        }

        return BenchmarkReport(
            runtime: runtimeLabel,
            captureDurationSeconds: duration,
            frameStats: benchmarkComputeFrameStats(
                timestamps: frameTimestamps,
                hitchSlack: hitchSlack,
                discardFirstSeconds: captureDiscardSeconds
            ),
            memoryStats: BenchmarkReport.MemoryStats(
                peakPhysFootprintBytes: peakFootprint,
                avgAllocDeltaPerFrameBytes: avgAllocDelta,
                netAllocDeltaPerFrameBytes: netAllocDelta,
                earlyNetAllocDeltaPerFrameBytes: earlyLate.early,
                lateNetAllocDeltaPerFrameBytes: earlyLate.late,
                lateOverEarlyAllocRatio: lateOverEarlyRatio
            ),
            taskSpawnCount: taskSpawnCount,
            metricKitSnapshots: mkSnapshots,
            warmupDiscardedSeconds: captureDiscardSeconds > 0 ? captureDiscardSeconds : nil,
            grayToImageTransitionCount: drainGrayTransitionCount(),
            thumbnailToImageTransitionCount: drainThumbnailTransitionCount(),
            pipelineTaskSpawnCount: drainPipelineTaskSpawnCount(),
            perFrameAttribution: benchmarkComputeFrameAttribution(
                timestamps: frameTimestamps,
                applyContentCounts: perFrameApplyContentCounts,
                pipelineTaskSpawnCounts: perFramePipelineTaskSpawnCounts,
                hitchSlack: hitchSlack
            )
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

    // MARK: - Gray-to-image transition counter (slowScrollFirstThreeItems scenario)

    /// Increment each time a cell's applyContent fires, indicating a deferred gray→image transition.
    /// Called from VelocityUIRuntimeViewController via RenderEnvironment.contentDeliveryObserver.
    nonisolated func recordGrayToImageTransition() {
        grayTransitionLock.withLock { $0 += 1 }
        recordApplyContentFrameEvent()
    }

    private func drainGrayTransitionCount() -> Int {
        grayTransitionLock.withLock { let v = $0; $0 = 0; return v }
    }

    // MARK: - Thumbnail-to-image transition counter (maxFlingNoGray scenario, VelocityUI-1su.3)

    /// Increment each time a cell's applyContent fires replacing a decode-guaranteed
    /// thumbnail/BlurHash placeholder — the max-fling physics fallback engaging.
    /// Called from VelocityUIRuntimeViewController via RenderEnvironment.contentDeliveryObserver.
    nonisolated func recordThumbnailToImageTransition() {
        thumbnailTransitionLock.withLock { $0 += 1 }
        recordApplyContentFrameEvent()
    }

    private func drainThumbnailTransitionCount() -> Int {
        thumbnailTransitionLock.withLock { let v = $0; $0 = 0; return v }
    }

    // MARK: - Pipeline-task-spawn counter (VelocityUI-let suspect 3)

    /// Increment each time `notifyPipelineIfNeeded` spawns its boundary-crossing pipeline Task.
    /// Called from VelocityUIRuntimeViewController via RenderEnvironment.pipelineTaskSpawnObserver.
    nonisolated func recordPipelineTaskSpawn() {
        pipelineTaskSpawnLock.withLock { $0 += 1 }
        perFramePipelineTaskSpawnCounter.withLock { $0 += 1 }
        signposter.emitEvent("pipeline-task-spawn")
    }

    private func drainPipelineTaskSpawnCount() -> Int {
        pipelineTaskSpawnLock.withLock { let v = $0; $0 = 0; return v }
    }

    /// Reads the current pipeline-task-spawn count without resetting it. See
    /// `peekGrayTransitionCount()` for the manual-flow contract.
    nonisolated func peekPipelineTaskSpawnCount() -> Int {
        pipelineTaskSpawnLock.withLock { $0 }
    }

    // MARK: - Per-frame applyContent counter (VelocityUI-let suspects 1/2)

    /// Common increment point for both transition-kind counters above — feeds the per-frame
    /// bin drained by `displayLinkTick` and emits a discrete Instruments marker so a captured
    /// finger-fling trace shows applyContent density directly on the timeline.
    nonisolated private func recordApplyContentFrameEvent() {
        perFrameApplyContentCounter.withLock { $0 += 1 }
        signposter.emitEvent("apply-content")
    }

    // MARK: - Non-draining peeks (LiveMetricsHUD)

    /// Reads the current gray→image transition count without resetting it.
    /// Used by LiveMetricsCollector in the manual/picker flow (no startCapture is
    /// called there, so the counter accumulates from launch — that is the intended
    /// live-running total). Does not perturb the drain-on-stopCapture measured path.
    nonisolated func peekGrayTransitionCount() -> Int {
        grayTransitionLock.withLock { $0 }
    }

    /// Reads the current thumbnail→image transition count without resetting it.
    /// See `peekGrayTransitionCount()` for the manual-flow contract.
    nonisolated func peekThumbnailTransitionCount() -> Int {
        thumbnailTransitionLock.withLock { $0 }
    }

    // MARK: - CADisplayLink

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        frameTimestamps.append((ts: link.timestamp, target: link.targetTimestamp))
        perFrameApplyContentCounts.append(perFrameApplyContentCounter.withLock { let v = $0; $0 = 0; return v })
        perFramePipelineTaskSpawnCounts.append(perFramePipelineTaskSpawnCounter.withLock { let v = $0; $0 = 0; return v })
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
/// `discardFirstSeconds`: timestamps within this many seconds of the first sample are dropped
/// before computing statistics, absorbing scroll-start transients on warm runs.
func benchmarkComputeFrameStats(
    timestamps: [(ts: CFTimeInterval, target: CFTimeInterval)],
    hitchSlack: TimeInterval,
    discardFirstSeconds: Double = 0
) -> BenchmarkReport.FrameStats {
    let effective: [(ts: CFTimeInterval, target: CFTimeInterval)]
    if discardFirstSeconds > 0, let firstTs = timestamps.first?.ts {
        let startIdx = timestamps.firstIndex(where: { $0.ts >= firstTs + discardFirstSeconds })
            ?? timestamps.count
        effective = Array(timestamps[startIdx...])
    } else {
        effective = timestamps
    }

    guard effective.count > 1 else {
        return BenchmarkReport.FrameStats(
            totalFrames: max(0, effective.count - 1),
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

    for i in 1..<effective.count {
        let actualDelta   = effective[i].ts     - effective[i - 1].ts
        let expectedDelta = effective[i].target - effective[i - 1].target
        frameTimes.append(actualDelta * 1_000)
        if benchmarkIsHitch(actualDelta: actualDelta, expectedDelta: expectedDelta, hitchSlack: hitchSlack) {
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

/// Single source of truth for the hitch predicate — shared by `benchmarkComputeFrameStats`
/// and `benchmarkComputeFrameAttribution` so the two never drift apart on what counts as late.
/// Matches Apple's Hangs heuristic: a frame is a hitch if it arrives more than `hitchSlack`
/// later than its own expected cadence, relative to the previous frame.
private func benchmarkIsHitch(actualDelta: CFTimeInterval, expectedDelta: CFTimeInterval, hitchSlack: TimeInterval) -> Bool {
    actualDelta - expectedDelta > hitchSlack
}

/// VelocityUI-let Phase 1: pairs each frame interval from `timestamps` with the suspect-event
/// counts that landed during it, so a single captured report can attribute dropped frames to a
/// dominant suspect (applyContent bursts / crossfade = suspects 1–2, pipeline Task storm =
/// suspect 3) without a separate Instruments pass. Exposed at module scope (mirrors
/// `benchmarkComputeFrameStats`) so unit tests can drive it without a live CADisplayLink.
///
/// `applyContentCounts`/`pipelineTaskSpawnCounts` must be the same length as `timestamps` —
/// index i holds the counts drained at the i-th CADisplayLink tick (events that landed between
/// tick i-1 and tick i), mirroring how `BenchmarkHarness.displayLinkTick` appends all three
/// arrays together every tick. index 0 is unused, matching how `benchmarkComputeFrameStats`
/// treats `timestamps[0]` as the reference frame with no preceding interval. Mismatched lengths
/// return an empty array rather than trapping — the harness keeps the three arrays in lockstep
/// by construction, but a mismatch here means a caller bypassed that contract.
func benchmarkComputeFrameAttribution(
    timestamps: [(ts: CFTimeInterval, target: CFTimeInterval)],
    applyContentCounts: [Int],
    pipelineTaskSpawnCounts: [Int],
    hitchSlack: TimeInterval
) -> [BenchmarkReport.FrameAttribution] {
    guard timestamps.count > 1,
          applyContentCounts.count == timestamps.count,
          pipelineTaskSpawnCounts.count == timestamps.count else { return [] }

    var result: [BenchmarkReport.FrameAttribution] = []
    result.reserveCapacity(timestamps.count - 1)

    for i in 1..<timestamps.count {
        let actualDelta   = timestamps[i].ts     - timestamps[i - 1].ts
        let expectedDelta = timestamps[i].target - timestamps[i - 1].target
        result.append(BenchmarkReport.FrameAttribution(
            frameIndex: i - 1,
            frameDurationMs: actualDelta * 1_000,
            isHitch: benchmarkIsHitch(actualDelta: actualDelta, expectedDelta: expectedDelta, hitchSlack: hitchSlack),
            applyContentCount: applyContentCounts[i],
            pipelineTaskSpawnCount: pipelineTaskSpawnCounts[i]
        ))
    }
    return result
}

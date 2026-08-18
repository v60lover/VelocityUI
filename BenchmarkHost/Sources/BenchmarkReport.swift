// BenchmarkReport.swift

import Foundation

struct BenchmarkReport: Sendable, Codable {
    let runtime: String
    let captureDurationSeconds: Double
    let frameStats: FrameStats
    let memoryStats: MemoryStats
    let taskSpawnCount: Int
    let metricKitSnapshots: [MetricKitSnapshot]
    /// Seconds of frames discarded from the start of the capture window.
    /// nil when no warmup-discard window was applied (cold scenario or zero-second window);
    /// a positive value documents the discard applied so off-line analysis can recompute totals.
    let warmupDiscardedSeconds: Double?
    /// Number of cells mounted with at least one `.image` fragment where `applyContent`
    /// had not fired by scenario end (gray→image transition observed).
    /// nil when not measured by this scenario.
    let grayToImageTransitionCount: Int?
    /// Number of `applyContent` deliveries that replaced a decode-guaranteed
    /// thumbnail/BlurHash placeholder — the max-fling physics fallback (VelocityUI-1su.3)
    /// engaging. A positive count here is a perf signal, not a regression; the invariant
    /// `maxFlingNoGray` asserts is `grayToImageTransitionCount == 0`, not this being zero.
    /// nil when not measured by this scenario.
    let thumbnailToImageTransitionCount: Int?
    /// Number of pipeline Tasks spawned by `notifyPipelineIfNeeded` (leading-index boundary
    /// crossings) during the capture — VelocityUI-let suspect 3 (pipeline Task storm).
    /// nil when not measured by this scenario.
    let pipelineTaskSpawnCount: Int?
    /// Per-frame suspect attribution (VelocityUI-let Phase 1) — one entry per frame interval,
    /// pairing its duration/hitch status with the applyContent and pipeline-Task-spawn counts
    /// that landed during it. Lets offline analysis attribute dropped frames to a dominant
    /// suspect from a captured report alone. nil when not measured by this scenario.
    let perFrameAttribution: [FrameAttribution]?

    init(
        runtime: String,
        captureDurationSeconds: Double,
        frameStats: FrameStats,
        memoryStats: MemoryStats,
        taskSpawnCount: Int,
        metricKitSnapshots: [MetricKitSnapshot],
        warmupDiscardedSeconds: Double? = nil,
        grayToImageTransitionCount: Int? = nil,
        thumbnailToImageTransitionCount: Int? = nil,
        pipelineTaskSpawnCount: Int? = nil,
        perFrameAttribution: [FrameAttribution]? = nil
    ) {
        self.runtime = runtime
        self.captureDurationSeconds = captureDurationSeconds
        self.frameStats = frameStats
        self.memoryStats = memoryStats
        self.taskSpawnCount = taskSpawnCount
        self.metricKitSnapshots = metricKitSnapshots
        self.warmupDiscardedSeconds = warmupDiscardedSeconds
        self.grayToImageTransitionCount = grayToImageTransitionCount
        self.thumbnailToImageTransitionCount = thumbnailToImageTransitionCount
        self.pipelineTaskSpawnCount = pipelineTaskSpawnCount
        self.perFrameAttribution = perFrameAttribution
    }

    struct FrameStats: Sendable, Codable {
        let totalFrames: Int
        let hitchCount: Int
        let hitchesPerThousand: Double
        let p50FrameTimeMs: Double
        let p99FrameTimeMs: Double
        let maxFrameTimeMs: Double
        let sustainedFrameRateHz: Double
    }

    struct MemoryStats: Sendable, Codable {
        let peakPhysFootprintBytes: Int
        /// Mean size of a positive footprint step — a burst-SIZE metric, not a
        /// per-frame rate. See AllocationProbe.summarize docstring.
        let avgAllocDeltaPerFrameBytes: Double
        /// (samples.last − samples.first) / (samples.count − 1). The true per-frame
        /// allocation rate; may be negative after eviction. See VelocityUI-ah8.4.
        let netAllocDeltaPerFrameBytes: Double
        /// `netAllocDeltaPerFrameBytes` computed over just the first half of the capture's
        /// AllocationProbe samples. Always computed (cheap, same shape as
        /// `netAllocDeltaPerFrameBytes`), but only meaningful for the `stream` scenario
        /// (VelocityUI-xxf7): a token-driven capture's early half corresponds to early tokens
        /// (StreamDriver appends at constant cadence), so early-vs-late is directly comparable
        /// to spike 6qd's late/early ratio. 0 for a capture too short to split (≤ 2 samples).
        let earlyNetAllocDeltaPerFrameBytes: Double
        /// `netAllocDeltaPerFrameBytes` computed over the second half of the capture's samples.
        /// See `earlyNetAllocDeltaPerFrameBytes`'s doc.
        let lateNetAllocDeltaPerFrameBytes: Double
        /// `lateNetAllocDeltaPerFrameBytes / earlyNetAllocDeltaPerFrameBytes` — the stream
        /// scenario's ON/OFF regression signal: ON should read close to 1.0 (flat per-token
        /// cost as the message grows), OFF should read far above 1.0 (cost grows with message
        /// size), mirroring spike 6qd's ~1.2x-vs-~16x shape. `nil` when `earlyNetAllocDeltaPerFrameBytes`
        /// isn't meaningfully positive (≤ 1 byte/frame) — dividing by a near-zero or negative
        /// baseline produces an unstable ratio, so the two raw numbers above are the source of
        /// truth in that case.
        let lateOverEarlyAllocRatio: Double?

        init(
            peakPhysFootprintBytes: Int,
            avgAllocDeltaPerFrameBytes: Double,
            netAllocDeltaPerFrameBytes: Double,
            earlyNetAllocDeltaPerFrameBytes: Double = 0,
            lateNetAllocDeltaPerFrameBytes: Double = 0,
            lateOverEarlyAllocRatio: Double? = nil
        ) {
            self.peakPhysFootprintBytes = peakPhysFootprintBytes
            self.avgAllocDeltaPerFrameBytes = avgAllocDeltaPerFrameBytes
            self.netAllocDeltaPerFrameBytes = netAllocDeltaPerFrameBytes
            self.earlyNetAllocDeltaPerFrameBytes = earlyNetAllocDeltaPerFrameBytes
            self.lateNetAllocDeltaPerFrameBytes = lateNetAllocDeltaPerFrameBytes
            self.lateOverEarlyAllocRatio = lateOverEarlyAllocRatio
        }
    }

    /// One entry per MXMetricPayload received during the capture window.
    /// Payload is stored as base64-encoded JSON from MXMetricPayload.jsonRepresentation
    /// so the orchestrator can diff payloads across runtimes without MetricKit dependency.
    struct MetricKitSnapshot: Sendable, Codable {
        let deliveredAtTimestamp: TimeInterval
        let payloadJSONBase64: String
    }

    /// One frame interval's suspect-attribution sample. See `perFrameAttribution`'s docstring
    /// and `benchmarkComputeFrameAttribution` (VelocityUI-let Phase 1).
    struct FrameAttribution: Sendable, Codable {
        let frameIndex: Int
        let frameDurationMs: Double
        let isHitch: Bool
        let applyContentCount: Int
        let pipelineTaskSpawnCount: Int
    }
}

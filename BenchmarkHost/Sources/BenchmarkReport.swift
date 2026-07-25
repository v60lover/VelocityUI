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

    init(
        runtime: String,
        captureDurationSeconds: Double,
        frameStats: FrameStats,
        memoryStats: MemoryStats,
        taskSpawnCount: Int,
        metricKitSnapshots: [MetricKitSnapshot],
        warmupDiscardedSeconds: Double? = nil,
        grayToImageTransitionCount: Int? = nil,
        thumbnailToImageTransitionCount: Int? = nil
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
        let avgAllocDeltaPerFrameBytes: Double
    }

    /// One entry per MXMetricPayload received during the capture window.
    /// Payload is stored as base64-encoded JSON from MXMetricPayload.jsonRepresentation
    /// so the orchestrator can diff payloads across runtimes without MetricKit dependency.
    struct MetricKitSnapshot: Sendable, Codable {
        let deliveredAtTimestamp: TimeInterval
        let payloadJSONBase64: String
    }
}

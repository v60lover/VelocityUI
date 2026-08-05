// Report.swift
//
// Codable mirror of BenchmarkHost/Sources/BenchmarkReport.swift. Kept as a
// hand-rolled duplicate (not linked) because this package builds with macOS
// SwiftPM while BenchmarkHost ships through an iOS Xcode project. If the
// in-app shape changes, update this file in lockstep — the orchestrator
// will fail loudly (JSON decode error) rather than silently mis-aggregate.

import Foundation

public struct BenchmarkReport: Codable, Sendable {
    public let runtime: String
    public let captureDurationSeconds: Double
    public let frameStats: FrameStats
    public let memoryStats: MemoryStats
    public let taskSpawnCount: Int
    public let metricKitSnapshots: [MetricKitSnapshot]
    /// Seconds of frames discarded from the start of the capture window.
    /// nil when no warmup-discard window was applied (cold scenario or zero-second window);
    /// a positive value documents the discard applied so off-line analysis can recompute totals.
    public let warmupDiscardedSeconds: Double?
    /// Number of cells mounted with at least one `.image` fragment where `applyContent`
    /// had not fired by scenario end (gray→image transition observed). nil when not
    /// measured by this scenario.
    public let grayToImageTransitionCount: Int?
    /// Number of `applyContent` deliveries that replaced a decode-guaranteed
    /// thumbnail/BlurHash placeholder. nil when not measured by this scenario.
    public let thumbnailToImageTransitionCount: Int?

    public init(
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

    public struct FrameStats: Codable, Sendable {
        public let totalFrames: Int
        public let hitchCount: Int
        public let hitchesPerThousand: Double
        public let p50FrameTimeMs: Double
        public let p99FrameTimeMs: Double
        public let maxFrameTimeMs: Double
        public let sustainedFrameRateHz: Double
    }

    public struct MemoryStats: Codable, Sendable {
        public let peakPhysFootprintBytes: Int
        public let avgAllocDeltaPerFrameBytes: Double
        /// nil for reports written before VelocityUI-ah8.4 added this field —
        /// the app always emits a value for its own live reports (AllocationProbe.summarize
        /// computes it unconditionally); Optional here exists solely so the reporter can
        /// still parse pre-existing results directories rather than skip every file in them.
        public let netAllocDeltaPerFrameBytes: Double?
    }

    public struct MetricKitSnapshot: Codable, Sendable {
        public let deliveredAtTimestamp: TimeInterval
        public let payloadJSONBase64: String
    }
}

/// One row in the result set: the (combo) identity parsed from the filename
/// plus the parsed report content. The filename is the only source of truth
/// for image mode / profile / scenario / run index — the in-app report only
/// carries `runtime` as a label.
public struct RunRecord: Sendable {
    public let runtime: String        // CLI key, e.g. "velocityui"
    public let mode: String           // "idiomatic" | "raw"
    public let profile: String        // "slow" | "medium" | "max"
    public let scenario: String       // "cold" | "warm"
    public let runIndex: Int
    public let report: BenchmarkReport

    public init(
        runtime: String,
        mode: String,
        profile: String,
        scenario: String,
        runIndex: Int,
        report: BenchmarkReport
    ) {
        self.runtime = runtime
        self.mode = mode
        self.profile = profile
        self.scenario = scenario
        self.runIndex = runIndex
        self.report = report
    }
}

extension RunRecord {
    /// Filename format the orchestrator writes:
    ///   `<runtime>__<mode>__<profile>__<scenario>__<run>.json`
    public static func parseFilename(_ name: String) -> (
        runtime: String, mode: String, profile: String, scenario: String, runIndex: Int
    )? {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "__", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, let runIdx = Int(parts[4]) else { return nil }
        return (parts[0], parts[1], parts[2], parts[3], runIdx)
    }
}

// BenchmarkReport.swift

import Foundation

struct BenchmarkReport: Sendable, Codable {
    let runtime: String
    let captureDurationSeconds: Double
    let frameStats: FrameStats
    let memoryStats: MemoryStats
    let taskSpawnCount: Int
    let metricKitSnapshots: [MetricKitSnapshot]

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

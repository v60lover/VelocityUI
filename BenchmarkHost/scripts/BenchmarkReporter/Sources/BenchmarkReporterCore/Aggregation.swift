// Aggregation.swift
//
// Reduces N RunRecords for a (runtime, mode, profile, scenario) combo into a
// single AggregatedRow. The discipline here matters: we never average across
// scenarios, never average across image modes, and always surface p50 + p99
// + max where the underlying value supports it.

import Foundation

public struct AggregatedRow: Sendable {
    public let runtime: String
    public let mode: String
    public let profile: String
    public let scenario: String
    public let runCount: Int

    /// Hitches per 1000 frames — p50 / p99 across run-level values.
    public let hitchesPer1k_p50: Double
    public let hitchesPer1k_p99: Double

    /// Frame-time stats — each per-run input is already itself a p50/p99/max.
    /// Taking p50 here gives "median run's p50 frame time" — not the same as
    /// pooling raw frames, but pooling raw frames isn't possible because the
    /// app already collapsed them. Documented in the Markdown footnote.
    public let frameTimeMs_p50: Double
    public let frameTimeMs_p99: Double
    public let frameTimeMs_max: Double

    /// Allocations / frame — p50, p99 across runs. Phase 1 contract says
    /// VelocityUI must be 0; other runtimes report as-is.
    public let allocBytesPerFrame_p50: Double
    public let allocBytesPerFrame_p99: Double

    /// Peak resident memory — max across runs (peak-of-peaks is the honest
    /// number for an upper bound).
    public let peakRSSBytes_max: Int

    /// Sustained frame-rate Hz — p50 / p99 across runs.
    public let fps_p50: Double
    public let fps_p99: Double

    /// Per-run Task-spawn counter — max across runs. Phase 1 contract says
    /// VelocityUI must be 0.
    public let taskSpawnCount_max: Int

    /// Coefficient of variation on the headline metric (hitches/1k frames).
    /// > 0.15 ⇒ `⚠ unstable` flag in the Markdown report. Never hidden, never
    /// suppressed — if the run-to-run signal is noisy, the reader needs to know.
    public let hitchesPer1k_cov: Double

    public init(
        runtime: String,
        mode: String,
        profile: String,
        scenario: String,
        runCount: Int,
        hitchesPer1k_p50: Double,
        hitchesPer1k_p99: Double,
        frameTimeMs_p50: Double,
        frameTimeMs_p99: Double,
        frameTimeMs_max: Double,
        allocBytesPerFrame_p50: Double,
        allocBytesPerFrame_p99: Double,
        peakRSSBytes_max: Int,
        fps_p50: Double,
        fps_p99: Double,
        taskSpawnCount_max: Int,
        hitchesPer1k_cov: Double
    ) {
        self.runtime = runtime
        self.mode = mode
        self.profile = profile
        self.scenario = scenario
        self.runCount = runCount
        self.hitchesPer1k_p50 = hitchesPer1k_p50
        self.hitchesPer1k_p99 = hitchesPer1k_p99
        self.frameTimeMs_p50 = frameTimeMs_p50
        self.frameTimeMs_p99 = frameTimeMs_p99
        self.frameTimeMs_max = frameTimeMs_max
        self.allocBytesPerFrame_p50 = allocBytesPerFrame_p50
        self.allocBytesPerFrame_p99 = allocBytesPerFrame_p99
        self.peakRSSBytes_max = peakRSSBytes_max
        self.fps_p50 = fps_p50
        self.fps_p99 = fps_p99
        self.taskSpawnCount_max = taskSpawnCount_max
        self.hitchesPer1k_cov = hitchesPer1k_cov
    }
}

public enum Aggregator {
    /// Groups records by (runtime, mode, profile, scenario) and reduces each
    /// group to one AggregatedRow. Returns rows in stable lexicographic order
    /// so the CSV diff cleanly across runs.
    public static func aggregate(_ records: [RunRecord]) -> [AggregatedRow] {
        struct Key: Hashable {
            let runtime, mode, profile, scenario: String
        }
        var buckets: [Key: [RunRecord]] = [:]
        for r in records {
            let key = Key(runtime: r.runtime, mode: r.mode, profile: r.profile, scenario: r.scenario)
            buckets[key, default: []].append(r)
        }
        return buckets
            .map { key, runs -> AggregatedRow in
                let hitches = runs.map(\.report.frameStats.hitchesPerThousand)
                let p50FT = runs.map(\.report.frameStats.p50FrameTimeMs)
                let p99FT = runs.map(\.report.frameStats.p99FrameTimeMs)
                let maxFT = runs.map(\.report.frameStats.maxFrameTimeMs)
                let allocs = runs.map(\.report.memoryStats.avgAllocDeltaPerFrameBytes)
                let peakRSS = runs.map(\.report.memoryStats.peakPhysFootprintBytes)
                let fps = runs.map(\.report.frameStats.sustainedFrameRateHz)
                let taskSpawns = runs.map(\.report.taskSpawnCount)
                return AggregatedRow(
                    runtime: key.runtime,
                    mode: key.mode,
                    profile: key.profile,
                    scenario: key.scenario,
                    runCount: runs.count,
                    hitchesPer1k_p50: Stats.percentile(hitches, 50),
                    hitchesPer1k_p99: Stats.percentile(hitches, 99),
                    frameTimeMs_p50: Stats.percentile(p50FT, 50),
                    frameTimeMs_p99: Stats.percentile(p99FT, 99),
                    frameTimeMs_max: maxFT.max() ?? 0,
                    allocBytesPerFrame_p50: Stats.percentile(allocs, 50),
                    allocBytesPerFrame_p99: Stats.percentile(allocs, 99),
                    peakRSSBytes_max: peakRSS.max() ?? 0,
                    fps_p50: Stats.percentile(fps, 50),
                    fps_p99: Stats.percentile(fps, 99),
                    taskSpawnCount_max: taskSpawns.max() ?? 0,
                    hitchesPer1k_cov: Stats.coefficientOfVariation(hitches)
                )
            }
            .sorted { (a, b) in
                if a.runtime != b.runtime { return a.runtime < b.runtime }
                if a.mode != b.mode { return a.mode < b.mode }
                if a.profile != b.profile { return a.profile < b.profile }
                return a.scenario < b.scenario
            }
    }
}

enum Stats {
    /// Nearest-rank percentile. For N=1 returns the only value; for N=2 and
    /// percentile=99 returns the larger of the two (which is the honest answer
    /// — we don't have enough data to interpolate).
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = Int(ceil(p / 100.0 * Double(sorted.count)))
        let idx = max(1, min(sorted.count, rank)) - 1
        return sorted[idx]
    }

    /// Coefficient of variation = stddev / |mean|. Returns 0 when mean is 0
    /// or sample size < 2 — both cases mean "no useful spread signal", and
    /// flagging a perfect-zero series as unstable would be silly.
    static func coefficientOfVariation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard abs(mean) > .ulpOfOne else { return 0 }
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count - 1)
        return sqrt(variance) / abs(mean)
    }
}

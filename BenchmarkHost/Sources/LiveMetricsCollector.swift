// LiveMetricsCollector.swift

import QuartzCore
import UIKit

/// Rolling-window sampler for the on-screen HUD in the manual/picker flow.
///
/// Owns its own CADisplayLink (in that flow no `BenchmarkHarness.startCapture`
/// runs, so nothing else is sampling frames). Each tick records the frame
/// timestamp pair and the current `phys_footprint`, keeping only the last
/// `windowCapacity` samples. `snapshot()` reuses the exact offline math —
/// `benchmarkComputeFrameStats` and `AllocationProbe.summarize` — so the live
/// numbers are directly comparable to what the reporter emits.
///
/// This is a diagnostic overlay, not the measured path: small per-tick array
/// churn here is acceptable and never runs during a headless measured pass
/// (the HUD only attaches when `orchestrator == nil`).
@MainActor
final class LiveMetricsCollector {

    struct Snapshot {
        var fps: Double
        var frameMsP50: Double
        var frameMsP99: Double
        var frameMsMax: Double
        var hitchesPer1k: Double
        var currentRSSBytes: Int
        var peakRSSBytes: Int
        var rssDeltaBytes: Int
        var allocBytesPerFrame: Double
        var scrollVelocity: Double        // pt/s, smoothed
        var grayTransitions: Int
        var thumbnailTransitions: Int
        /// Cumulative pipeline-Task spawns (VelocityUI-let suspect 3) since the runtime launched.
        var pipelineTaskSpawns: Int
        var sampleCount: Int
    }

    /// ~3 s of samples at 60 Hz (or ~1.5 s at 120 Hz). Long enough for a stable
    /// p99 during a fling, short enough that the reading tracks the current gesture.
    private let windowCapacity = 180

    /// Matches BenchmarkHarness.hitchSlack (Apple's 4 ms Hangs heuristic).
    private let hitchSlack: TimeInterval = 0.004

    private weak var scrollView: UIScrollView?
    private weak var harness: BenchmarkHarness?

    private var frames: [(ts: CFTimeInterval, target: CFTimeInterval, footprint: Int)] = []
    private var displayLink: CADisplayLink?

    private var baselineRSS: Int = 0
    private var peakRSS: Int = 0

    private var lastOffsetY: CGFloat = 0
    private var lastVelocityTs: CFTimeInterval = .nan
    private var smoothedVelocity: Double = 0

    init(scrollView: UIScrollView, harness: BenchmarkHarness?) {
        self.scrollView = scrollView
        self.harness = harness
    }

    func start() {
        stop()
        frames.removeAll(keepingCapacity: true)
        frames.reserveCapacity(windowCapacity + 1)
        baselineRSS = AllocationProbe.currentPhysFootprint()
        peakRSS = baselineRSS
        lastOffsetY = scrollView?.contentOffset.y ?? 0
        lastVelocityTs = .nan
        smoothedVelocity = 0

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        // @MainActor class — deinit runs on the main actor.
        MainActor.assumeIsolated { stop() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let footprint = AllocationProbe.currentPhysFootprint()
        if footprint > peakRSS { peakRSS = footprint }

        frames.append((ts: link.timestamp, target: link.targetTimestamp, footprint: footprint))
        if frames.count > windowCapacity {
            frames.removeFirst(frames.count - windowCapacity)
        }

        if let sv = scrollView {
            let y = sv.contentOffset.y
            if !lastVelocityTs.isNaN {
                let dt = link.timestamp - lastVelocityTs
                if dt > 0 {
                    let instantaneous = Double(abs(y - lastOffsetY)) / dt
                    // EMA — the raw per-frame velocity is too jittery to read.
                    smoothedVelocity = smoothedVelocity * 0.8 + instantaneous * 0.2
                }
            }
            lastOffsetY = y
            lastVelocityTs = link.timestamp
        }
    }

    func snapshot() -> Snapshot {
        let pairs = frames.map { (ts: $0.ts, target: $0.target) }
        let fs = benchmarkComputeFrameStats(timestamps: pairs, hitchSlack: hitchSlack)
        // Net-delta over the rolling window, not the positive-step burst mean — the
        // burst mean hangs high after the finger lifts (retains old bursts for the
        // whole window) and cliff-drops in a step-count-denominator artifact.
        // Net-delta falls to ~0 within one window of decode quiesce. Clamped ≥ 0
        // for display only — the raw metric in the JSON report may be negative.
        let (_, _, netAlloc) = AllocationProbe.summarize(samples: frames.map(\.footprint))
        let current = frames.last?.footprint ?? baselineRSS

        return Snapshot(
            fps: fs.sustainedFrameRateHz,
            frameMsP50: fs.p50FrameTimeMs,
            frameMsP99: fs.p99FrameTimeMs,
            frameMsMax: fs.maxFrameTimeMs,
            hitchesPer1k: fs.hitchesPerThousand,
            currentRSSBytes: current,
            peakRSSBytes: peakRSS,
            rssDeltaBytes: current - baselineRSS,
            allocBytesPerFrame: max(0, netAlloc),
            scrollVelocity: smoothedVelocity,
            grayTransitions: harness?.peekGrayTransitionCount() ?? 0,
            thumbnailTransitions: harness?.peekThumbnailTransitionCount() ?? 0,
            pipelineTaskSpawns: harness?.peekPipelineTaskSpawnCount() ?? 0,
            sampleCount: frames.count
        )
    }
}

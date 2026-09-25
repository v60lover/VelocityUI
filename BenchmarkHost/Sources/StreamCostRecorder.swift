// StreamCostRecorder.swift

import QuartzCore
import UIKit
import VelocityUI

/// Host-side timing for the streaming cost baseline (VelocityUI-ln1g.1). Wrap each token delivery
/// in `recordDelivery`; the next display-link tick after it counts as "painted".
@MainActor
final class StreamCostRecorder {

    struct Summary: Equatable {
        var samples: Int
        var tokenToPaintMsMedian: Double
        var tokenToPaintMsP99: Double
        var mainActorMsMedian: Double
        var mainActorMsP99: Double
        var maxBacklog: Int
    }

    let warmupTokens: Int
    private var deliveredCount = 0
    private var pendingPaintStamps: [CFTimeInterval] = []
    private var tokenToPaintMs: [Double] = []
    private var mainActorMs: [Double] = []
    private var maxBacklog = 0
    private var displayLink: CADisplayLink?

    /// The first `warmupTokens` deliveries are executed but not measured.
    init(warmupTokens: Int = 0) {
        self.warmupTokens = warmupTokens
    }

    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    /// Runs `deliver` (parse + publish) and stamps it. MainActor time is measured around it.
    func recordDelivery(_ deliver: () -> Void) {
        let start = CACurrentMediaTime()
        deliver()
        let end = CACurrentMediaTime()
        deliveredCount += 1
        guard deliveredCount > warmupTokens else { return }
        mainActorMs.append((end - start) * 1000)
        pendingPaintStamps.append(start)
        maxBacklog = max(maxBacklog, pendingPaintStamps.count)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !pendingPaintStamps.isEmpty else { return }
        for stamp in pendingPaintStamps {
            tokenToPaintMs.append((link.timestamp - stamp) * 1000)
        }
        pendingPaintStamps.removeAll(keepingCapacity: true)
    }

    func summary() -> Summary {
        Summary(
            samples: tokenToPaintMs.count,
            tokenToPaintMsMedian: streamCostPercentile(tokenToPaintMs, 0.5),
            tokenToPaintMsP99: streamCostPercentile(tokenToPaintMs, 0.99),
            mainActorMsMedian: streamCostPercentile(mainActorMs, 0.5),
            mainActorMsP99: streamCostPercentile(mainActorMs, 0.99),
            maxBacklog: maxBacklog
        )
    }
}

extension StreamCostRecorder {
    /// One-line run description printed with the summary: device, OS, build config, warmup, scenario.
    func report(libraryTotals: StreamLibraryCounters.Totals, scenario: String, tokensPerSecond: Double, imageReport: ImageOwnershipReport? = nil) -> String {
        #if DEBUG
        let config = "Debug"
        #else
        let config = "Release"
        #endif
        let device = UIDevice.current
        return "[cost] device=\(device.name) os=\(device.systemVersion) config=\(config) "
            + "warmup=\(warmupTokens) tps=\(tokensPerSecond) scenario=\(scenario)\n[cost] \(summary())\n[cost] \(libraryTotals)"
            + (imageReport.map { "\n[cost] \($0.summaryLine)" } ?? "")
    }
}

/// Nearest-rank percentile. Empty input returns 0.
nonisolated func streamCostPercentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count - 1, max(0, rank - 1))]
}

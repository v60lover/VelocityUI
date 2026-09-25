// StartupSettleGate.swift

import QuartzCore
import UIKit

/// Waits for the host app's own launch lag to pass before a stream run starts (VelocityUI-ln1g.1).
/// Fires once after `requiredQuietFrames` consecutive frames faster than `quietFrameMs`, or after
/// `timeout` seconds, whichever comes first.
@MainActor
final class StartupSettleGate {

    private let requiredQuietFrames: Int
    private let quietFrameMs: Double
    private let timeout: TimeInterval
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var quietFrames = 0
    private var startedAt: CFTimeInterval = 0
    private var completion: ((Bool) -> Void)?

    init(requiredQuietFrames: Int = 30, quietFrameMs: Double = 25, timeout: TimeInterval = 30) {
        self.requiredQuietFrames = requiredQuietFrames
        self.quietFrameMs = quietFrameMs
        self.timeout = timeout
    }

    /// `completion(true)` means the host settled; `false` means the timeout hit first.
    func wait(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp > 0 {
            let ms = (now - lastTimestamp) * 1000
            quietFrames = ms < quietFrameMs ? quietFrames + 1 : 0
        }
        lastTimestamp = now
        if quietFrames >= requiredQuietFrames {
            finish(settled: true)
        } else if CACurrentMediaTime() - startedAt >= timeout {
            finish(settled: false)
        }
    }

    private func finish(settled: Bool) {
        link?.invalidate()
        link = nil
        let done = completion
        completion = nil
        done?(settled)
    }
}

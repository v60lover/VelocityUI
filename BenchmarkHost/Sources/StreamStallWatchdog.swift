// StreamStallWatchdog.swift

import Foundation
import os

/// Prints a partial `[cost]` line from a background queue when no token has been delivered for
/// `stallSeconds` (VelocityUI-ln1g.1). A frozen MainActor cannot report itself, so this only reads
/// lock-protected state: the delivered count, the library counters and the process footprint.
final class StreamStallWatchdog: Sendable {
    private struct State {
        var delivered = 0
        var lastChange = ProcessInfo.processInfo.systemUptime
        var stopped = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let total: Int
    private let counters: StreamLibraryCounters
    private let stallSeconds: Double
    private let queue = DispatchQueue(label: "velocityui.stream-stall-watchdog", qos: .utility)

    init(total: Int, counters: StreamLibraryCounters, stallSeconds: Double = 8) {
        self.total = total
        self.counters = counters
        self.stallSeconds = stallSeconds
    }

    func noteDelivered(_ count: Int) {
        state.withLock {
            $0.delivered = count
            $0.lastChange = ProcessInfo.processInfo.systemUptime
        }
    }

    func stop() { state.withLock { $0.stopped = true } }

    func start() {
        queue.asyncAfter(deadline: .now() + 2) { [self] in poll() }
    }

    private func poll() {
        let (delivered, idle, stopped) = state.withLock {
            ($0.delivered, ProcessInfo.processInfo.systemUptime - $0.lastChange, $0.stopped)
        }
        if stopped { return }
        if idle >= stallSeconds {
            print("[cost] STALL no token for \(Int(idle))s delivered=\(delivered)/\(total) footprint=\(AllocationProbe.currentPhysFootprint())")
            print("[cost] STALL \(counters.totals())")
            return
        }
        queue.asyncAfter(deadline: .now() + 2) { [self] in poll() }
    }
}

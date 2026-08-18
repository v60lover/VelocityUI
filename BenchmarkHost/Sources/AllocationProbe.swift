// AllocationProbe.swift

import Darwin
import Foundation
import os

/// Polls phys_footprint via task_info(TASK_VM_INFO) at 60 Hz on a background queue.
/// start() / stop() must be called from a single serial context (BenchmarkHarness is @MainActor).
final class AllocationProbe: @unchecked Sendable {

    // Wraps any DispatchSourceTimer as @unchecked Sendable so it can be stored in
    // OSAllocatedUnfairLock without triggering the existential Sendable diagnostic.
    private final class TimerRef: @unchecked Sendable {
        let source: any DispatchSourceTimer
        init(_ source: any DispatchSourceTimer) { self.source = source }
    }

    private let samplesLock = OSAllocatedUnfairLock<[Int]>(initialState: [])
    private let timerRefLock = OSAllocatedUnfairLock<TimerRef?>(initialState: nil)

    deinit {
        // F9: guard against stop() not being called — prevents the source firing
        // forever on .utility after the harness is released.
        timerRefLock.withLock {
            $0?.source.cancel()
            $0 = nil
        }
    }

    func start() {
        // F5: cancel any prior source before building a new one — prevents two
        // sources running concurrently into the same samplesLock after a double-start.
        timerRefLock.withLock {
            $0?.source.cancel()
            $0 = nil
        }
        samplesLock.withLock {
            $0.removeAll()
            // F7-style hygiene: pre-size so the probe's own append-reallocs never
            // show up as a footprint step in the measurement it is taking.
            $0.reserveCapacity(7_200)
        }
        let source = DispatchSource.makeTimerSource(flags: [], queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let footprint = AllocationProbe.currentPhysFootprint()
            self.samplesLock.withLock { $0.append(footprint) }
        }
        timerRefLock.withLock { $0 = TimerRef(source) }
        source.resume()
    }

    /// `samples` is the raw 60 Hz phys_footprint series the whole-run summary was computed
    /// from — BenchmarkHarness.stopCapture() also feeds it to `summarizeEarlyLate(samples:)`
    /// for the `stream` scenario's ON/OFF toggle comparison (VelocityUI-xxf7).
    func stop() -> (peakPhysFootprintBytes: Int, avgAllocDeltaPerFrameBytes: Double, netAllocDeltaPerFrameBytes: Double, samples: [Int]) {
        timerRefLock.withLock {
            $0?.source.cancel()
            $0 = nil
        }
        let samples = samplesLock.withLock { $0 }
        let summary = AllocationProbe.summarize(samples: samples)
        return (summary.peakPhysFootprintBytes, summary.avgAllocDeltaPerFrameBytes, summary.netAllocDeltaPerFrameBytes, samples)
    }

    /// - `avgAllocDeltaPerFrameBytes` is the mean size of a positive footprint step —
    ///   a burst-SIZE metric. It is invariant to how often allocation happens, and a
    ///   single guaranteed-unavoidable decode (e.g. the final cached image) sets its
    ///   floor regardless of how clean the surrounding scroll path is. Kept for
    ///   cross-run comparability; NOT the Phase 1 contract metric (see VelocityUI-ah8.4).
    /// - `netAllocDeltaPerFrameBytes` = (samples.last − samples.first) / (samples.count − 1)
    ///   is the true per-frame rate: churn (alloc-then-free) nets to ~0 even when the
    ///   burst mean is MB-scale, and it goes negative after eviction. This is the
    ///   metric the `replay` scenario's Q5 gate uses.
    // Internal for unit tests — pure function over sample array.
    static func summarize(samples: [Int]) -> (peakPhysFootprintBytes: Int, avgAllocDeltaPerFrameBytes: Double, netAllocDeltaPerFrameBytes: Double) {
        guard !samples.isEmpty else { return (0, 0.0, 0.0) }
        let peak = samples.max()!
        let posDeltas = zip(samples, samples.dropFirst()).compactMap { a, b -> Int? in
            let d = b - a
            return d > 0 ? d : nil
        }
        let avg = posDeltas.isEmpty ? 0.0 : Double(posDeltas.reduce(0, +)) / Double(posDeltas.count)
        let net = samples.count > 1
            ? Double(samples[samples.count - 1] - samples[0]) / Double(samples.count - 1)
            : 0.0
        return (peak, avg, net)
    }

    /// Splits `samples` at the midpoint and computes `netAllocDeltaPerFrameBytes` (see
    /// `summarize`'s doc) separately over each half — the early-vs-late comparison
    /// BenchmarkHost's `stream` scenario (VelocityUI-xxf7) uses to show whether per-token cost
    /// stays flat (incremental hot-block rasterize ON, VelocityUI-x4q0) or grows with message
    /// size (OFF), mirroring spike 6qd's late/early ratio methodology. The midpoint sample is
    /// shared by both halves (each half needs ≥ 2 samples to form even one delta) so a
    /// borderline sample count still yields two real deltas rather than one degenerate half.
    /// Internal for unit tests — pure function over sample array.
    static func summarizeEarlyLate(samples: [Int]) -> (early: Double, late: Double) {
        guard samples.count > 2 else { return (0.0, 0.0) }
        let mid = samples.count / 2
        let early = summarize(samples: Array(samples[0...mid])).netAllocDeltaPerFrameBytes
        let late = summarize(samples: Array(samples[mid...])).netAllocDeltaPerFrameBytes
        return (early, late)
    }

    // Internal for unit tests — readable by the probe test that allocates a known buffer.
    static func currentPhysFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

// DispatchQueueExecutor.swift

#if canImport(UIKit)
import Dispatch

/// Custom SerialExecutor wrapping a serial DispatchQueue. Gives an actor a dedicated
/// execution context off the cooperative thread pool.
///
/// Why: actors on the default executor share the cooperative pool with measureNode (Layer 2) —
/// even microsecond-scale actor bookkeeping contends for slots that should be running layout.
/// A dedicated executor removes that contention by construction.
///
/// Implements only the legacy `enqueue(_ job: UnownedJob)` requirement (SwiftStdlib 5.1 / iOS 13+),
/// not the iOS 17+ `consuming ExecutorJob` one — the stdlib explicitly supports legacy-only
/// without warnings on older targets.
public final class DispatchQueueExecutor: SerialExecutor {
    private let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        self.queue = DispatchQueue(label: label, qos: qos)
    }

    public func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Traps immediately if the caller is not on this executor's queue.
    /// Used by the Swift runtime's actor isolation checks (#isolation, assumeIsolated).
    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
#endif

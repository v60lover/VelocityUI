// DispatchQueueExecutor.swift

#if canImport(UIKit)
import Dispatch

/// Custom SerialExecutor wrapping a serial DispatchQueue. Gives an actor a dedicated
/// execution context off the cooperative thread pool.
///
/// Why: actors using the default executor share the cooperative pool with measureNode
/// (Layer 2). Even microsecond-scale actor bookkeeping (cache lookup, semaphore await,
/// dispatch enqueue) contends for the same pool slots that should be running layout. A
/// dedicated executor removes that contention by construction — contract clause 3,
/// "media never starves layout".
///
/// Availability: implements only the legacy `enqueue(_ job: UnownedJob)` requirement
/// (SwiftStdlib 5.1 / iOS 13+). The modern `consuming ExecutorJob` requirement is iOS
/// 17+ and is intentionally NOT implemented. The Swift stdlib explicitly supports the
/// legacy-only implementation without warnings on older deployment targets — see
/// swiftlang/swift `custom_executor_enqueue_availability.swift`. Prior art:
/// `GRDB.swift/GRDB/Core/DispatchQueueActor.swift`.
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

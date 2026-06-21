// GIFActor.swift

#if canImport(UIKit)
import Foundation

/// Phase 3 stub: GIF decode pipeline. Full implementation deferred to Phase 3 (GIF support).
public actor GIFActor {
    nonisolated let _executor: DispatchQueueExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        _executor.asUnownedSerialExecutor()
    }

    public init() {
        _executor = DispatchQueueExecutor(label: "velocityui.gif.actor")
    }

    /// Stops CADisplayLinks associated with the given feed cohort.
    /// Phase 1: no GIF display links exist — no-op. Phase 3 extends this.
    public func stopDisplayLinks(cohort: ObjectIdentifier) {
        // Phase 3 extension point: cancel display links keyed by cohort.
    }
}
#endif

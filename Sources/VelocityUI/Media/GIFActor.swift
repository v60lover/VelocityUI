// GIFActor.swift

#if canImport(UIKit)
import Foundation

/// Stub: GIF decode pipeline, deferred to Phase 3 (GIF support).
public actor GIFActor {
    nonisolated let _executor: DispatchQueueExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        _executor.asUnownedSerialExecutor()
    }

    public init() {
        _executor = DispatchQueueExecutor(label: "velocityui.gif.actor")
    }

    /// Stops CADisplayLinks for the given feed cohort. No-op until Phase 3 (GIF support) adds display links.
    public func stopDisplayLinks(cohort: ObjectIdentifier) {
        // Phase 3 extension point: cancel display links keyed by cohort.
    }
}
#endif

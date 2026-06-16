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
}
#endif

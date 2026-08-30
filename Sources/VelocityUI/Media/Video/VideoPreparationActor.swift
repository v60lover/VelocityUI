// VideoPreparationActor.swift

#if canImport(UIKit)
import Foundation

/// Stub: off-main video preparation pipeline, deferred to Phase 4 (Video support).
public actor VideoPreparationActor {
    nonisolated let _executor: DispatchQueueExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        _executor.asUnownedSerialExecutor()
    }

    public init() {
        _executor = DispatchQueueExecutor(label: "velocityui.video.preparation.actor")
    }
}
#endif

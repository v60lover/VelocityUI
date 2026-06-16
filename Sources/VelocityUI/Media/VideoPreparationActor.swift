// VideoPreparationActor.swift

#if canImport(UIKit)
import Foundation

/// Phase 4 stub: off-main video preparation pipeline.
/// Full implementation deferred to Phase 4 (Video support).
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

// VideoController.swift

#if canImport(UIKit)
import Foundation

/// Stub: AVPlayer coordination and attach/detach lifecycle, deferred to Phase 4 (Video support).
@MainActor
public final class VideoController {
    public let maxAttached: Int
    /// `nonisolated` so RenderEnvironment can assert identity (===) in its designated init.
    nonisolated let videoPreparation: VideoPreparationActor

    public init(videoPreparation: VideoPreparationActor, maxAttached: Int = 3) {
        self.videoPreparation = videoPreparation
        self.maxAttached = maxAttached
    }
}
#endif

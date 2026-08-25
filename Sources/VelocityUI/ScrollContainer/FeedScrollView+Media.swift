// FeedScrollView+Media.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - Media pipeline

    /// Forwards to the owned `mediaDispatcher` with this feed's live display scale — see
    /// `MediaDispatcher.spawnMediaFetches`.
    func spawnMediaFetches(
        for cell: RenderCell,
        fragments: [Fragment],
        itemID: AnyHashable,
        syncMap: [Int: CGImage] = [:]
    ) {
        mediaDispatcher.spawnMediaFetches(
            for: cell,
            fragments: fragments,
            itemID: itemID,
            scale: max(1, traitCollection.displayScale),
            syncMap: syncMap
        )
    }

    /// Forwards to the owned `mediaDispatcher` with this feed's live display scale — see
    /// `MediaDispatcher.buildSyncMap`.
    func buildSyncMap(for fragments: [Fragment], itemID: AnyHashable) -> [Int: CGImage] {
        mediaDispatcher.buildSyncMap(
            for: fragments,
            itemID: itemID,
            scale: max(1, traitCollection.displayScale)
        )
    }
}
#endif

// FeedScrollView+Media.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - Media pipeline

    /// For each image fragment with a non-nil URL, spawn a Task that fetches and decodes the
    /// image then delivers it to the cell. Called at mount time and from refineKnownFrames.
    ///
    /// Cell is captured weakly to prevent a retain cycle. itemID is captured at spawn time and
    /// threaded through applyContent, which rejects callbacks whose itemID doesn't match the
    /// cell's current one.
    ///
    /// `max(1, traitCollection.displayScale)` guards against 0.0 scale for views not yet
    /// attached to a UIWindow — a zero scale would produce an undefined decode.
    ///
    /// `syncMap`: fragments already painted synchronously via `applyLayout` — must not receive a
    /// second async fetch.
    func spawnMediaFetches(
        for cell: RenderCell,
        fragments: [Fragment],
        itemID: AnyHashable,
        syncMap: [Int: CGImage] = [:]
    ) {
        let imageActor = environment.imageActor
        let scale = max(1, traitCollection.displayScale)
        let contentDeliveryObserver = environment.contentDeliveryObserver

        for fragment in fragments {
            guard case .image(let d) = fragment.content, let url = d.url else { continue }
            let fragmentID = fragment.id
            guard syncMap[fragmentID] == nil else { continue }
            let targetSize = fragment.frame.size
            let cornerRadius = d.cornerRadius

            let task = Task { [weak cell] in
                guard let img = await imageActor.image(
                    for: url,
                    targetSize: targetSize,
                    cornerRadius: cornerRadius,
                    scale: scale
                ) else { return }
                // Primary defence on the fast-scroll path: MediaHandle.cancel() marks the Task
                // cancelled before prepareForReuse rebinds the cell, but imageActor.image() may
                // still return if the semaphore was already acquired. applyContent's itemID
                // guard is the defense-in-depth backup for races after this check.
                guard !Task.isCancelled else { return }
                if let transition = cell?.applyContent(id: fragmentID, image: img, for: itemID) {
                    contentDeliveryObserver?(transition)
                }
            }
            cell.addMediaHandle(MediaHandle(task: task), for: fragmentID)
        }
    }

    /// Collects synchronously available image and text pixels for a mounted item. Text artifacts
    /// are retained in the resident tier on a cache hit so viewport reconciliation can't clear them.
    ///
    /// Scale caveat: if preload ran at a different displayScale, cachedImage returns nil and the
    /// fragment silently falls back to the async path.
    func buildSyncMap(for fragments: [Fragment], itemID: AnyHashable) -> [Int: CGImage] {
        let imageActor = environment.imageActor
        let residentStore = environment.visibleBlockStore
        let frozenStore = environment.frozenBitmapStore
        let scale = max(1, traitCollection.displayScale)
        var map: [Int: CGImage] = [:]
        for (position, fragment) in fragments.enumerated() {
            switch fragment.content {
            case .image(let descriptor):
                guard let url = descriptor.url else { continue }
                if let image = imageActor.cachedImage(
                    for: url,
                    targetSize: fragment.frame.size,
                    cornerRadius: descriptor.cornerRadius,
                    scale: scale
                ) {
                    map[fragment.id] = image
                }
            case .text:
                let key = BlockKey(
                    boxedItemID: itemID,
                    index: position,
                    blockID: fragment.blockID
                )
                if let image = residentStore.bitmap(for: key) {
                    map[fragment.id] = image
                } else if let size = frozenStore.size(for: key),
                          let image = frozenStore.bitmap(for: key) {
                    residentStore.store(image, size: size, for: key)
                    frozenStore.evict([key])
                    map[fragment.id] = image
                }
            case .geometry:
                continue
            }
        }
        return map
    }
}
#endif

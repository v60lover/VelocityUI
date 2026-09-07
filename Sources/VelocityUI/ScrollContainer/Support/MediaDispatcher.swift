// MediaDispatcher.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// Owns media fan-out for `FeedScrollView`: spawning async image-fetch tasks for fragments that
/// need one, and collecting the image/text pixels already available synchronously (cache hits)
/// so `applyLayout` can paint real content instead of a placeholder on the same pass. `@MainActor`
/// — called from both the synchronous scroll path and the cold item-diff path, never itself
/// `await`s before returning.
@MainActor
final class MediaDispatcher {
    private let imageActor: ImageActor
    private let visibleBlockStore: VisibleBlockStore
    private let frozenBitmapStore: FrozenBitmapStore
    private let contentDeliveryObserver: (@Sendable (RenderCell.ContentTransitionKind) -> Void)?

    init(
        imageActor: ImageActor,
        visibleBlockStore: VisibleBlockStore,
        frozenBitmapStore: FrozenBitmapStore,
        contentDeliveryObserver: (@Sendable (RenderCell.ContentTransitionKind) -> Void)?
    ) {
        self.imageActor = imageActor
        self.visibleBlockStore = visibleBlockStore
        self.frozenBitmapStore = frozenBitmapStore
        self.contentDeliveryObserver = contentDeliveryObserver
    }

    /// For each image fragment with a non-nil URL, spawn a Task that fetches and decodes the
    /// image then delivers it to the cell. Called at mount time and from refineKnownFrames.
    ///
    /// Cell is captured weakly to prevent a retain cycle. itemID is captured at spawn time and
    /// threaded through applyContent, which rejects callbacks whose itemID doesn't match the
    /// cell's current one.
    ///
    /// `scale` is the caller's `max(1, traitCollection.displayScale)` — this type has no
    /// `UITraitCollection` of its own.
    ///
    /// `syncMap`: fragments already painted synchronously via `applyLayout` — must not receive a
    /// second async fetch.
    func spawnMediaFetches(
        for cell: RenderCell,
        fragments: [Fragment],
        itemID: AnyHashable,
        scale: CGFloat,
        syncMap: [Int: CGImage] = [:]
    ) {
        let imageActor = self.imageActor
        let contentDeliveryObserver = self.contentDeliveryObserver

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
    func buildSyncMap(for fragments: [Fragment], table: NodeTable, ordinals: [Int: Int], scale: CGFloat) -> [Int: CGImage] {
        var map: [Int: CGImage] = [:]
        let itemID = table.itemID
        for fragment in fragments {
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
            case .text(let descriptor):
                if case .body = descriptor.codeBlockRole { continue }
                let key = canonicalBlockKey(boxedItemID: itemID, fragment: fragment, logicalOrdinal: ordinals[fragment.id] ?? fragment.id)
                if let image = visibleBlockStore.bitmap(for: key) {
                    map[fragment.id] = image
                } else {
                    visibleBlockStore.promote([key], from: frozenBitmapStore)
                    guard let image = visibleBlockStore.bitmap(for: key) else { continue }
                    map[fragment.id] = image
                }
            case .table, .mathBlock:
                // Same resident/frozen lookup shape as non-code-body `.text` above — a table or
                // math-block raster is one flat `CGImage`, not a per-line chunk list.
                let key = canonicalBlockKey(boxedItemID: itemID, fragment: fragment, logicalOrdinal: ordinals[fragment.id] ?? fragment.id)
                if let image = visibleBlockStore.bitmap(for: key) {
                    map[fragment.id] = image
                } else {
                    visibleBlockStore.promote([key], from: frozenBitmapStore)
                    guard let image = visibleBlockStore.bitmap(for: key) else { continue }
                    map[fragment.id] = image
                }
            case .codeBlockBackground, .geometry:
                continue
            }
        }
        return map
    }
}
#endif

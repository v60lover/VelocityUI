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
    /// `MediaDispatcher.buildSyncMap`. `ordinals` is `table.leafOrdinals()` — computed once by the
    /// caller and shared with a sibling `buildCodeBodyContentMap` call over the same table, instead
    /// of each call recomputing its own copy on the scroll path.
    func buildSyncMap(for fragments: [Fragment], table: NodeTable, ordinals: [Int: Int]) -> [Int: CGImage] {
        mediaDispatcher.buildSyncMap(
            for: fragments,
            table: table,
            ordinals: ordinals,
            scale: max(1, traitCollection.displayScale)
        )
    }

    func buildCodeBodyContentMap(for fragments: [Fragment], table: NodeTable, ordinals: [Int: Int]) -> [Int: CodeBodyLayerContent] {
        var map: [Int: CodeBodyLayerContent] = [:]
        let itemID = table.itemID
        for fragment in fragments {
            guard case .text(let descriptor) = fragment.content,
                  case .body = descriptor.codeBlockRole
            else { continue }
            let key = canonicalBlockKey(boxedItemID: itemID, fragment: fragment, logicalOrdinal: ordinals[fragment.id] ?? fragment.id)
            if let content = environment.hotCodeStreamStore.content(for: key) {
                map[fragment.id] = content
                continue
            }
            if environment.visibleBlockStore.bitmap(for: key) == nil {
                environment.visibleBlockStore.promote([key], from: environment.frozenBitmapStore)
            }
            guard let image = environment.visibleBlockStore.bitmap(for: key) else { continue }
            let size = environment.visibleBlockStore.size(for: key) ?? fragment.frame.size
            map[fragment.id] = CodeBodyLayerContent(
                chunks: [CodeBodyChunk(image: image, size: size)], tailImage: nil, tailSize: .zero
            )
        }
        return map
    }
}
#endif

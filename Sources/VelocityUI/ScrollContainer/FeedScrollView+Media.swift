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

    func buildCodeBodyContentMap(for fragments: [Fragment], itemID: AnyHashable) -> [Int: CodeBodyLayerContent] {
        var map: [Int: CodeBodyLayerContent] = [:]
        for (position, fragment) in fragments.enumerated() {
            guard case .text(let descriptor) = fragment.content,
                  case .body = descriptor.codeBlockRole
            else { continue }
            let key = BlockKey(boxedItemID: itemID, index: position, blockID: fragment.blockID)
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
                sealedImage: image, sealedSize: size, tailImage: nil, tailSize: .zero
            )
        }
        return map
    }
}
#endif

// HotStores+DebugSnapshot.swift

#if canImport(UIKit)
import CoreGraphics

extension HotBlockRasterizerStore {
    public func debugImageSnapshot() -> ImageOwnerSnapshot {
        ImageOwnerSnapshot(owner: "hotText", images: entries.values.compactMap { $0.rasterizer.image })
    }
}

extension HotCodeStreamStore {
    public func debugImageSnapshot() -> ImageOwnerSnapshot {
        var images: [CGImage] = []
        for state in entries.values {
            images += state.tiles.compactMap { $0 }
            images += state.sealedChunks.compactMap(\.image)
            if let composite = state.hotChunkComposite { images.append(composite) }
            if let tail = state.lastTailImage { images.append(tail) }
        }
        return ImageOwnerSnapshot(owner: "hotCode", images: images)
    }
}
#endif

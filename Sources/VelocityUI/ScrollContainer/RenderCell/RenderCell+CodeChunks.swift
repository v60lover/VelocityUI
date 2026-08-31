// RenderCell+CodeChunks.swift

#if canImport(UIKit)
import UIKit

extension RenderCell {
    /// Reconciles `codeChunkSublayers[identity]` to exactly `chunks.count` layers, stacked
    /// top-to-bottom starting at `origin`, each sized to its own chunk's image (no stretch --
    /// mirrors the sealed+tail sizing rule). Creates/prunes layers by count. A frozen chunk's
    /// `CGImage` is never redrawn once pushed (see `HotCodeStreamStore.State.sealedChunks`), so its
    /// layer is left untouched when neither its image identity nor its geometry changed -- only the
    /// still-growing hot chunk (and any newly-frozen chunk) actually update on a given call. This
    /// keeps the per-line-seal MainActor cost bounded by the chunks that changed, not by
    /// `chunks.count`.
    func reconcileChunkLayers(identity: LayerIdentity, chunks: [CodeBodyChunk], into container: CALayer, origin: CGPoint) {
        var layers = codeChunkSublayers[identity] ?? []
        while layers.count < chunks.count {
            let l = CALayer()
            l.masksToBounds = false
            l.cornerRadius = 0
            container.addSublayer(l)
            layers.append(l)
        }
        while layers.count > chunks.count {
            layers.removeLast().removeFromSuperlayer()
        }

        var y = origin.y
        for (index, chunk) in chunks.enumerated() {
            let l = layers[index]
            let frame = CGRect(origin: CGPoint(x: origin.x, y: y), size: chunk.size)
            // `contents as? CGImage` always succeeds for any CF-bridged Any -- CFGetTypeID is the
            // correct way to check a CF type identity before the cast (mirrors the same pattern in
            // `RenderCell+TestHooks.swift`'s `_debugPaintedBitmaps`).
            let currentImage: CGImage? = {
                guard let contents = l.contents else { return nil }
                let cf = contents as CFTypeRef
                guard CFGetTypeID(cf) == CGImage.typeID else { return nil }
                return (cf as! CGImage)
            }()
            let contentsUnchanged = currentImage === chunk.image
            if !contentsUnchanged || l.frame != frame {
                l.contents = chunk.image
                l.frame = frame
                l.backgroundColor = nil
            }
            y += chunk.size.height
        }

        if layers.isEmpty {
            codeChunkSublayers.removeValue(forKey: identity)
        } else {
            codeChunkSublayers[identity] = layers
        }
    }
}
#endif

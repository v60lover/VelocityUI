// FeedScrollView+DebugSnapshot.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension ImageOwnerSnapshot {
    /// Images set as `contents` on `roots` and every sublayer below them.
    @MainActor
    public static func mountedLayers(under roots: [CALayer], owner: String = "mounted") -> ImageOwnerSnapshot {
        var images: [CGImage] = []
        func walk(_ layer: CALayer) {
            if let contents = layer.contents {
                let cf = contents as CFTypeRef
                if CFGetTypeID(cf) == CGImage.typeID { images.append(cf as! CGImage) }
            }
            layer.sublayers?.forEach(walk)
        }
        roots.forEach(walk)
        return ImageOwnerSnapshot(owner: owner, images: images)
    }
}

extension FeedScrollView {
    /// Store snapshots plus mounted cell layers, deduped by `CGImage` identity.
    public func debugImageReport() -> ImageOwnershipReport {
        let mounted = ImageOwnerSnapshot.mountedLayers(under: visibleCells.values.map(\.layer))
        return environment.debugImageReport(extraOwners: [mounted])
    }
}
#endif

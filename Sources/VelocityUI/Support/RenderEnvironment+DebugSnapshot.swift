// RenderEnvironment+DebugSnapshot.swift

#if canImport(UIKit)
import CoreGraphics

extension RenderEnvironment {
    /// Snapshots every image-holding store, plus optional extra owners such as mounted layers.
    /// `LayoutCache` and `HotTableRasterizerStore` hold no images; in-flight table results are
    /// only visible once delivered, when they land in `visible` and the mounted layers.
    @MainActor
    public func debugImageReport(extraOwners: [ImageOwnerSnapshot] = []) -> ImageOwnershipReport {
        ImageOwnershipReport(
            [visibleBlockStore.debugImageSnapshot(), hotBlockRasterizerStore.debugImageSnapshot(),
             hotCodeStreamStore.debugImageSnapshot(), frozenBitmapStore.debugImageSnapshot()] + extraOwners
        )
    }
}
#endif

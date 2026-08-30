// RenderCell+TestHooks.swift

#if canImport(UIKit)
import UIKit

extension RenderCell {
    /// Counts `applyContent` privacy-guard rejections (stale itemID deliveries). Should stay zero
    /// in normal operation; nonzero indicates a cancellation-propagation gap. Shared across every
    /// `RenderCell` instance, matching how callers reset/read it (`RenderCell._xxx`, not
    /// `cell._xxx`) — a pooled cell's identity isn't what the counter tracks. Not gated behind
    /// `#if canImport(XCTest)`: `applyContent` increments it unconditionally, with no `#if` at the
    /// call site, so the declaration must always compile.
    nonisolated(unsafe) static var _privacyGuardFiredCount: Int = 0

    /// Total count of successful `applyContent` deliveries across all cells. Test-only — used to
    /// assert the sync mount-time paint path bypasses `applyContent` entirely. Same
    /// shared-across-instances shape as `_privacyGuardFiredCount`, for the same reason.
    nonisolated(unsafe) static var _debugApplyContentCount: Int = 0
    nonisolated static func _debugResetApplyContentCount() { _debugApplyContentCount = 0 }
}

#if canImport(XCTest)
extension RenderCell {
    /// True once `contentLayer` is visible: all images have loaded, or a paintable text bitmap
    /// arrived before a pending image. Tests must not infer this from async-delivery counters.
    var _debugIsContentRevealed: Bool { contentLayer.opacity == 1 }

    /// Every fragment id currently painting a `CGImage`, mapped to that exact instance. For a code
    /// body (whose pixels live in `codeChunkSublayers`, not `sublayers`), reports the widest
    /// mounted chunk, since a chunked body has no single bitmap. Test-only — lets tests assert
    /// pixel identity, not just frame height.
    var _debugPaintedBitmaps: [Int: CGImage] {
        func cgImage(from layer: CALayer) -> CGImage? {
            // `contents as? CGImage` always succeeds for any CF-bridged Any — CFGetTypeID is the
            // correct way to check a CF type identity before the cast.
            guard let contents = layer.contents else { return nil }
            let cf = contents as CFTypeRef
            guard CFGetTypeID(cf) == CGImage.typeID else { return nil }
            return (cf as! CGImage)
        }
        var result: [Int: CGImage] = [:]
        for (id, identity) in layerIdentityByFragmentID {
            if let layer = sublayers[identity], let image = cgImage(from: layer) {
                result[id] = image
                continue
            }
            if let widest = (codeChunkSublayers[identity] ?? []).compactMap(cgImage).max(by: { $0.width < $1.width }) {
                result[id] = widest
            }
        }
        return result
    }
}
#endif
#endif

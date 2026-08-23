// HotBlockRasterizer.swift

#if canImport(UIKit)
import UIKit

/// Rasterizes one still-growing hot text block. On an append, composites only the new
/// tail fragments over the retained image — always redrawing the previous last fragment
/// whole, so a ligature/emoji at the seam can't go stale. One instance per hot block,
/// owned by `HotBlockRasterizerStore`.
final class HotBlockRasterizer {
    private let measurer = HotBlockMeasurer()
    private var image: CGImage?
    private var lastSize: CGSize = .zero
    private var previousFragmentCount: Int = 0

    #if canImport(XCTest)
    /// Test-only: fragments redrawn by the most recent `append(_:width:scale:)` call.
    /// Lets a flatness test assert this stays constant per token-kind as the block grows.
    private(set) var _debugLastRedrawnFragmentCount: Int = 0
    #endif

    /// Appends `descriptor`'s current content (its full text so far — `HotBlockMeasurer`
    /// computes the delta internally) at `width`, returning the new height and the
    /// composited image. `image` is `nil` only on a degenerate size — treat that like a
    /// `FreezeState.hot` result: paint nothing yet, retry on a later call.
    func append(_ descriptor: TextDescriptor, width: CGFloat, scale: CGFloat) -> (height: CGFloat, image: CGImage?) {
        let (height, appended) = measurer.measure(descriptor, width: width)
        let size = CGSize(width: width, height: height)
        lastSize = size

        var newFragments: [NSTextLayoutFragment] = []
        measurer.layoutManager.enumerateTextLayoutFragments(
            from: measurer.layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            newFragments.append(fragment)
            return true
        }

        guard size.width > 0, size.height > 0 else {
            image = nil
            previousFragmentCount = newFragments.count
            #if canImport(XCTest)
            _debugLastRedrawnFragmentCount = 0
            #endif
            return (height, nil)
        }

        if appended, let previousImage = image {
            // Composite: blit the retained image for the stable top region, then redraw
            // only the tail — but always the whole previous-last fragment, never a
            // sub-glyph slice, so a ligature/emoji at the seam can't go stale.
            let stableCount = max(0, previousFragmentCount - 1)
            let stableTopY = stableCount > 0 ? newFragments[stableCount - 1].layoutFragmentFrame.maxY : 0
            let redrawFragments = Array(newFragments[min(stableCount, newFragments.count)...])

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            image = renderer.image { ctx in
                if stableTopY > 0 {
                    // Crop, don't scale: previousImage is already rasterized at `scale`, so
                    // stretching it with draw(in:) would distort the stable region instead
                    // of preserving it verbatim.
                    let stableTopYPixels = min(previousImage.height, Int((stableTopY * scale).rounded()))
                    if stableTopYPixels > 0,
                       let cropped = previousImage.cropping(to: CGRect(x: 0, y: 0, width: previousImage.width, height: stableTopYPixels)) {
                        UIImage(cgImage: cropped, scale: scale, orientation: .up).draw(at: .zero)
                    }
                }
                for fragment in redrawFragments {
                    fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx.cgContext)
                }
            }.cgImage
            #if canImport(XCTest)
            _debugLastRedrawnFragmentCount = redrawFragments.count
            #endif
        } else {
            // Non-append (first call, or a full-reset fallback): the block changed
            // everywhere, so a full rasterize is correct here, not a missed optimization.
            image = rasterizeText(descriptor, size: size, scale: scale)
            #if canImport(XCTest)
            _debugLastRedrawnFragmentCount = newFragments.count
            #endif
        }

        previousFragmentCount = newFragments.count
        return (height, image)
    }

    /// Hands back whatever `append(_:width:scale:)` last produced — the final bitmap for the
    /// block's frozen cache entry. `nil` before any successful `append` call. No re-measurement:
    /// the seal moment reuses exactly the pixels already composited, never a fresh rasterize.
    func finish() -> (size: CGSize, image: CGImage)? {
        guard let image else { return nil }
        return (lastSize, image)
    }
}
#endif

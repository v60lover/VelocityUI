// HotBlockRasterizer.swift

#if canImport(UIKit)
import UIKit

/// Incremental rasterize path for ONE still-growing hot text block (VelocityUI-x4q0, direction
/// (b) from TEXTKIT2_INCREMENTAL_RASTERIZATION_RESEARCH.md §4). Owns one `HotBlockMeasurer`
/// (VelocityUI-c1uc) and reuses its persistent `NSTextLayoutManager` to draw only newly appended
/// tail fragments, compositing over the retained previous `CGImage` instead of re-rasterizing
/// the whole block every token.
///
/// Every edit goes through `HotBlockMeasurer.measure(_:width:)` — never touches
/// `NSTextContentStorage`/`NSTextStorage` directly, so its captured-storage contract can't be
/// reintroduced as a bug here.
///
/// On an append (`measure`'s `appended == true`), the previous LAST fragment is always redrawn
/// in full alongside anything new — never partial/sub-glyph — so a ligature/emoji spanning the
/// append seam never leaves a stale half-glyph (research §6.5). The retained top region is
/// CROPPED into the composite, never scaled (`testMultiFragmentBlit_GrowingLastLineMatchesGroundTruth`,
/// `testLigatureAndEmojiAtSeam`). Any non-append change (first call, width change, attribute
/// change, non-prefix edit) falls back to a full `rasterizeText` pass, matching cold/first-paint.
///
/// Lifetime is ONE hot block, owned per-`BlockKey` by `HotBlockRasterizerStore`, which tears this
/// (and its measurer's live `NSTextLayoutManager`) down once the block seals or scrolls out. No
/// singletons (CLAUDE.md).
final class HotBlockRasterizer {
    private let measurer = HotBlockMeasurer()
    private var image: CGImage?
    private var lastSize: CGSize = .zero
    private var previousFragmentCount: Int = 0

    #if canImport(XCTest)
    /// Test-only: fragments redrawn by the most recent `append(_:width:scale:)` call — the
    /// direction-(b) "glyph-rasterized line count" proxy at fragment granularity. Lets a flatness
    /// test assert this stays constant per token-kind as the block grows, mirroring
    /// `HotBlockRasterizerSpikeTests`'s self-calibrating pattern against production code.
    private(set) var _debugLastRedrawnFragmentCount: Int = 0
    #endif

    /// Appends `descriptor`'s current content (the hot block's full text so far — NOT a raw
    /// delta; `HotBlockMeasurer` computes the delta internally) at `width`, returning the new
    /// height and the composited/rasterized image. `image` is `nil` only when `size` is
    /// degenerate (mirrors `rasterizeText`'s own `size.width/height > 0` guard and
    /// `FreezeState.freeze(_:)`'s existing `.hot` degenerate-size handling) — the caller should
    /// treat that the same way it already treats a `FreezeState.hot` result: paint nothing yet,
    /// retry on a later call.
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
            // Direction (b) composite: blit the retained previous image for the stable top
            // region, then redraw ONLY the tail — but always the WHOLE previous-last fragment,
            // never a sub-glyph slice, so a ligature/emoji at the seam can't go stale. Mirrors
            // HotBlockRasterizerSpikeTests.IncrementalTextProbe.append's direction-(b) block.
            let stableCount = max(0, previousFragmentCount - 1)
            let stableTopY = stableCount > 0 ? newFragments[stableCount - 1].layoutFragmentFrame.maxY : 0
            let redrawFragments = Array(newFragments[min(stableCount, newFragments.count)...])

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            image = renderer.image { ctx in
                if stableTopY > 0 {
                    // Crop, don't scale: previousImage is already rasterized at `scale`, so its
                    // top stableTopY points are exactly stableTopY * scale pixels tall. Using
                    // draw(in:) here would stretch/squash that region to fit stableTopY instead
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
            // Non-append (first call, or HotBlockMeasurer's own full-reset fallback): the block
            // genuinely changed everywhere, so a full rasterize is correct, not a missed
            // optimization — same shape the cold/first-paint path already uses.
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

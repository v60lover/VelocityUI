// HotCodeStreamStore+Rasterize.swift

#if canImport(UIKit)
import UIKit

extension HotCodeStreamStore {
    // MARK: - Pure helpers

    /// Splits `rawCode` at its final `\n` into complete (sealed) lines and the unterminated tail.
    /// A trailing `\n` with nothing after it yields an empty tail; `"\n"` alone yields one sealed
    /// empty line, not zero -- distinguished from `rawCode` containing no `\n` at all, which
    /// yields zero sealed lines (everything is still tail).
    static func splitSealedAndTail(_ rawCode: String) -> (sealedLines: [String], tail: String) {
        guard let lastNewline = rawCode.lastIndex(of: "\n") else {
            return ([], rawCode)
        }
        let sealedPart = rawCode[rawCode.startIndex..<lastNewline]
        let tail = String(rawCode[rawCode.index(after: lastNewline)...])
        let sealedLines = sealedPart.isEmpty ? [""] : sealedPart.components(separatedBy: "\n")
        return (sealedLines, tail)
    }

    /// Rasterizes one line (sealed or the partial tail) via the same `makeCodeTextDescriptor` +
    /// `rasterizeText` primitives the whole-block path uses -- `colorRuns: nil` for a plain tile,
    /// or a line's own runs to recolor it. An empty/degenerate line still occupies a
    /// `font.uiFont.lineHeight`-tall row with a `nil` image.
    static func rasterizeLine(
        _ text: String,
        colorRuns: LineColorRuns?,
        font: VFontDescriptor,
        theme: Theme,
        scale: CGFloat,
        measure: (TextDescriptor, CGFloat) -> CGSize
    ) -> (image: CGImage?, size: CGSize) {
        let descriptor = makeCodeTextDescriptor(
            lines: [text][...], colorRuns: [colorRuns ?? LineColorRuns(runs: [])], font: font, theme: theme
        )
        let size = measure(descriptor, .greatestFiniteMagnitude)
        guard size.width > 0, size.height > 0 else {
            return (nil, CGSize(width: 0, height: font.uiFont.lineHeight))
        }
        return (rasterizeText(descriptor, size: size, scale: scale), size)
    }

    /// Composites `tiles` (stacked top-to-bottom by `tileHeights`) plus `tailImage` into one
    /// image sized `(maxWidth, totalHeight)`. `from` marks the first tile index that changed since
    /// `previousComposite` was built; everything below it is blitted verbatim (cropped from the
    /// retained image, never re-rasterized). `to` (default `tiles.count`) marks the exclusive end
    /// of the range that actually changed and must be freshly drawn -- new tiles from `append`/
    /// `finalize` always pass `to: tiles.count` (there's nothing valid to reuse below brand-new
    /// tiles), but a bounded recolor chunk from `deliverColorRuns` passes its own `chunkEnd`: the
    /// tiles from `to` through `tiles.count` are still plain and byte-identical to what
    /// `previousComposite` already drew, so they're blitted from it instead of re-drawn -- without
    /// this, `recolorChunkSize` would bound MainActor *rasterization* work per turn but not the
    /// *compositing* work, which would still redraw every remaining tile in the block every turn.
    /// `from == tiles.count` (no `to` override) is the fast tail-only-changed path. Mirrors
    /// `HotBlockRasterizer.append`'s crop+redraw-tail technique, generalized to line tiles.
    static func recomposite(
        from startTileIndex: Int,
        to endTileIndex: Int? = nil,
        tiles: [CGImage?],
        tileHeights: [CGFloat],
        sealedHeight: CGFloat,
        previousComposite: CGImage?,
        tailImage: CGImage?,
        tailHeight: CGFloat,
        maxWidth: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let totalHeight = sealedHeight + tailHeight
        guard maxWidth > 0, totalHeight > 0 else { return nil }
        let redrawEnd = endTileIndex ?? tiles.count
        let widthPixels = Int((maxWidth * scale).rounded())

        // y-offset of `startTileIndex` -- `sealedHeight` is the incrementally maintained running
        // total, so this stays bounded by the changed range rather than summing every tile.
        let yStart = sealedHeight - tileHeights[startTileIndex...].reduce(0, +)
        // The suffix beyond `redrawEnd` (still-plain tiles a recolor chunk didn't touch) can only
        // be reused verbatim from `previousComposite` if the canvas hasn't grown since -- a
        // later-colorized line widening `maxWidth` would leave `previousComposite` too narrow.
        let canReuseSuffix = redrawEnd < tiles.count
            && previousComposite != nil
            && previousComposite!.width == widthPixels

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: maxWidth, height: totalHeight), format: format)
        return renderer.image { _ in
            if let previousComposite {
                if canReuseSuffix {
                    UIImage(cgImage: previousComposite, scale: scale, orientation: .up).draw(at: .zero)
                } else if yStart > 0 {
                    let stableHeightPixels = min(previousComposite.height, Int((yStart * scale).rounded()))
                    if stableHeightPixels > 0,
                       let cropped = previousComposite.cropping(
                           to: CGRect(x: 0, y: 0, width: previousComposite.width, height: stableHeightPixels)
                       ) {
                        UIImage(cgImage: cropped, scale: scale, orientation: .up).draw(at: .zero)
                    }
                }
            }
            var y = yStart
            for index in startTileIndex..<redrawEnd {
                if let tile = tiles[index] {
                    UIImage(cgImage: tile, scale: scale, orientation: .up).draw(at: CGPoint(x: 0, y: y))
                }
                y += tileHeights[index]
            }
            if canReuseSuffix {
                y = sealedHeight
            } else {
                for index in redrawEnd..<tiles.count {
                    if let tile = tiles[index] {
                        UIImage(cgImage: tile, scale: scale, orientation: .up).draw(at: CGPoint(x: 0, y: y))
                    }
                    y += tileHeights[index]
                }
            }
            if let tailImage {
                UIImage(cgImage: tailImage, scale: scale, orientation: .up).draw(at: CGPoint(x: 0, y: y))
            }
        }.cgImage
    }
}
#endif

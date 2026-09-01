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
        return rasterizeMeasuredCodeText(descriptor, measuredSize: size, scale: scale)
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

    /// Freezes every completed `chunkLineBudget`-line chunk in `state.tiles` that isn't already in
    /// `state.sealedChunks`, then rebuilds the still-growing hot chunk. Each freeze and the final
    /// hot-chunk rebuild both cost O(chunkLineBudget) via `recomposite` over a local (0-based)
    /// slice of `tiles`/`tileHeights` -- never O(sealed line count). Called after any call that
    /// seals new lines (`append`, `finalize`), and safe to call redundantly (idempotent when
    /// nothing changed since the last call).
    static func updateChunks(_ state: State, scale: CGFloat) {
        while state.tiles.count - state.hotChunkStartIndex >= chunkLineBudget {
            let end = state.hotChunkStartIndex + chunkLineBudget
            let localTiles = Array(state.tiles[state.hotChunkStartIndex..<end])
            let localHeights = Array(state.tileHeights[state.hotChunkStartIndex..<end])
            let localHeight = localHeights.reduce(0, +)
            let image = recomposite(
                from: 0, tiles: localTiles, tileHeights: localHeights, sealedHeight: localHeight,
                previousComposite: nil, tailImage: nil, tailHeight: 0, maxWidth: state.maxWidth, scale: scale
            )
            state.sealedChunks.append(CodeBodyChunk(image: image, size: CGSize(width: state.maxWidth, height: localHeight)))
            state.hotChunkStartIndex = end
        }
        let hotTiles = Array(state.tiles[state.hotChunkStartIndex...])
        let hotHeights = Array(state.tileHeights[state.hotChunkStartIndex...])
        state.hotChunkHeight = hotHeights.reduce(0, +)
        state.hotChunkComposite = hotTiles.isEmpty ? nil : recomposite(
            from: 0, tiles: hotTiles, tileHeights: hotHeights, sealedHeight: state.hotChunkHeight,
            previousComposite: nil, tailImage: nil, tailHeight: 0, maxWidth: state.maxWidth, scale: scale
        )
    }

    /// Rebuilds only the frozen chunk(s) whose line range intersects `range`, and the hot chunk if
    /// `range` reaches into it -- the recolor-path counterpart to `updateChunks`. A bounded
    /// `recolorChunkSize`-line delivery touches at most a handful of `chunkLineBudget`-sized
    /// chunks, so this stays O(chunkLineBudget) per touched chunk; every untouched chunk is left
    /// byte-identical, never read or redrawn. The touched chunk INDICES are computed directly by
    /// division from `range`, not by scanning every chunk from index 0 -- otherwise a recolor deep
    /// into a long block would pay O(chunk count) just to locate the chunks it needs.
    static func recompositeChunks(in range: Range<Int>, state: State, scale: CGFloat) {
        let sealedRange = range.clamped(to: 0..<state.hotChunkStartIndex)
        if !sealedRange.isEmpty {
            let firstChunkIndex = sealedRange.lowerBound / chunkLineBudget
            let lastChunkIndex = (sealedRange.upperBound - 1) / chunkLineBudget
            for chunkIndex in firstChunkIndex...lastChunkIndex {
                let chunkStart = chunkIndex * chunkLineBudget
                let chunkEnd = min(chunkStart + chunkLineBudget, state.hotChunkStartIndex)
                let localTiles = Array(state.tiles[chunkStart..<chunkEnd])
                let localHeights = Array(state.tileHeights[chunkStart..<chunkEnd])
                let localHeight = localHeights.reduce(0, +)
                let image = recomposite(
                    from: 0, tiles: localTiles, tileHeights: localHeights, sealedHeight: localHeight,
                    previousComposite: nil, tailImage: nil, tailHeight: 0, maxWidth: state.maxWidth, scale: scale
                )
                state.sealedChunks[chunkIndex] = CodeBodyChunk(image: image, size: CGSize(width: state.maxWidth, height: localHeight))
            }
        }
        guard range.upperBound > state.hotChunkStartIndex else { return }
        let hotTiles = Array(state.tiles[state.hotChunkStartIndex...])
        let hotHeights = Array(state.tileHeights[state.hotChunkStartIndex...])
        state.hotChunkHeight = hotHeights.reduce(0, +)
        state.hotChunkComposite = hotTiles.isEmpty ? nil : recomposite(
            from: 0, tiles: hotTiles, tileHeights: hotHeights, sealedHeight: state.hotChunkHeight,
            previousComposite: nil, tailImage: nil, tailHeight: 0, maxWidth: state.maxWidth, scale: scale
        )
    }

    /// One-shot flatten of a chunk list + tail into a single bitmap. Used only when a block leaves
    /// the hot streaming path (a `finalize()` synchronous return, or its fully-colorized delivery)
    /// to persist ONE composite into `VisibleBlockStore`/`FrozenBitmapStore`, which store one
    /// bitmap per key -- never called on the per-line hot-append path, which is exactly the
    /// O(sealed height) recomposite this type replaces.
    static func composeFullImage(_ content: CodeBodyLayerContent, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let size = content.totalSize
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            var y: CGFloat = 0
            for chunk in content.chunks {
                if let chunkImage = chunk.image {
                    UIImage(cgImage: chunkImage, scale: scale, orientation: .up).draw(at: CGPoint(x: 0, y: y))
                }
                y += chunk.size.height
            }
            if let tailImage = content.tailImage {
                UIImage(cgImage: tailImage, scale: scale, orientation: .up).draw(at: CGPoint(x: 0, y: y))
            }
        }.cgImage
        guard let image else { return nil }
        return (image, size)
    }
}
#endif

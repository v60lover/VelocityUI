// HotCodeStreamStore+Recolor.swift

#if canImport(UIKit)
import UIKit

extension HotCodeStreamStore {
    // MARK: - Off-main parse + chunked recolor delivery

    /// Spawns one off-main tree-sitter parse of `state.sealedLineTexts` as of this call. Grammar
    /// lookup happens inside the detached task, off-main -- `HighlightRegistry.grammar(for:)` is
    /// documented safe to call from a `Task`, never with an `await` on the calling side. The
    /// spawned `Task` itself inherits this store's `@MainActor` isolation (it's created from a
    /// MainActor method), so it may capture the non-Sendable `measure`/`onRecolor` closures; only
    /// the nested `Task.detached` body is required to be `Sendable`-clean.
    func spawnParse(
        _ key: BlockKey,
        state: State,
        coveredLineCount: Int,
        font: VFontDescriptor,
        theme: Theme,
        languageID: LanguageID,
        highlightRegistry: HighlightRegistry,
        scale: CGFloat,
        measure: @escaping (TextDescriptor, CGFloat) -> CGSize,
        eventObserver: (@Sendable (CodeStreamEventKind) -> Void)?,
        onRecolor: @MainActor @escaping (CodeBodyLayerContent) -> Void
    ) {
        eventObserver?(.parseCall)
        let sealedSnapshot = state.sealedLineTexts
        let generation = state.generation
        state.pendingTask?.cancel()
        state.pendingDetachedTask?.cancel()
        // Unstructured `Task.detached` does not inherit cancellation from the wrapper `Task`
        // below -- superseding this spawn (a later line seals before this parse lands) must
        // cancel the detached parse explicitly, or a fast stream of line-seal events leaves many
        // already-obsolete whole-prefix parses running concurrently.
        let detached = Task.detached(priority: .utility) {
            let grammar = highlightRegistry.grammar(for: languageID)
            return TreeSitterHighlighter().colorRuns(for: sealedSnapshot[...], grammar: grammar, theme: theme)
        }
        state.pendingDetachedTask = detached
        state.pendingTask = Task { @MainActor [weak self] in
            let colorRuns = await detached.value
            guard let self, !Task.isCancelled else { return }
            self.deliverColorRuns(
                key, generation: generation, colorRuns: colorRuns, coveredLineCount: coveredLineCount,
                font: font, theme: theme, scale: scale, measure: measure, onRecolor: onRecolor
            )
        }
    }

    /// Applies a landed parse result in bounded chunks of at most `recolorChunkSize` lines per
    /// MainActor turn, recomposing and delivering after each chunk, then yielding and continuing
    /// on the next turn until the whole `coveredLineCount` range is colorized. Without chunking, a
    /// parse landing after adaptive defer (hundreds of lines at once) would recolor its entire
    /// coverage inline in one callback and stall a frame.
    ///
    /// Drops the result if the entry was reset since spawn (`generation` mismatch -- theme/scale
    /// swap or eviction+remount under the same key) or if a later spawn already colored past this
    /// result's coverage -- content only grows, so `coveredLineCount` is a sufficient monotonic
    /// staleness check with no separate per-result token needed.
    func deliverColorRuns(
        _ key: BlockKey,
        generation: Int,
        colorRuns: [LineColorRuns],
        coveredLineCount: Int,
        font: VFontDescriptor,
        theme: Theme,
        scale: CGFloat,
        measure: @escaping (TextDescriptor, CGFloat) -> CGSize,
        onRecolor: @MainActor @escaping (CodeBodyLayerContent) -> Void
    ) {
        guard let state: HotCodeStreamStore.State = entries[key], state.generation == generation else { return }
        let upper = min(coveredLineCount, state.tiles.count)
        guard upper > state.coloredLineCount else { return }

        let start = state.coloredLineCount
        let chunkEnd = min(upper, start + Self.recolorChunkSize)
        for index in start..<chunkEnd {
            let lineRuns = index < colorRuns.count ? colorRuns[index] : LineColorRuns(runs: [])
            let (image, size) = Self.rasterizeLine(
                state.sealedLineTexts[index], colorRuns: lineRuns, font: font, theme: theme, scale: scale, measure: measure
            )
            state.tiles[index] = image
            state.tileHeights[index] = size.height
            state.maxWidth = max(state.maxWidth, size.width)
        }
        state.coloredLineCount = chunkEnd

        state.sealedComposite = Self.recomposite(
            from: start, to: chunkEnd, tiles: state.tiles, tileHeights: state.tileHeights, sealedHeight: state.sealedHeight,
            previousComposite: state.sealedComposite,
            tailImage: nil, tailHeight: 0,
            maxWidth: state.maxWidth, scale: scale
        )
        onRecolor(CodeBodyLayerContent(
            sealedImage: state.sealedComposite,
            sealedSize: CGSize(width: state.maxWidth, height: state.sealedHeight),
            tailImage: state.lastTailImage,
            tailSize: CGSize(width: state.maxWidth, height: state.lastTailHeight)
        ))

        if chunkEnd < upper {
            state.pendingTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.deliverColorRuns(
                    key, generation: generation, colorRuns: colorRuns, coveredLineCount: coveredLineCount,
                    font: font, theme: theme, scale: scale, measure: measure, onRecolor: onRecolor
                )
            }
        } else {
            state.pendingTask = nil
        }
    }
}
#endif

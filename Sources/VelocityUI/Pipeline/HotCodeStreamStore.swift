// HotCodeStreamStore.swift

#if canImport(UIKit)
import UIKit

/// Production-safe observability for `HotCodeStreamStore`, mirroring `ContentTransitionKind` --
/// routed through `RenderEnvironment.codeStreamObserver` instead of an XCTest-only counter.
public enum CodeStreamEventKind: Sendable, Equatable {
    /// One off-main tree-sitter parse of the whole sealed prefix was spawned.
    case parseCall
    /// One newly-sealed line received its own (plain, pre-color) raster tile.
    case sealedLineTileRasterized
    /// The unterminated trailing line was (re)rasterized.
    case partialLineRasterized
}

/// `CGImage` is immutable after creation; this value only transports its pixels across tasks.
struct CodeBodyLayerContent: @unchecked Sendable {
    let sealedImage: CGImage?
    let sealedSize: CGSize
    let tailImage: CGImage?
    let tailSize: CGSize

    var totalSize: CGSize {
        CGSize(width: max(sealedSize.width, tailSize.width), height: sealedSize.height + tailSize.height)
    }

    var image: CGImage? { sealedImage }
}

/// Per-`BlockKey` lifecycle owner for streaming a hot code block's body: per-line raster tiles
/// that freeze the moment they're colorized, a replaceable plain partial-line tile, and one
/// off-main tree-sitter parse per line-seal event. `@MainActor`, no locking -- touched only from
/// the synchronous scroll-adjacent content-append path, mirroring `HotBlockRasterizerStore`.
///
/// Keyed by `block.key` (not `codePartID(..., part: .codeBody)`) -- same convention as
/// `HotBlockRasterizerStore`, so the two stores' eviction sweeps stay parallel.
///
/// Two-layer delivery updates the sealed composite only when a line seals or recolors; tail-only
/// appends replace just their own small raster. The store also avoids re-splitting the whole block's text or
/// re-sums every tile's height on every token, it cancels stale off-main parses instead of letting
/// them race a remount, and it never colorizes more than a bounded chunk of lines in one MainActor
/// turn.
///
/// Split across three files, one responsibility per file:
/// - `HotCodeStreamStore.swift` (this file): state + the public `append`/`finalize`/`evict` API.
/// - `HotCodeStreamStore+Recolor.swift`: the off-main parse spawn + chunked recolor delivery.
/// - `HotCodeStreamStore+Rasterize.swift`: pure line-splitting/rasterization/compositing helpers.
@MainActor
public final class HotCodeStreamStore {
    final class State {
        var tiles: [CGImage?] = []
        var tileHeights: [CGFloat] = []
        var sealedLineTexts: [String] = []
        var coloredLineCount: Int = 0
        var maxWidth: CGFloat = 0
        /// Running sum of `tileHeights` -- maintained incrementally as lines seal so `append`
        /// never pays an O(line count) `reduce` per token. Colorizing a tile never changes its
        /// measured size (same font, same text, only color), so recolor never touches this.
        var sealedHeight: CGFloat = 0
        var sealedComposite: CGImage?
        var themeGeneration: Int
        /// Bitmap pixels depend on display scale as well as theme -- mirrors
        /// `CodeBodyRasterIdentity`, which the sealed-cache path already keys on both.
        var scale: CGFloat
        var isDeferred: Bool = false
        var lastTailImage: CGImage?
        var lastTailHeight: CGFloat = 0
        /// The unsealed suffix carried across calls -- `append` only re-scans text appended since
        /// `processedUTF8Count`, not the whole block, for new sealed lines.
        var tailText: String = ""
        /// UTF8 byte count of the raw content already folded into `sealedLineTexts` + `tailText`.
        var processedUTF8Count: Int = 0
        /// Bumped on every `reset` -- a spawned parse/recolor-chunk task captures this value and
        /// re-checks it after every `await`, so a task from a torn-down generation can never land
        /// on a state that has since been reset (theme/scale swap while still hot).
        var generation: Int = 0
        /// The in-flight off-main parse, or the in-flight chunked-recolor continuation -- exactly
        /// one at a time. Cancelled on `evict`/`reset` so a stale task can never outlive the entry
        /// it was spawned for and color a since-remounted block under the same key.
        var pendingTask: Task<Void, Never>?
        /// The `Task.detached` doing the actual tree-sitter parse inside `pendingTask`'s wrapper.
        /// Cancelling `pendingTask` alone does NOT propagate cancellation into an unstructured
        /// `Task.detached` -- it keeps running to completion regardless. Tracked separately so
        /// `evict`/`reset` can cancel it explicitly instead of leaving a superseded whole-prefix
        /// parse to burn CPU under a fast stream of line seals.
        var pendingDetachedTask: Task<[LineColorRuns], Never>?

        init(themeGeneration: Int, scale: CGFloat) {
            self.themeGeneration = themeGeneration
            self.scale = scale
        }

        func reset(themeGeneration: Int, scale: CGFloat) {
            pendingTask?.cancel()
            pendingTask = nil
            pendingDetachedTask?.cancel()
            pendingDetachedTask = nil
            tiles = []
            tileHeights = []
            sealedLineTexts = []
            coloredLineCount = 0
            maxWidth = 0
            sealedHeight = 0
            sealedComposite = nil
            isDeferred = false
            tailText = ""
            processedUTF8Count = 0
            self.themeGeneration = themeGeneration
            self.scale = scale
            generation += 1
        }
    }

    /// Upper bound on how many lines one `deliverColorRuns` MainActor turn recolors + rasterizes +
    /// recomposites before yielding and continuing on the next turn. Without this, a parse that
    /// lands after adaptive defer (hundreds of sealed lines at once, e.g. via `finalize`) would
    /// recolor its entire coverage synchronously in a single callback and stall a frame.
    static let recolorChunkSize = 40

    var entries: [BlockKey: State] = [:]
    let adaptiveDeferLineThreshold: Int

    /// - Parameter adaptiveDeferLineThreshold: once a block's sealed line count exceeds this
    ///   value, intermediate per-line tree-sitter parses stop -- the block keeps streaming in
    ///   plain mono -- until `finalize(_:...)` runs exactly one final parse when the fence closes.
    ///   Default 300 matches this feature's acceptance criteria.
    public init(adaptiveDeferLineThreshold: Int = 300) {
        self.adaptiveDeferLineThreshold = adaptiveDeferLineThreshold
    }

    func content(for key: BlockKey) -> CodeBodyLayerContent? {
        guard let state = entries[key] else { return nil }
        return CodeBodyLayerContent(
            sealedImage: state.sealedComposite,
            sealedSize: CGSize(width: state.maxWidth, height: state.sealedHeight),
            tailImage: state.lastTailImage,
            tailSize: CGSize(width: state.maxWidth, height: state.lastTailHeight)
        )
    }

    /// Appends `rawCode`'s current content (the block's full text so far) for `key`'s hot code
    /// block, returning separate sealed and tail layer content. Any newly sealed line gets an
    /// immediate plain tile (first-paint-before-highlighting); the tail is always plain. When new
    /// lines seal and the block isn't past `adaptiveDeferLineThreshold`, spawns one off-main
    /// tree-sitter parse of the whole sealed prefix; its result lands later via `onRecolor`.
    ///
    /// Bounded per token: only the text appended since the previous call is rescanned for new
    /// sealed lines (not the whole block), and total height is maintained incrementally.
    func append(
        _ key: BlockKey,
        rawCode: String,
        font: VFontDescriptor,
        theme: Theme,
        themeGeneration: Int,
        languageID: LanguageID,
        highlightRegistry: HighlightRegistry,
        scale: CGFloat,
        measure: @escaping (TextDescriptor, CGFloat) -> CGSize,
        eventObserver: (@Sendable (CodeStreamEventKind) -> Void)?,
        onRecolor: @MainActor @escaping (CodeBodyLayerContent) -> Void
    ) -> (height: CGFloat, content: CodeBodyLayerContent) {
        let state = entries[key] ?? State(themeGeneration: themeGeneration, scale: scale)
        entries[key] = state
        if state.themeGeneration != themeGeneration || state.scale != scale {
            state.reset(themeGeneration: themeGeneration, scale: scale)
        }

        let rawUTF8Count = rawCode.utf8.count
        // Content only ever grows while hot. A shrink means the caller restarted this key's
        // content out from under the stream -- resync from scratch rather than underflow.
        if rawUTF8Count < state.processedUTF8Count {
            state.reset(themeGeneration: themeGeneration, scale: scale)
        }
        // `String.UTF8View` is only `BidirectionalCollection`, not `RandomAccessCollection` --
        // `dropFirst(state.processedUTF8Count)` would walk from the start every call, an
        // O(already-processed) cost that grows with the whole block, not the delta. `suffix(_:)`
        // on a bidirectional collection instead walks backward from `endIndex`, so this stays
        // O(delta) regardless of how much of the block has already been processed.
        let deltaByteCount = rawUTF8Count - state.processedUTF8Count
        let delta = deltaByteCount > 0
            ? String(decoding: rawCode.utf8.suffix(deltaByteCount), as: UTF8.self)
            : ""
        state.processedUTF8Count = rawUTF8Count

        let (newSealedLines, tail) = Self.splitSealedAndTail(state.tailText + delta)
        let previousTileCount = state.tiles.count
        for line in newSealedLines {
            let (image, size) = Self.rasterizeLine(
                line, colorRuns: nil, font: font, theme: theme, scale: scale, measure: measure
            )
            state.tiles.append(image)
            state.tileHeights.append(size.height)
            state.sealedLineTexts.append(line)
            state.sealedHeight += size.height
            state.maxWidth = max(state.maxWidth, size.width)
            eventObserver?(.sealedLineTileRasterized)
        }
        let newLinesSealedThisCall = !newSealedLines.isEmpty
        state.tailText = tail

        let (tailImage, tailSize) = Self.rasterizeLine(
            tail, colorRuns: nil, font: font, theme: theme, scale: scale, measure: measure
        )
        eventObserver?(.partialLineRasterized)
        state.maxWidth = max(state.maxWidth, tailSize.width)
        state.lastTailImage = tailImage
        state.lastTailHeight = tailSize.height

        if newLinesSealedThisCall {
            state.sealedComposite = Self.recomposite(
                from: previousTileCount, tiles: state.tiles, tileHeights: state.tileHeights,
                sealedHeight: state.sealedHeight, previousComposite: state.sealedComposite,
                tailImage: nil, tailHeight: 0, maxWidth: state.maxWidth, scale: scale
            )
        }
        let totalHeight = state.sealedHeight + tailSize.height

        if newLinesSealedThisCall, !state.isDeferred {
            if state.tiles.count > adaptiveDeferLineThreshold {
                state.isDeferred = true
            } else {
                spawnParse(
                    key, state: state, coveredLineCount: state.sealedLineTexts.count,
                    font: font, theme: theme, languageID: languageID,
                    highlightRegistry: highlightRegistry, scale: scale, measure: measure,
                    eventObserver: eventObserver, onRecolor: onRecolor
                )
            }
        }

        return (totalHeight, CodeBodyLayerContent(
            sealedImage: state.sealedComposite,
            sealedSize: CGSize(width: state.maxWidth, height: state.sealedHeight),
            tailImage: tailImage,
            tailSize: tailSize
        ))
    }

    /// Called when a code fence closes: the block's content is now fully known and won't grow
    /// further while hot. Folds any still-unsealed tail into one last sealed line, then --
    /// regardless of whether adaptive defer had already stopped intermediate parses -- spawns
    /// exactly one off-main parse covering every line not yet colorized.
    ///
    /// Returns the CURRENT composite synchronously: this reuses already-rasterized tiles and never
    /// runs tree-sitter or a whole-block rasterization inline, so the scroll-adjacent seal path
    /// never blocks on parsing a large block. The fully-colorized composite lands later via
    /// `onRecolor`, exactly like a hot-path recolor. `needsAsyncColorization` tells the caller
    /// whether that delivery is still coming (and therefore whether it's safe to `evict` this key
    /// immediately, or must wait for the delivery to fire first).
    func finalize(
        _ key: BlockKey,
        rawCode: String,
        font: VFontDescriptor,
        theme: Theme,
        themeGeneration: Int,
        languageID: LanguageID,
        highlightRegistry: HighlightRegistry,
        scale: CGFloat,
        measure: @escaping (TextDescriptor, CGFloat) -> CGSize,
        eventObserver: (@Sendable (CodeStreamEventKind) -> Void)?,
        onRecolor: @MainActor @escaping (CodeBodyLayerContent) -> Void
    ) -> (height: CGFloat, content: CodeBodyLayerContent, needsAsyncColorization: Bool) {
        let state = entries[key] ?? State(themeGeneration: themeGeneration, scale: scale)
        entries[key] = state
        if state.themeGeneration != themeGeneration || state.scale != scale {
            state.reset(themeGeneration: themeGeneration, scale: scale)
        }

        let rawUTF8Count = rawCode.utf8.count
        if rawUTF8Count < state.processedUTF8Count {
            state.reset(themeGeneration: themeGeneration, scale: scale)
        }
        // `String.UTF8View` is only `BidirectionalCollection`, not `RandomAccessCollection` --
        // `dropFirst(state.processedUTF8Count)` would walk from the start every call, an
        // O(already-processed) cost that grows with the whole block, not the delta. `suffix(_:)`
        // on a bidirectional collection instead walks backward from `endIndex`, so this stays
        // O(delta) regardless of how much of the block has already been processed.
        let deltaByteCount = rawUTF8Count - state.processedUTF8Count
        let delta = deltaByteCount > 0
            ? String(decoding: rawCode.utf8.suffix(deltaByteCount), as: UTF8.self)
            : ""
        state.processedUTF8Count = rawUTF8Count

        // No more streaming after this call -- the whole remaining tail becomes one final sealed
        // line, even without a trailing newline, so every line in the block gets exactly one tile.
        let (sealedFromRemaining, finalTail) = Self.splitSealedAndTail(state.tailText + delta)
        var newSealedLines = sealedFromRemaining
        if !finalTail.isEmpty {
            newSealedLines.append(finalTail)
        }
        let previousTileCount = state.tiles.count
        for line in newSealedLines {
            let (image, size) = Self.rasterizeLine(
                line, colorRuns: nil, font: font, theme: theme, scale: scale, measure: measure
            )
            state.tiles.append(image)
            state.tileHeights.append(size.height)
            state.sealedLineTexts.append(line)
            state.sealedHeight += size.height
            state.maxWidth = max(state.maxWidth, size.width)
            eventObserver?(.sealedLineTileRasterized)
        }
        state.tailText = ""
        state.lastTailImage = nil
        state.lastTailHeight = 0
        state.isDeferred = false

        state.sealedComposite = Self.recomposite(
            from: previousTileCount, tiles: state.tiles, tileHeights: state.tileHeights, sealedHeight: state.sealedHeight,
            previousComposite: state.sealedComposite,
            tailImage: nil, tailHeight: 0,
            maxWidth: state.maxWidth, scale: scale
        )

        let needsAsync = state.coloredLineCount < state.tiles.count
        if needsAsync {
            spawnParse(
                key, state: state, coveredLineCount: state.tiles.count,
                font: font, theme: theme, languageID: languageID,
                highlightRegistry: highlightRegistry, scale: scale, measure: measure,
                eventObserver: eventObserver, onRecolor: onRecolor
            )
        }

        return (state.sealedHeight, CodeBodyLayerContent(
            sealedImage: state.sealedComposite,
            sealedSize: CGSize(width: state.maxWidth, height: state.sealedHeight),
            tailImage: nil,
            tailSize: .zero
        ), needsAsync)
    }

    /// Tears down every hot-stream entry for a key that scrolled out of the working range, was
    /// removed, or just sealed -- mirrors `HotBlockRasterizerStore.evict(_:)`. Cancels any
    /// in-flight parse/recolor-chunk task first so it can never land on a since-recreated entry
    /// for the same key after a remount.
    public func evict(_ keys: Set<BlockKey>) {
        for key in keys {
            entries[key]?.pendingTask?.cancel()
            entries[key]?.pendingDetachedTask?.cancel()
            entries.removeValue(forKey: key)
        }
    }

    /// Whether every sealed line tile for `key` has received its final off-main colorization --
    /// i.e. no more `onRecolor` deliveries are coming from any spawn already in flight. Callers
    /// use this to decide whether an `onRecolor` delivery is safe to treat as authoritative (cache
    /// it under a stable identity, evict the streaming entry) versus one intermediate chunk among
    /// several -- evicting or identity-caching on an intermediate chunk would strand the remaining
    /// lines uncolored. A key with no entry (never streamed, or already evicted) counts as fully
    /// colorized: there is nothing left pending for it.
    func isFullyColorized(_ key: BlockKey) -> Bool {
        guard let state = entries[key] else { return true }
        return state.coloredLineCount >= state.tiles.count
    }
}
#endif

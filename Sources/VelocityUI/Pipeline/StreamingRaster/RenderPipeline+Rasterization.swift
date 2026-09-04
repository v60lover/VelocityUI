// RenderPipeline+Rasterization.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics
import SwaTex
import SwaTexRender

struct TextBitmapArtifact: @unchecked Sendable {
    let key: BlockKey
    let image: CGImage
    let size: CGSize
    /// `CGImage` is immutable; this optional identity is present only for code-body rasters.
    let codeBodyIdentity: CodeBodyRasterIdentity?
}

/// Rasterizes plain text normally and code bodies with syntax highlighting and no wrapping.
/// A supplied body raster has already passed layout and raster-identity checks, so reuse skips
/// tree-sitter tokenization and wide rasterization.
nonisolated func rasterizeTextFragment(
    _ descriptor: TextDescriptor,
    frameSize: CGSize,
    layoutWidth: CGFloat,
    scale: CGFloat,
    highlightRegistry: HighlightRegistry,
    theme: Theme,
    existingBodyRaster: (image: CGImage, size: CGSize)?
) -> (image: CGImage?, size: CGSize, retokenized: Bool) {
    guard case .body(let chrome) = descriptor.codeBlockRole else {
        // layoutWidth is the full width the fragment was measured at (see LayoutEngine's
        // `.text` case); frameSize is the tight measured size -- laying out narrower than
        // measurement here is exactly the clip bug this split fixes.
        return (
            rasterizeText(descriptor, layoutWidth: layoutWidth, outputSize: frameSize, scale: scale),
            frameSize, false
        )
    }
    if let existingBodyRaster {
        return (existingBodyRaster.image, existingBodyRaster.size, false)
    }
    let lines = descriptor.content.components(separatedBy: "\n")[...]
    let grammar = highlightRegistry.grammar(for: LanguageID(fenceInfo: chrome.language))
    let colorRuns = TreeSitterHighlighter().colorRuns(for: lines, grammar: grammar, theme: theme)
    let (image, size) = rasterizeCodeBlockSync(
        lines: lines, colorRuns: colorRuns, font: descriptor.font, theme: theme, scale: scale
    ) { d, w in TextMeasurementContext().measure(d, width: w) }
    return (image, size, true)
}

/// A layout-cache hit guarantees unchanged content. Reuse additionally requires an exact match
/// for the theme generation and display scale that produced the cached pixels.
///
/// Returns the regenerated-code-body count alongside the artifacts, which the caller reports
/// through `RenderEnvironment.codeBodyRetokenizeObserver` — production-safe observability for the
/// cache-hit reuse invariant, mirroring `pipelineTaskSpawnObserver`.
nonisolated func rasterizeTextArtifacts(
    table: NodeTable,
    fragments: [Fragment],
    layoutWidth: CGFloat,
    scale: CGFloat,
    highlightRegistry: HighlightRegistry,
    themeSnapshot: HighlightThemeSnapshot,
    reusableFrom: FrozenBitmapStore?
) -> (artifacts: [TextBitmapArtifact], codeBodyRetokenizeCount: Int) {
    let itemID = table.itemID
    let codeBodyIdentity = CodeBodyRasterIdentity(
        themeGeneration: themeSnapshot.generation,
        scale: scale
    )
    var retokenizeCount = 0
    let artifacts: [TextBitmapArtifact] = fragments.enumerated().compactMap { position, fragment in
        guard case .text(let descriptor) = fragment.content else { return nil }
        let key = BlockKey(boxedItemID: itemID, index: position, blockID: fragment.blockID)
        let isCodeBody: Bool
        if case .body = descriptor.codeBlockRole { isCodeBody = true } else { isCodeBody = false }
        let existing: (image: CGImage, size: CGSize)? = isCodeBody
            ? reusableFrom?.codeBodyRaster(for: key, identity: codeBodyIdentity)
            : nil
        let (image, size, retokenized) = rasterizeTextFragment(
            descriptor, frameSize: fragment.frame.size, layoutWidth: layoutWidth, scale: scale,
            highlightRegistry: highlightRegistry,
            theme: themeSnapshot.theme,
            existingBodyRaster: existing
        )
        guard let image else { return nil }
        if retokenized { retokenizeCount += 1 }
        return TextBitmapArtifact(
            key: key, image: image, size: size,
            codeBodyIdentity: isCodeBody ? codeBodyIdentity : nil
        )
    }
    return (artifacts, retokenizeCount)
}

/// Rasterizes every `.table` fragment into one BGRA8888 premultiplied `CGImage`, mirroring
/// `rasterizeTextArtifacts`'s shape. Re-solves column widths and cell layout from the original
/// `MarkdownTableDescriptor` (looked up back on `table.nodes[fragment.id]`, same as
/// `materializeCodeBlockFragments`'s callers re-derive code text from `CodeBlockDescriptor`) --
/// `extractFragments` only carries geometry forward, not the cell grid itself.
///
/// Always a full re-raster, never an incremental append -- a table's column widths are a
/// function of every row, so a newly-arrived row can retroactively resize columns under
/// already-rasterized rows. TABLE_RENDER_DESIGN.md "Streaming" describes exactly this: a hot
/// table re-rasterizes whole, unlike a hot code body's independent per-line tiles.
nonisolated func rasterizeTableArtifacts(
    table: NodeTable,
    fragments: [Fragment],
    scale: CGFloat
) -> [TextBitmapArtifact] {
    let itemID = table.itemID
    return fragments.enumerated().compactMap { position, fragment -> TextBitmapArtifact? in
        guard case .table = fragment.content,
              fragment.id >= 0, fragment.id < table.nodes.count,
              case .table(let descriptor) = table.nodes[fragment.id]
        else { return nil }
        let key = BlockKey(boxedItemID: itemID, index: position, blockID: fragment.blockID)
        let measure: TextMeasure = { d, w in TextMeasurementContext().measure(d, width: w) }
        // solve/layout/raster must share one padding value (rasterizeTable's precondition).
        let padding = TableCellPadding.default
        let solution = solveColumnWidths(
            cells: descriptor.cells, availableWidth: fragment.frame.width, measure: measure, padding: padding
        )
        let resolved = layoutTableCells(
            cells: descriptor.cells, columnWidths: solution.widths, alignments: descriptor.alignments,
            measure: measure, padding: padding
        )
        let raster = rasterizeTable(
            layout: resolved, gridColor: .tableGridLine, backgroundColor: .codeBlockBackground,
            padding: padding, scale: scale
        )
        guard let image = raster.image else { return nil }
        return TextBitmapArtifact(key: key, image: image, size: raster.size, codeBodyIdentity: nil)
    }
}

/// Rasterizes every `.mathBlock` fragment into one BGRA8888 premultiplied `CGImage`, mirroring
/// `rasterizeTableArtifacts`'s shape exactly. Re-derives the layout decision (formula vs.
/// literal-text fallback) from the original `MathBlockDescriptor` via `layoutMathBlock` -- the
/// same pure function `LayoutEngine`'s `.mathBlock` case already called, so the two can never
/// disagree on which branch applies (Section 3 cross-site consistency).
///
/// Always a full re-raster on every call, mirroring the table contract's "never an incremental
/// append, a change re-solves whole" -- matches MATH_RENDER_DESIGN.md's streaming behavior: "on
/// each token that completes a formula the block re-typesets — cheap, off-MainActor" (SwaTex
/// parse+layout is ~70µs uncached, ~100ns on a `FormulaCache` hit).
nonisolated func rasterizeMathArtifacts(
    table: NodeTable,
    fragments: [Fragment],
    scale: CGFloat,
    formulaCache: FormulaCache?,
    fontProvider: KaTeXFontProvider
) -> [TextBitmapArtifact] {
    let itemID = table.itemID
    return fragments.enumerated().compactMap { position, fragment -> TextBitmapArtifact? in
        guard case .mathBlock = fragment.content,
              fragment.id >= 0, fragment.id < table.nodes.count,
              case .mathBlock(let descriptor) = table.nodes[fragment.id]
        else { return nil }
        let key = BlockKey(boxedItemID: itemID, index: position, blockID: fragment.blockID)
        // `fragment.frame.width` is the card's pinned container width -- the same value
        // `LayoutEngine`'s `.mathBlock` case measured against, so the literal-fallback wrap
        // width and the formula/canvas centering base both agree with what was measured.
        let blockWidth = fragment.frame.width
        let mathLayout = layoutMathBlock(
            rawTeX: descriptor.rawTeX, font: descriptor.font, color: descriptor.color,
            width: blockWidth, cache: formulaCache,
            measure: { d, w in TextMeasurementContext().measure(d, width: w) }
        )
        let raster = rasterizeMathBlock(mathLayout, blockWidth: blockWidth, scale: scale, fontProvider: fontProvider)
        guard let image = raster.image else { return nil }
        return TextBitmapArtifact(key: key, image: image, size: raster.size, codeBodyIdentity: nil)
    }
}
#endif

// RenderPipeline+Rasterization.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

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
#endif

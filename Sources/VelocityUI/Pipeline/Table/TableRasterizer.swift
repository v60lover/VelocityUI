// TableRasterizer.swift

#if canImport(UIKit)
import UIKit

/// Draws a resolved table layout (VelocityUI-8ge8.3's `layoutTableCells`) into one BGRA8888
/// premultiplied `CGImage`, mirroring `CodeBlockRasterizer`'s "one raster, one CGContext" shape.
///
/// `layout.size` is `ResolvedTableLayout`'s own documented pre-gridline content size (Σ column
/// widths, Σ row heights) -- this function is the one place that reserves real space for
/// gridlines on top of it, so the returned `size` is `Σ final column widths + gridlines`
/// (TABLE_RENDER_DESIGN.md "Rendering" / this bead's acceptance criterion), not `layout.size`
/// itself.
///
/// Precondition: `padding` must equal the `padding` passed to the `layoutTableCells` call that
/// produced `layout` -- this function recomputes each cell's wrap width
/// (`columnWidth - 2*padding.horizontal`) to re-rasterize the same text at the same wrap the
/// layout was measured at; a mismatched `padding` would wrap differently than what `layout`'s
/// row heights and text frames already account for (same shared-value contract shape as
/// `RenderEnvironment`'s `imageActor.dimensionCache === dimensionCache` precondition).
///
/// Uses `UIGraphicsImageRenderer` for the outer canvas. Plain fills/strokes (background,
/// gridlines) honor `layout.rows[i].frame`'s top-left/y-down coordinates directly. Per-cell text
/// images do not: empirically, `CGContext.draw(_:in:)` for a `CGImage` in this renderer places the
/// rect mirrored around the canvas's vertical center rather than top-down (a two-row fixture came
/// back with row 0's and row 1's ink swapped). `drawCGImage(_:in:canvasHeight:context:)` below
/// corrects for that -- see its own doc comment for what was actually tried and ruled out.
///
/// Pure/nonisolated -- no cache lookup, no global state (Design Principle 4). `gridColor`/
/// `backgroundColor` have no default, mirroring `rasterizeCodeBlockBackground(cornerRadius:
/// color:scale:)`'s required color param -- adding a shared default color belongs to node/mount
/// wiring (VelocityUI-8ge8.5/.6), not this rasterizer.
func rasterizeTable(
    layout: ResolvedTableLayout,
    gridColor: VColorDescriptor,
    backgroundColor: VColorDescriptor,
    cornerRadius: CGFloat = 12,
    gridLineWidth: CGFloat = 1,
    padding: TableCellPadding = .default,
    scale: CGFloat = 1
) -> (image: CGImage?, size: CGSize) {
    guard !layout.rows.isEmpty, !layout.columnWidths.isEmpty,
          layout.size.width > 0, layout.size.height > 0
    else { return (nil, .zero) }

    // One forward pass per axis: accumulates each column/row's content-start offset in the
    // gridline-reserved canvas, plus every divider's leading edge -- boundaryXs/boundaryYs has
    // columnCount+1 / rowCount+1 entries (one leading edge per column/row, plus the trailing
    // outer border), each `gridLineWidth` wide.
    var boundaryXs: [CGFloat] = []
    var columnOffsets: [CGFloat] = []
    var xCursor: CGFloat = 0
    for width in layout.columnWidths {
        boundaryXs.append(xCursor)
        xCursor += gridLineWidth
        columnOffsets.append(xCursor)
        xCursor += width
    }
    boundaryXs.append(xCursor)
    xCursor += gridLineWidth
    let totalWidth = xCursor

    var boundaryYs: [CGFloat] = []
    var rowOffsets: [CGFloat] = []
    var yCursor: CGFloat = 0
    for row in layout.rows {
        boundaryYs.append(yCursor)
        yCursor += gridLineWidth
        rowOffsets.append(yCursor)
        yCursor += row.frame.height
    }
    boundaryYs.append(yCursor)
    yCursor += gridLineWidth
    let totalHeight = yCursor

    // Snap to the pixel grid at `scale` before sizing the renderer. Row heights come from real
    // (fractional) text measurement, so `totalHeight` is rarely a whole point value; leaving it
    // fractional makes `normaliseAndRound`'s pixel-size check below miss its fast path, forcing a
    // rescale blit that antialiases the canvas edges (a corner pixel that should be fully opaque
    // reads back partially transparent). Matches the same `pixelLength`-based canvas sizing every
    // other rasterizer in this codebase (e.g. `normaliseAndRound` itself) already uses.
    let pixelWidth = pixelLength(totalWidth, scale: scale)
    let pixelHeight = pixelLength(totalHeight, scale: scale)
    let totalSize = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    let bounds = CGRect(origin: .zero, size: totalSize)

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: totalSize, format: format)

    let uiImage = renderer.image { rendererContext in
        let cgContext = rendererContext.cgContext

        // Round the outer container via CGContext clip -- never CALayer.cornerRadius/masksToBounds.
        if cornerRadius > 0 {
            let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            cgContext.addPath(path)
            cgContext.clip()
        }

        cgContext.setFillColor(red: backgroundColor.red, green: backgroundColor.green, blue: backgroundColor.blue, alpha: backgroundColor.alpha)
        cgContext.fill(bounds)

        cgContext.setFillColor(red: gridColor.red, green: gridColor.green, blue: gridColor.blue, alpha: gridColor.alpha)
        for x in boundaryXs {
            cgContext.fill(CGRect(x: x, y: 0, width: gridLineWidth, height: totalHeight))
        }
        for y in boundaryYs {
            cgContext.fill(CGRect(x: 0, y: y, width: totalWidth, height: gridLineWidth))
        }

        for (rowIndex, row) in layout.rows.enumerated() {
            let dy = rowOffsets[rowIndex] - row.frame.minY
            for (columnIndex, cell) in row.cells.enumerated() {
                guard columnIndex < layout.columnWidths.count else { continue }
                let dx = columnOffsets[columnIndex] - cell.frame.minX
                let contentWidth = max(0, layout.columnWidths[columnIndex] - 2 * padding.horizontal)

                guard let cellImage = rasterizeText(
                    cell.descriptor,
                    layoutWidth: contentWidth,
                    outputSize: cell.textFrame.size,
                    scale: scale,
                    inkGuard: codeInkRightGuard
                ) else { continue }

                let drawnWidth = CGFloat(cellImage.width) / scale
                let drawnHeight = CGFloat(cellImage.height) / scale
                let drawRect = CGRect(
                    x: cell.textFrame.minX + dx,
                    y: cell.textFrame.minY + dy,
                    width: drawnWidth,
                    height: drawnHeight
                )
                drawCGImage(cellImage, in: drawRect, canvasHeight: totalHeight, context: cgContext)
            }
        }
    }

    guard let compositeImage = uiImage.cgImage else { return (nil, .zero) }
    // Corners are already rounded above; cornerRadius: 0 here only guarantees the BGRA8888
    // premultiplied acceptance criterion, reusing ImageNormaliser's existing reblit/fast-path
    // instead of a second hand-rolled format check (Section 5 sibling-pattern reuse).
    let normalised = normaliseAndRound(compositeImage, targetSize: totalSize, cornerRadius: 0, scale: scale)
    return (normalised, totalSize)
}

/// Draws `image` so its visual top-left lands at `rect.origin` (measured top-down from the
/// canvas, matching every other coordinate in this file) and its visual bottom-right at
/// `rect.origin + rect.size`.
///
/// Verified empirically, not derived from CTM theory: inside a `UIGraphicsImageRenderer` canvas,
/// plain fills/strokes (the background and gridlines above) already honor a top-left/y-down
/// `CGRect` directly, but `CGContext.draw(_:in:)` for a `CGImage` does not -- a rect placed at
/// `y0` lands mirrored around the canvas's vertical center, at `canvasHeight - y0 - height`. (Two
/// independent fixes -- an unadorned `context.draw`, and a manual local CTM flip/translate around
/// the rect -- both reproduced the same mirrored placement, which rules out a simple double-flip
/// and points at `CGContextDrawImage`'s own behavior disagreeing with this renderer's ambient
/// space specifically for images.) Converting `rect.minY` through this mirror before drawing
/// corrects it back to top-down placement, confirmed by `TableRasterizerTests
/// .testCellTextPlacedCorrectly_eachRowStaysInOwnBand`.
private func drawCGImage(_ image: CGImage, in rect: CGRect, canvasHeight: CGFloat, context: CGContext) {
    let mirroredRect = CGRect(
        x: rect.minX,
        y: canvasHeight - rect.minY - rect.height,
        width: rect.width,
        height: rect.height
    )
    context.draw(image, in: mirroredRect)
}
#endif

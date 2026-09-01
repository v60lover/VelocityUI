// TableCellLayout.swift

import CoreGraphics

/// Horizontal/vertical breathing room inside every cell, applied on both sides of the wrapped
/// text. `default` isn't matched to an existing constant elsewhere in the codebase — chosen
/// consistent with the general text-padding scale `CodeBlockNode`'s header/body split uses.
public struct TableCellPadding: Sendable, Equatable {
    public let horizontal: CGFloat
    public let vertical: CGFloat

    public init(horizontal: CGFloat, vertical: CGFloat) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let `default` = TableCellPadding(horizontal: 8, vertical: 6)
}

/// One cell's resolved layout: its styled text plus where it draws. `frame` is the cell's full
/// box (one column wide, one row tall — GFM has no colspan/rowspan) in table-content coordinates,
/// origin at the table's top-left. `textFrame` is where the wrapped text paints inside that box,
/// already offset for padding and the column's alignment.
public struct ResolvedTableCell: Sendable {
    public let descriptor: TextDescriptor
    public let frame: CGRect
    public let textFrame: CGRect

    public init(descriptor: TextDescriptor, frame: CGRect, textFrame: CGRect) {
        self.descriptor = descriptor
        self.frame = frame
        self.textFrame = textFrame
    }
}

/// One row's resolved layout: `frame.height` is the tallest cell's wrapped height plus vertical
/// padding (TABLE_RENDER_DESIGN.md "Row heights and cell layout") — every cell in the row shares
/// that height, top-aligned within it.
public struct ResolvedTableRow: Sendable {
    public let cells: [ResolvedTableCell]
    public let frame: CGRect
    public let isHeader: Bool

    public init(cells: [ResolvedTableCell], frame: CGRect, isHeader: Bool) {
        self.cells = cells
        self.frame = frame
        self.isHeader = isHeader
    }
}

/// The resolved table layout `TableRasterizer` (VelocityUI-8ge8.4) consumes: every cell's rect
/// and text placement, plus the column widths and overall content size the caller already knows
/// from `solveColumnWidths`.
public struct ResolvedTableLayout: Sendable {
    public let rows: [ResolvedTableRow]
    public let columnWidths: [CGFloat]
    public let size: CGSize

    public init(rows: [ResolvedTableRow], columnWidths: [CGFloat], size: CGSize) {
        self.rows = rows
        self.columnWidths = columnWidths
        self.size = size
    }
}

/// Converts a parsed table's raw cell grid (`ParsedMDBlock.tableRows` — row 0 is the header,
/// `[1...]` are body rows) into the `[[TextDescriptor]]` shape `measureColumnIntrinsics` /
/// `solveColumnWidths` (VelocityUI-8ge8.2) already consume, so the header-bold descriptors built
/// here are exactly what the column-width solver measures — no second, parallel descriptor path.
///
/// Header row renders in a bold variant of `font` (same size/family/traits, heavier weight);
/// body rows render in `font` as-is. Per-cell inline emphasis (`TableCell.runs`, already
/// tokenized by the parser) folds in via `IncrementalMarkdownParser.textRun(for:baseFont:baseColor:)`
/// — the same bold/italic/code/strike/link mapping paragraphs and headings use, so a `**bold**`
/// table cell can never render differently than a `**bold**` paragraph span.
///
/// Pure/nonisolated — no cache lookup, no global state (Design Principle 4).
///
/// Internal, not public: `TableCell` (the parser's raw cell type) is internal, so this can't be
/// a public entry point until a public-facing table node (VelocityUI-8ge8.5) wraps it.
nonisolated func makeTableCellDescriptors(
    tableRows: [[TableCell]],
    font: VFontDescriptor,
    color: VColorDescriptor = .primary
) -> [[TextDescriptor]] {
    let headerFont = VFontDescriptor(
        size: font.size, weight: VFontDescriptor.boldWeight, family: font.family, traits: font.traits
    )

    return tableRows.enumerated().map { rowIndex, row in
        let rowFont = rowIndex == 0 ? headerFont : font
        return row.map { cell in
            let runs = cell.runs.map { IncrementalMarkdownParser.textRun(for: $0, baseFont: rowFont, baseColor: color) }
            var hasher = Hasher()
            hasher.combine(cell.text)
            hasher.combine(runs)
            let hash = hasher.finalize()
            return TextDescriptor(
                content: cell.text,
                font: rowFont,
                color: color,
                lineLimit: nil,
                lineBreakMode: 0,
                runs: runs,
                layoutHash: hash,
                appearanceHash: hash
            )
        }
    }
}

/// Lays out a table's cells given its final column widths (from `solveColumnWidths`) — wraps
/// each cell's text at its column, computes row heights, and places text inside its column rect
/// per the column's alignment. TABLE_RENDER_DESIGN.md "Row heights and cell layout".
///
/// - Row height = the row's tallest wrapped cell height + `padding.vertical` on both sides.
/// - Every cell in a row shares that row's height, top-aligned within it — GFM defines no
///   per-cell vertical alignment.
/// - Horizontal placement of a cell's text honors that column's `alignments` entry: `.left`/
///   `.none` flush left, `.center` centers the leftover slack, `.right` flushes right — all
///   measured inside the cell's padded content box, never the raw column width.
/// - No colspan/rowspan: `cells[row][column]` maps 1:1 onto `columnWidths[column]`, one column
///   wide and one row tall.
///
/// Rows/cells with fewer entries than `columnWidths` (a short parse) are laid out for the
/// columns they actually have — no synthesized empty cells.
///
/// Pure/nonisolated — `measure` is injected exactly like `TextMeasure` in
/// `measureColumnIntrinsics`, so this stays UIKit-free (Design Principle 4).
public nonisolated func layoutTableCells(
    cells: [[TextDescriptor]],
    columnWidths: [CGFloat],
    alignments: [TableColumnAlignment],
    measure: TextMeasure,
    padding: TableCellPadding = .default
) -> ResolvedTableLayout {
    guard !cells.isEmpty, !columnWidths.isEmpty else {
        return ResolvedTableLayout(rows: [], columnWidths: columnWidths, size: .zero)
    }

    var rows: [ResolvedTableRow] = []
    rows.reserveCapacity(cells.count)
    var yCursor: CGFloat = 0

    for (rowIndex, rowCells) in cells.enumerated() {
        let columnCount = min(rowCells.count, columnWidths.count)

        var measuredSizes: [CGSize] = []
        measuredSizes.reserveCapacity(columnCount)
        var rowHeight: CGFloat = 0
        for columnIndex in 0..<columnCount {
            let contentWidth = max(0, columnWidths[columnIndex] - 2 * padding.horizontal)
            let size = measure(rowCells[columnIndex], contentWidth)
            measuredSizes.append(size)
            rowHeight = max(rowHeight, size.height + 2 * padding.vertical)
        }

        var resolvedCells: [ResolvedTableCell] = []
        resolvedCells.reserveCapacity(columnCount)
        var xCursor: CGFloat = 0
        for columnIndex in 0..<columnCount {
            let columnWidth = columnWidths[columnIndex]
            let descriptor = rowCells[columnIndex]
            let measuredSize = measuredSizes[columnIndex]
            let cellFrame = CGRect(x: xCursor, y: yCursor, width: columnWidth, height: rowHeight)

            let contentWidth = max(0, columnWidth - 2 * padding.horizontal)
            let slack = max(0, contentWidth - measuredSize.width)
            let alignment = columnIndex < alignments.count ? alignments[columnIndex] : .none
            let textOffsetX: CGFloat
            switch alignment {
            case .left, .none: textOffsetX = 0
            case .center: textOffsetX = slack / 2
            case .right: textOffsetX = slack
            }

            let textFrame = CGRect(
                x: cellFrame.minX + padding.horizontal + textOffsetX,
                y: cellFrame.minY + padding.vertical,
                width: measuredSize.width,
                height: measuredSize.height
            )
            resolvedCells.append(ResolvedTableCell(descriptor: descriptor, frame: cellFrame, textFrame: textFrame))
            xCursor += columnWidth
        }

        let rowFrame = CGRect(x: 0, y: yCursor, width: xCursor, height: rowHeight)
        rows.append(ResolvedTableRow(cells: resolvedCells, frame: rowFrame, isHeader: rowIndex == 0))
        yCursor += rowHeight
    }

    let totalWidth = columnWidths.reduce(0, +)
    return ResolvedTableLayout(rows: rows, columnWidths: columnWidths, size: CGSize(width: totalWidth, height: yCursor))
}

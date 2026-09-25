// HotTableLayoutState.swift

#if canImport(UIKit)
import CoreGraphics

/// Retains one table's geometry while its store entry serializes render requests.
/// The scheduler permits one active renderer per state, so its mutable fields are never concurrent.
final class HotTableLayoutState: @unchecked Sendable {
    private struct Retained {
        let cells: [[TextDescriptor]]
        let alignments: [TableColumnAlignment]
        let availableWidth: CGFloat
        let padding: TableCellPadding
        let intrinsics: [ColumnIntrinsics]
        let layout: ResolvedTableLayout
    }

    private var retained: Retained?

    func resolve(
        cells: [[TextDescriptor]],
        availableWidth: CGFloat,
        alignments: [TableColumnAlignment],
        measure: TextMeasure,
        padding: TableCellPadding
    ) -> ResolvedTableLayout {
        guard isRectangular(cells) else {
            retained = nil
            return fullLayout(
                cells: cells, availableWidth: availableWidth, alignments: alignments,
                measure: measure, padding: padding
            )
        }

        guard let previous = retained,
              isStrictAppend(of: previous.cells, in: cells),
              previous.alignments == alignments,
              previous.availableWidth == availableWidth,
              previous.padding == padding
        else {
            return replace(
                cells: cells, availableWidth: availableWidth, alignments: alignments,
                measure: measure, padding: padding
            )
        }

        let appendedCells = Array(cells.dropFirst(previous.cells.count))
        let appendedIntrinsics = measureColumnIntrinsics(
            cells: appendedCells, measure: measure, padding: padding
        )
        let intrinsics = zip(previous.intrinsics, appendedIntrinsics).map { old, new in
            ColumnIntrinsics(min: max(old.min, new.min), max: max(old.max, new.max))
        }
        let solution = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)

        guard solution.widths == previous.layout.columnWidths else {
            return replace(
                cells: cells, availableWidth: availableWidth, alignments: alignments,
                measure: measure, padding: padding
            )
        }

        let appendedLayout = layoutTableCells(
            cells: appendedCells, columnWidths: solution.widths, alignments: alignments,
            measure: measure, padding: padding
        )
        let layout = appending(appendedLayout, to: previous.layout)
        retained = Retained(
            cells: cells, alignments: alignments, availableWidth: availableWidth, padding: padding,
            intrinsics: intrinsics, layout: layout
        )
        return layout
    }

    private func replace(
        cells: [[TextDescriptor]],
        availableWidth: CGFloat,
        alignments: [TableColumnAlignment],
        measure: TextMeasure,
        padding: TableCellPadding
    ) -> ResolvedTableLayout {
        let intrinsics = measureColumnIntrinsics(cells: cells, measure: measure, padding: padding)
        let solution = solveColumnWidths(intrinsics: intrinsics, availableWidth: availableWidth)
        let layout = layoutTableCells(
            cells: cells, columnWidths: solution.widths, alignments: alignments,
            measure: measure, padding: padding
        )
        retained = Retained(
            cells: cells, alignments: alignments, availableWidth: availableWidth, padding: padding,
            intrinsics: intrinsics, layout: layout
        )
        return layout
    }

    private func fullLayout(
        cells: [[TextDescriptor]],
        availableWidth: CGFloat,
        alignments: [TableColumnAlignment],
        measure: TextMeasure,
        padding: TableCellPadding
    ) -> ResolvedTableLayout {
        let solution = solveColumnWidths(
            cells: cells, availableWidth: availableWidth, measure: measure, padding: padding
        )
        return layoutTableCells(
            cells: cells, columnWidths: solution.widths, alignments: alignments,
            measure: measure, padding: padding
        )
    }

    private func isRectangular(_ cells: [[TextDescriptor]]) -> Bool {
        guard let columnCount = cells.first?.count, columnCount > 0 else { return false }
        return cells.allSatisfy { $0.count == columnCount }
    }

    private func isStrictAppend(of previous: [[TextDescriptor]], in cells: [[TextDescriptor]]) -> Bool {
        guard cells.count > previous.count else { return false }
        return zip(previous, cells).allSatisfy { sameRow($0, $1) }
    }

    private func sameRow(_ lhs: [TextDescriptor], _ rhs: [TextDescriptor]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { sameDescriptor($0, $1) }
    }

    private func sameDescriptor(_ lhs: TextDescriptor, _ rhs: TextDescriptor) -> Bool {
        lhs.content == rhs.content && lhs.font == rhs.font && lhs.color == rhs.color
            && lhs.lineLimit == rhs.lineLimit && lhs.lineBreakMode == rhs.lineBreakMode
            && lhs.underlineStyle == rhs.underlineStyle && lhs.strikethroughStyle == rhs.strikethroughStyle
            && lhs.kerning == rhs.kerning && lhs.lineSpacing == rhs.lineSpacing
            && lhs.contentSizeCategory == rhs.contentSizeCategory && lhs.runs == rhs.runs
            && lhs.leadingBarColor == rhs.leadingBarColor && lhs.leadingBarWidth == rhs.leadingBarWidth
            && lhs.leadingBarGap == rhs.leadingBarGap && lhs.ruleColor == rhs.ruleColor
            && lhs.alignment == rhs.alignment && lhs.maxWidthFraction == rhs.maxWidthFraction
            && lhs.layoutHash == rhs.layoutHash && lhs.appearanceHash == rhs.appearanceHash
            && lhs.codeBlockRole == rhs.codeBlockRole && lhs.backgroundChrome == rhs.backgroundChrome
    }

    private func appending(_ appended: ResolvedTableLayout, to previous: ResolvedTableLayout) -> ResolvedTableLayout {
        let offset = previous.size.height
        let rows = previous.rows + appended.rows.map { row in
            let cells = row.cells.map { cell in
                ResolvedTableCell(
                    descriptor: cell.descriptor,
                    frame: cell.frame.offsetBy(dx: 0, dy: offset),
                    textFrame: cell.textFrame.offsetBy(dx: 0, dy: offset)
                )
            }
            return ResolvedTableRow(
                cells: cells, frame: row.frame.offsetBy(dx: 0, dy: offset), isHeader: false
            )
        }
        return ResolvedTableLayout(
            rows: rows, columnWidths: previous.columnWidths,
            size: CGSize(width: previous.size.width, height: previous.size.height + appended.size.height)
        )
    }
}
#endif

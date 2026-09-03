// TableColumnWidthSolver.swift

import CoreGraphics

/// A column's intrinsic width bounds. `min` is the widest unbreakable token in the column —
/// below it a word would clip. `max` is the column's widest cell laid out on one line.
public struct ColumnIntrinsics: Equatable, Sendable {
    public let min: CGFloat
    public let max: CGFloat

    public init(min: CGFloat, max: CGFloat) {
        self.min = min
        self.max = max
    }
}

/// Extra slack folded into every column's intrinsic width before it becomes a wrap constraint.
/// TextKit breaks a line when the next token *reaches* the container edge, so a column sized to
/// exactly its measured ink width re-wraps the last glyph on floating-point equality. One point
/// keeps that glyph on its line — same role as `rasterizeText`'s `inkGuard`.
let columnInkWrapGuard: CGFloat = 1

/// Result of `solveColumnWidths`. `overflow` is true only when the table can't fit even at
/// every column's `min` width — the caller should turn on horizontal scroll.
public struct ColumnWidthSolution: Equatable, Sendable {
    public let widths: [CGFloat]
    public let overflow: Bool

    public init(widths: [CGFloat], overflow: Bool) {
        self.widths = widths
        self.overflow = overflow
    }
}

/// Two-pass column width solver — TABLE_RENDER_DESIGN.md "Column-width algorithm".
///
/// - Branch 1 (`availableWidth >= Σmax`): every column gets its natural `max` width.
/// - Branch 2 (`Σmin <= availableWidth < Σmax`): grow each column from `min` proportional to
///   its flexibility `(max - min)`, so a single-word column (`max == min`) never grows while a
///   prose column soaks up the slack and wraps. This is the stricter CSS rule, not Telegram's
///   proportional-to-max.
/// - Branch 3 (`availableWidth < Σmin`): can't shrink further; keep the natural `min` widths
///   and report `overflow = true`.
///
/// Pure/nonisolated — no cache lookup, no global state (Design Principle 4). `intrinsics` must
/// already carry real per-column measurements; see `measureColumnIntrinsics(cells:measure:)`.
public nonisolated func solveColumnWidths(
    intrinsics: [ColumnIntrinsics],
    availableWidth: CGFloat
) -> ColumnWidthSolution {
    guard !intrinsics.isEmpty else {
        return ColumnWidthSolution(widths: [], overflow: false)
    }

    let totalMin = intrinsics.reduce(CGFloat(0)) { $0 + $1.min }
    let totalMax = intrinsics.reduce(CGFloat(0)) { $0 + $1.max }

    if availableWidth >= totalMax {
        return ColumnWidthSolution(widths: intrinsics.map(\.max), overflow: false)
    }
    if availableWidth < totalMin {
        return ColumnWidthSolution(widths: intrinsics.map(\.min), overflow: true)
    }

    // totalMin <= availableWidth < totalMax here, so totalMin < totalMax and
    // totalFlex below is strictly positive — no division by zero.
    let surplus = availableWidth - totalMin
    let totalFlex = totalMax - totalMin
    let widths = intrinsics.map { column -> CGFloat in
        let flex = column.max - column.min
        return column.min + flex * surplus / totalFlex
    }
    return ColumnWidthSolution(widths: widths, overflow: false)
}

/// Measures per-column `min`/`max` intrinsics from a rows-by-columns grid of already-styled
/// cell descriptors (picking the header vs. body font per cell is the caller's job — this
/// function stays free of font/theme concerns and only measures what it's given).
///
/// `max` = each cell's natural single-line width (`measure(descriptor, .greatestFiniteMagnitude)`).
/// `min` = the widest whitespace-delimited token in the cell: a token has no internal break
/// opportunity, so its own natural width is the floor below which it would clip. A cell with no
/// whitespace can't wrap at all, so its floor is its full `naturalWidth` (measured with runs),
/// not a re-measured runs-less token that would underestimate a styled cell.
///
/// Both bounds include `2 * padding.horizontal` plus `columnInkWrapGuard`, so solved column
/// widths reserve the cell's horizontal padding and a hairline of wrap slack —
/// `layoutTableCells`/`rasterizeTable` subtract the padding back and the guard keeps the last
/// glyph on one line. `padding` must match theirs.
///
/// `measure` is injected exactly like `TextMeasure` in FreezeState.swift, so this stays
/// pure/nonisolated and UIKit-free — same sibling pattern as `freeze(_:)`.
public nonisolated func measureColumnIntrinsics(
    cells: [[TextDescriptor]],
    measure: TextMeasure,
    padding: TableCellPadding = .default
) -> [ColumnIntrinsics] {
    guard let columnCount = cells.first?.count else { return [] }

    var mins = [CGFloat](repeating: 0, count: columnCount)
    var maxs = [CGFloat](repeating: 0, count: columnCount)

    for row in cells {
        for (columnIndex, descriptor) in row.enumerated() where columnIndex < columnCount {
            let naturalWidth = measure(descriptor, .greatestFiniteMagnitude).width
            maxs[columnIndex] = max(maxs[columnIndex], naturalWidth)

            // A cell with no internal break opportunity can't wrap, so its floor is its own
            // rendered width -- `naturalWidth`, measured on the real descriptor (runs and all).
            // Re-measuring a stripped, runs-less token instead would underestimate any styled
            // cell (a bold header, an inline-code span) and let it wrap one glyph in overflow.
            let hasBreakOpportunity = descriptor.content.contains { $0.isWhitespace }
            let widestToken: CGFloat
            if hasBreakOpportunity {
                widestToken = descriptor.content
                    .split(whereSeparator: { $0.isWhitespace })
                    .map { token in
                        measure(
                            TextDescriptor(
                                content: String(token),
                                font: descriptor.font,
                                color: descriptor.color,
                                lineLimit: descriptor.lineLimit,
                                lineBreakMode: descriptor.lineBreakMode,
                                layoutHash: 0,
                                appearanceHash: 0
                            ),
                            .greatestFiniteMagnitude
                        ).width
                    }
                    .max() ?? naturalWidth
            } else {
                widestToken = naturalWidth
            }
            mins[columnIndex] = max(mins[columnIndex], widestToken)
        }
    }

    // `columnInkWrapGuard` keeps the last glyph on one line (TextKit wraps on exact-width
    // equality); `horizontalPadding` is the cell's padding the downstream layout subtracts back.
    let reserve = columnInkWrapGuard + 2 * padding.horizontal
    return zip(mins, maxs).map { ColumnIntrinsics(min: $0 + reserve, max: $1 + reserve) }
}

/// Composition of `measureColumnIntrinsics` + `solveColumnWidths(intrinsics:availableWidth:)` —
/// the table model + available width in, final per-column widths + overflow flag out.
public nonisolated func solveColumnWidths(
    cells: [[TextDescriptor]],
    availableWidth: CGFloat,
    measure: TextMeasure,
    padding: TableCellPadding = .default
) -> ColumnWidthSolution {
    solveColumnWidths(
        intrinsics: measureColumnIntrinsics(cells: cells, measure: measure, padding: padding),
        availableWidth: availableWidth
    )
}

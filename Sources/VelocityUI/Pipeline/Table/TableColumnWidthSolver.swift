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
/// opportunity, so its own natural width is the floor below which it would clip.
///
/// `measure` is injected exactly like `TextMeasure` in FreezeState.swift, so this stays
/// pure/nonisolated and UIKit-free — same sibling pattern as `freeze(_:)`.
public nonisolated func measureColumnIntrinsics(
    cells: [[TextDescriptor]],
    measure: TextMeasure
) -> [ColumnIntrinsics] {
    guard let columnCount = cells.first?.count else { return [] }

    var mins = [CGFloat](repeating: 0, count: columnCount)
    var maxs = [CGFloat](repeating: 0, count: columnCount)

    for row in cells {
        for (columnIndex, descriptor) in row.enumerated() where columnIndex < columnCount {
            let naturalWidth = measure(descriptor, .greatestFiniteMagnitude).width
            maxs[columnIndex] = max(maxs[columnIndex], naturalWidth)

            let widestToken = descriptor.content
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
            mins[columnIndex] = max(mins[columnIndex], widestToken)
        }
    }

    return zip(mins, maxs).map { ColumnIntrinsics(min: $0, max: $1) }
}

/// Composition of `measureColumnIntrinsics` + `solveColumnWidths(intrinsics:availableWidth:)` —
/// the table model + available width in, final per-column widths + overflow flag out.
public nonisolated func solveColumnWidths(
    cells: [[TextDescriptor]],
    availableWidth: CGFloat,
    measure: TextMeasure
) -> ColumnWidthSolution {
    solveColumnWidths(
        intrinsics: measureColumnIntrinsics(cells: cells, measure: measure),
        availableWidth: availableWidth
    )
}

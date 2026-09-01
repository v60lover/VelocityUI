// MarkdownOracle.swift

import Foundation
import Markdown
@testable import VelocityUI

/// A GFM table projected down to the dimensions both parsers can agree on: header/body cell
/// text and per-column alignment. Neither parser's native representation is compared directly —
/// `IncrementalMarkdownParser` emits raw pipe-delimited text, swift-markdown emits a `Markup`
/// tree — so both sides funnel through this shared shape.
struct RawTableShape: Equatable {
    var alignments: [String?]
    var headerCells: [String]
    var bodyRows: [[String]]
}

/// Projects our parser's raw table block text (header line, delimiter line, body lines joined
/// by "\n" — see `IncrementalMarkdownParser.swift`'s `.table(alignments:)` join) into a
/// `RawTableShape`. Trims each cell: our raw split keeps surrounding whitespace that cmark's
/// cell model never carries, so trimming is the normalization step that makes the two sides
/// comparable.
func ourTableShape(fromRawBlockText text: String) -> RawTableShape? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 2 else { return nil }

    func cells(_ line: Substring) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func alignment(_ cell: String) -> String? {
        let c = cell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        if left && right { return "center" }
        if right { return "right" }
        if left { return "left" }
        return nil
    }

    let headerCells = cells(lines[0])
    let alignments = cells(lines[1]).map(alignment)
    let bodyRows = lines.dropFirst(2).map(cells)
    return RawTableShape(alignments: alignments, headerCells: headerCells, bodyRows: Array(bodyRows))
}

/// Collects the first top-level `Table` swift-markdown finds while walking `Document(parsing:)`.
/// A test corpus with more than one table is out of scope for this oracle — see the bead design.
private struct FirstTableWalker: MarkupWalker {
    var table: Table?

    mutating func visitTable(_ table: Table) {
        if self.table == nil {
            self.table = table
        }
    }
}

/// Projects cmark's `Table` node into the same `RawTableShape` `ourTableShape` produces, using
/// `Table.ColumnAlignment` and each cell's `plainText` (strips inline markup back to plain
/// characters, matching how our raw parser has no inline structure to strip in the first place).
func oracleTableShape(source: String) -> RawTableShape? {
    let document = Document(parsing: source)
    var walker = FirstTableWalker()
    walker.visit(document)
    guard let table = walker.table else { return nil }

    let headerCells = Array(table.head.cells.map { $0.plainText })
    let bodyRows = Array(table.body.rows.map { row in Array(row.cells.map { $0.plainText }) })
    let alignments: [String?] = table.columnAlignments.map { alignment in
        switch alignment {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        case nil: return nil
        }
    }
    return RawTableShape(alignments: alignments, headerCells: headerCells, bodyRows: bodyRows)
}

/// Runs `source` through both `IncrementalMarkdownParser` (full, non-streaming — append once,
/// read the sealed+hot table block) and swift-markdown, and structurally compares the resulting
/// `RawTableShape`s. Returns a diff description on mismatch instead of asserting inline, so
/// callers decide whether a mismatch is a test failure (well-formed corpus) or the expected,
/// asserted-for outcome (a corpus entry chosen to expose a known gap).
func compareTable(source: String) -> (matches: Bool, diff: String?) {
    var parser = IncrementalMarkdownParser()
    parser.append(source)
    let combined = parser.sealedBlocks + parser.hotBlocksState
    guard let tableBlock = combined.first(where: {
        if case .table = $0.kind { return true }
        return false
    }) else {
        return (false, "our parser produced no .table block for source: \(source)")
    }
    guard let ours = ourTableShape(fromRawBlockText: tableBlock.text) else {
        return (false, "could not project our raw table block text into a RawTableShape: \(tableBlock.text)")
    }
    guard let theirs = oracleTableShape(source: source) else {
        return (false, "swift-markdown produced no Table for source: \(source)")
    }
    if ours == theirs {
        return (true, nil)
    }
    return (false, "ours: \(ours)\ntheirs: \(theirs)")
}

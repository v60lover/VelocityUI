// StreamFixtures.swift

import Foundation

/// Deterministic token streams for the streaming cost baseline (VelocityUI-ln1g.1). Each fixture
/// stresses one shape: many small blocks, or one very large block.
struct StreamFixture: Sendable, Equatable {
    let name: String
    let tokens: [String]
    /// Index into `tokens` of the last token of each table row. Empty for non-table fixtures.
    /// Lets a run warm up N rows and measure only the rows after them ("500+1").
    let rowEndTokenIndices: [Int]

    enum TableWidths: Sendable {
        /// Every row fits the widths set by the header and first rows.
        case stable
        /// A wider value appears every `growEvery` rows, so solved column widths keep changing.
        case changing(growEvery: Int)
    }

    /// Streams a GFM table one cell at a time.
    static func table(rows: Int, widths: TableWidths) -> StreamFixture {
        var tokens = ["| Name ", "| Status ", "| Latency |\n", "| --- ", "| --- ", "| --- |\n"]
        var rowEnds: [Int] = []
        for row in 0..<rows {
            tokens.append("| " + String(format: "row-%04d", row) + " ")
            tokens.append("| " + (row % 3 == 0 ? "ok" : "retry") + " ")
            tokens.append("| " + latency(row: row, widths: widths) + " |\n")
            rowEnds.append(tokens.count - 1)
        }
        tokens.append("\n")
        let label: String
        switch widths {
        case .stable: label = "table-\(rows)-stable"
        case .changing(let every): label = "table-\(rows)-changing-\(every)"
        }
        return StreamFixture(name: label, tokens: tokens, rowEndTokenIndices: rowEnds)
    }

    /// One paragraph with no blank line, streamed word by word, so it stays a single open block.
    static func longParagraph(words: Int) -> StreamFixture {
        var tokens: [String] = []
        for i in 0..<words {
            tokens.append(Self.vocabulary[i % Self.vocabulary.count] + (i == words - 1 ? "\n\n" : " "))
        }
        return StreamFixture(name: "paragraph-\(words)w", tokens: tokens, rowEndTokenIndices: [])
    }

    /// One fenced code block, streamed line by line, that stays open until the last line.
    static func longCode(lines: Int) -> StreamFixture {
        var tokens = ["```swift\n"]
        for i in 0..<lines {
            tokens.append("let value\(i) = compute(\(i), scale: \(i % 7)) // step \(i)\n")
        }
        tokens.append("```\n\n")
        return StreamFixture(name: "code-\(lines)l", tokens: tokens, rowEndTokenIndices: [])
    }

    /// Many short assistant turns, each a couple of sealed blocks. One chunk list per turn.
    static func manyMessages(count: Int) -> [[String]] {
        (0..<count).map { i in
            ["Answer \(i): ", "short reply ", "with a few words.\n\n", "- item a\n", "- item b\n\n"]
        }
    }

    private static func latency(row: Int, widths: TableWidths) -> String {
        let base = String(format: "%d.%d ms", 10 + row % 90, row % 10)
        guard case .changing(let every) = widths, every > 0, row > 0, row % every == 0 else { return base }
        return base + " (retried " + String(repeating: "x", count: row / every * 4) + ")"
    }

    private static let vocabulary = [
        "streaming", "answers", "grow", "one", "token", "at", "a", "time", "and", "the", "layout",
        "must", "stay", "cheap", "even", "when", "a", "single", "block", "covers", "many", "screens",
    ]
}

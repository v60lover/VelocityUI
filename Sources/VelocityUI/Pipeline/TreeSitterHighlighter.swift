// TreeSitterHighlighter.swift

import Foundation
import SwiftTreeSitter

/// tree-sitter-backed `SyntaxHighlighter` (VelocityUI-wmss.4 decision, wmss.4.1 device-proven).
///
/// Parses the whole block from scratch on every call and stays pure — no `Tree` held between
/// calls, no cache. That's what gives cross-line context (triple-quoted strings, block comments)
/// for free, since a full parse sees the whole block at once. The incremental `InputEdit`
/// tree-reuse optimization is VelocityUI-oz5q.7's job, layered on top without touching this
/// contract.
public struct TreeSitterHighlighter: SyntaxHighlighter {
    public init() {}

    public func colorRuns(for lines: ArraySlice<String>, grammar: CompiledGrammar, theme: Theme) -> [LineColorRuns] {
        let lineArray = Array(lines)
        guard !lineArray.isEmpty else { return [] }
        guard let language = grammar.language, let query = grammar.highlightsQuery else {
            return Array(repeating: LineColorRuns(runs: []), count: lineArray.count)
        }

        let parser = Parser()
        do {
            try parser.setLanguage(language)
        } catch {
            return Array(repeating: LineColorRuns(runs: []), count: lineArray.count)
        }

        let joined = lineArray.joined(separator: "\n")
        guard let tree = parser.parse(joined) else {
            return Array(repeating: LineColorRuns(runs: []), count: lineArray.count)
        }

        let lineStarts = Self.utf16LineStarts(lineArray)
        let lineLengths = lineArray.map { $0.utf16.count }
        var perLine = [[ColorRun]](repeating: [], count: lineArray.count)

        for match in query.execute(in: tree) {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                let tokenType = Self.tokenType(forCaptureName: name)
                let color = theme.color(for: tokenType)
                for (lineIndex, localRange) in Self.split(
                    capture.node.range,
                    lineStarts: lineStarts,
                    lineLengths: lineLengths
                ) {
                    perLine[lineIndex].append(ColorRun(range: localRange, tokenType: tokenType, color: color))
                }
            }
        }
        return perLine.map { LineColorRuns(runs: $0) }
    }

    // MARK: - Capture-name -> TokenType

    /// Prefix mapping, per VelocityUI-oz5q.3's design: `string*` -> `.string`, `number*` ->
    /// `.number`, `keyword*` -> `.keyword` (covers `keyword.function`, `keyword.type`, etc. —
    /// every grammar's keyword captures use a `keyword` or `keyword.*` name), `comment*` ->
    /// `.comment`, `type*` -> `.type`, `function*` -> `.function`. `constant.builtin` (boolean/
    /// nil/null literals) maps to `.number` — closest existing category for a literal constant,
    /// since `TokenType` has no dedicated case for it. Anything else -> `.plain`.
    static func tokenType(forCaptureName name: String) -> TokenType {
        if name == "constant.builtin" { return .number }
        if name.hasPrefix("string") { return .string }
        if name.hasPrefix("number") { return .number }
        if name.hasPrefix("keyword") { return .keyword }
        if name.hasPrefix("comment") { return .comment }
        if name.hasPrefix("type") { return .type }
        if name.hasPrefix("function") { return .function }
        return .plain
    }

    // MARK: - Global UTF-16 range -> per-line local ranges

    private static func utf16LineStarts(_ lines: [String]) -> [Int] {
        var starts = [Int]()
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1  // +1 for the "\n" the lines were joined with.
        }
        return starts
    }

    /// Clips a capture's global `NSRange` (UTF-16 offsets into the joined block) against each
    /// line's span, so a token spanning a line break (a triple-quoted string, a block comment)
    /// produces one run per line instead of one run with an out-of-bounds range.
    private static func split(
        _ globalRange: NSRange,
        lineStarts: [Int],
        lineLengths: [Int]
    ) -> [(Int, Range<Int>)] {
        var result: [(Int, Range<Int>)] = []
        let globalLower = globalRange.location
        let globalUpper = globalRange.location + globalRange.length
        for i in lineStarts.indices {
            let lineStart = lineStarts[i]
            if lineStart >= globalUpper { break }
            let lineEnd = lineStart + lineLengths[i]
            let lo = max(globalLower, lineStart)
            let hi = min(globalUpper, lineEnd)
            if lo < hi {
                result.append((i, (lo - lineStart)..<(hi - lineStart)))
            }
        }
        return result
    }
}

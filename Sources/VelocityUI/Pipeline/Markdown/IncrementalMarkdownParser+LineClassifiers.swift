// IncrementalMarkdownParser+LineClassifiers.swift

import Foundation

extension IncrementalMarkdownParser {

    // MARK: - Shared line classifiers
    //
    // Used by both the resumable scanner in `IncrementalMarkdownParser+HotScan.swift` and the
    // full-rescan oracle in `IncrementalMarkdownParser+TestHooks.swift` — one classification
    // path, so they can't drift from each other.

    static func isBlankLine(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }
    static func leadingSpaceCount(_ line: Substring) -> Int {
        line.prefix { $0 == " " }.count
    }
    static func fenceOpenMarker(_ line: Substring) -> (marker: Substring, language: String?)? {
        let trimmed = line.drop { $0 == " " }
        let marker: Substring
        if trimmed.hasPrefix("```") {
            marker = trimmed.prefix { $0 == "`" }
        } else if trimmed.hasPrefix("~~~") {
            marker = trimmed.prefix { $0 == "~" }
        } else {
            return nil
        }
        let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        let language = info.split(separator: " ").first.map(String.init)
        return (marker, language)
    }
    // `$$` / `\[` only opens block math at the start of a line (after optional leading
    // spaces) — mid-paragraph occurrences stay literal, tokenized inline instead (see
    // `inlineRuns`). `rest` is everything on the line after the opening marker, used to
    // detect a same-line close (a one-line block).
    static func mathBlockOpenMarker(_ line: Substring) -> (closeMarker: String, rest: Substring)? {
        let trimmed = line.drop { $0 == " " }
        if trimmed.hasPrefix("$$") {
            return ("$$", trimmed.dropFirst(2))
        }
        if trimmed.hasPrefix("\\[") {
            return ("\\]", trimmed.dropFirst(2))
        }
        return nil
    }
    static func isFenceCloseShapedLine(_ line: Substring, opening: Substring) -> Bool {
        guard let openChar = opening.first else { return false }
        var trimmed = line.drop { $0 == " " }
        var count = 0
        while let first = trimmed.first, first == openChar {
            trimmed = trimmed.dropFirst()
            count += 1
        }
        guard count >= opening.count else { return false }
        return trimmed.allSatisfy { $0 == " " || $0 == "\t" }
    }
    static func listMarkerInfo(_ line: Substring) -> (ordered: Bool, number: Int, depth: Int, checked: Bool?)? {
        let spaces = leadingSpaceCount(line)
        guard spaces <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard let first = rest.first else { return nil }
        let depth = spaces / 2
        if "-*+".contains(first) {
            let after = rest.index(after: rest.startIndex)
            guard after < rest.endIndex, rest[after] == " " else { return nil }
            let content = rest[rest.index(after: after)...].drop { $0 == " " }
            return (ordered: false, number: 0, depth: depth, checked: Self.taskMarkerChecked(content))
        }
        var idx = rest.startIndex
        var digits = 0
        while idx < rest.endIndex, rest[idx].isNumber {
            idx = rest.index(after: idx)
            digits += 1
        }
        guard digits > 0, idx < rest.endIndex, rest[idx] == "." || rest[idx] == ")" else { return nil }
        let after = rest.index(after: idx)
        guard after < rest.endIndex, rest[after] == " " else { return nil }
        let number = Int(rest[rest.startIndex..<idx]) ?? 1
        let content = rest[rest.index(after: after)...].drop { $0 == " " }
        return (ordered: true, number: number, depth: depth, checked: Self.taskMarkerChecked(content))
    }
    static func isListMarkerLine(_ line: Substring) -> Bool {
        listMarkerInfo(line) != nil
    }
    static func atxHeading(_ line: Substring) -> (level: Int, content: String)? {
        guard leadingSpaceCount(line) == 0, line.first == "#" else { return nil }
        var rest = line
        var level = 0
        while rest.first == "#" {
            rest = rest.dropFirst()
            level += 1
            if level > 6 { return nil }
        }
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.drop { $0 == " " }
        while let last = text.last, last == " " || last == "\t" {
            text = text.dropLast()
        }
        // Optional CommonMark closing sequence: a trailing run of '#' preceded by
        // whitespace (or nothing but the run itself) is stripped too.
        var probe = text
        var trailingHashes = 0
        while probe.last == "#" {
            probe = probe.dropLast()
            trailingHashes += 1
        }
        if trailingHashes > 0, probe.isEmpty || probe.last == " " || probe.last == "\t" {
            text = probe
            while let last = text.last, last == " " || last == "\t" {
                text = text.dropLast()
            }
        }
        return (level, String(text))
    }
    // Recognizes a line that consists of exactly `![alt](url)`, alone — same strictness
    // as `atxHeading`/`isThematicBreakLine` (leading spaces == 0). Alt text is only used to
    // find the closing `]`; the URL substring is everything between the matching `(` and
    // the line's final `)`, so a URL containing its own parentheses still round-trips.
    // Returns nil while the line is still streaming (no closing `)` yet, or malformed),
    // so a not-yet-complete image line degrades to ordinary paragraph text meanwhile
    // instead of misparsing.
    static func imageLineURL(_ line: Substring) -> URL? {
        guard leadingSpaceCount(line) == 0 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"), trimmed.count > 3 else { return nil }
        let body = trimmed.dropFirst(2).dropLast()
        guard let closeBracket = body.firstIndex(of: "]") else { return nil }
        let afterBracket = body.index(after: closeBracket)
        guard afterBracket < body.endIndex, body[afterBracket] == "(" else { return nil }
        let urlString = String(body[body.index(after: afterBracket)...])
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        return url
    }
    static func isThematicBreakLine(_ line: Substring) -> Bool {
        guard leadingSpaceCount(line) == 0 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first) else { return false }
        return trimmed.allSatisfy { $0 == first }
    }
    static func isBlockquoteMarkerLine(_ line: Substring) -> Bool {
        guard leadingSpaceCount(line) <= 3 else { return false }
        return line.drop { $0 == " " }.first == ">"
    }
    // Validates a delimiter row AND parses its per-column alignment in the same pass —
    // one source of truth for "is this a delimiter row" and "what does it say", so the
    // promotion check and the alignment it commits to a `.table` block can never disagree.
    static func tableDelimiterRowAlignments(_ line: Substring) -> [TableColumnAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let cells = t.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return nil }
        var alignments: [TableColumnAlignment] = []
        alignments.reserveCapacity(cells.count)
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.contains("-") else { return nil }
            for ch in c where ch != "-" && ch != ":" { return nil }
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }
    static func setextUnderlineLevel(_ line: Substring) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Builds one `ParsedMDBlock` from an open/closing run of lines — the single construction
    /// site `finalizeOpenBlock()` and the tail's trailing hot block both call, so they can't
    /// drift on how `.table` blocks get their `tableRows` populated.
    static func makeParsedBlock(kind: MarkdownBlockKind, lines: [Substring]) -> ParsedMDBlock {
        let text = lines.map(String.init).joined(separator: "\n")
        var block = ParsedMDBlock(kind: kind, text: text, runs: Self.tokenizableRuns(for: kind, text: text))
        if case .table(let alignments) = kind {
            block.tableRows = Self.parseTableRows(lines: lines, columnCount: alignments.count)
        }
        return block
    }

    /// Builds `[[TableCell]]` from a `.table` block's raw lines: `lines[0]` is the header,
    /// `lines[1]` is the delimiter row (skipped — it carries alignment, not cell content),
    /// `lines[2...]` are body rows. Every row is split and tokenized through the same
    /// `splitTableRowCells`/`inlineRuns` path so header and body cells can't disagree on shape.
    private static func parseTableRows(lines: [Substring], columnCount: Int) -> [[TableCell]] {
        guard columnCount > 0, lines.count >= 2 else { return [] }
        var rows: [[TableCell]] = []
        rows.reserveCapacity(lines.count - 1)
        for (index, line) in lines.enumerated() where index != 1 {
            let cells = Self.splitTableRowCells(line, columnCount: columnCount)
            rows.append(cells.map { TableCell(text: $0, runs: inlineRuns($0)) })
        }
        return rows
    }

    /// Splits one raw table row line into cells per GFM rules: a leading/trailing `|` is
    /// optional and stripped, `\|` is a literal pipe (never a column separator), and the
    /// result is padded with empty cells or truncated to `columnCount` — ragged rows are
    /// legal GFM (short rows padded, long rows truncated to the header's column count).
    static func splitTableRowCells(_ line: Substring, columnCount: Int) -> [String] {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "|" { trimmed = trimmed.dropFirst() }
        if let last = trimmed.last, last == "|" {
            let beforeLast = trimmed.index(before: trimmed.endIndex)
            let isEscaped = beforeLast > trimmed.startIndex && trimmed[trimmed.index(before: beforeLast)] == "\\"
            if !isEscaped { trimmed = trimmed.dropLast() }
        }

        var cells: [String] = []
        var current = ""
        var chars = trimmed
        while let ch = chars.first {
            if ch == "\\", chars.dropFirst().first == "|" {
                current.append("|")
                chars = chars.dropFirst(2)
                continue
            }
            if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                chars = chars.dropFirst()
                continue
            }
            current.append(ch)
            chars = chars.dropFirst()
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if cells.count < columnCount {
            cells.append(contentsOf: repeatElement("", count: columnCount - cells.count))
        } else if cells.count > columnCount {
            cells = Array(cells.prefix(columnCount))
        }
        return cells
    }
}

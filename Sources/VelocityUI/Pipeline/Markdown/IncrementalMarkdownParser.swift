// IncrementalMarkdownParser.swift

import Foundation
import CoreGraphics

// MARK: - MarkdownBlockKind

/// Per-column GFM table alignment, parsed from the delimiter row's leading/trailing `:`
/// (`:---` left, `:--:` center, `---:` right, `---` no alignment specified).
public enum TableColumnAlignment: Sendable, Equatable, Hashable {
    case left, center, right, none
}

/// The markdown block shapes this parser recognizes. Drives which `TextDescriptor` style
/// `IncrementalMarkdownParser.blocks(itemID:width:)` picks — there is no dedicated
/// `FragmentContent` case per kind; everything renders as styled text (`Block` only wraps
/// `.text`/`.image`/`.geometry` — see `Block.swift`).
public enum MarkdownBlockKind: Sendable, Equatable, Hashable {
    case paragraph
    case heading(level: Int)
    case codeFence(language: String?)
    /// `number` is the literal digit run the source used (e.g. `3.` -> 3), meaningless when
    /// `ordered` is false. `depth` is the nesting level inferred from leading indentation.
    case listItem(ordered: Bool, number: Int, depth: Int)
    case blockquote
    /// A GFM table, grouped into ONE block from a header row + delimiter row + zero or more
    /// body rows. `alignments` (one per column, from the delimiter row) lives here because
    /// render styling switches on it independent of cell text; the actual grid — header row
    /// plus body rows, each cell tokenized via `inlineRuns(_:)` — lives in
    /// `ParsedMDBlock.tableRows`, not in this case.
    case table(alignments: [TableColumnAlignment])
    /// A `---`/`***`/`___` rule line.
    case thematicBreak
    /// Block LaTeX math (`$$...$$` or `\[...\]`), parallel to `.codeFence`. `text` (via
    /// `style()`) holds the raw TeX with delimiter lines stripped, same convention as
    /// `.codeFence` stripping its fence markers.
    case mathBlock
}

/// A styled span within a text block's content, produced by `inlineRuns(_:)`. `url` is only
/// meaningful when `style` contains `.link`.
struct InlineRun: Equatable, Sendable {
    var text: String
    var style: StyleFlags
    var url: String?
    /// Raw TeX source when this run is inline math (`$...$` / `\(...\)`); nil otherwise. A
    /// dedicated field rather than a `StyleFlags` bit, because the payload is data (the TeX
    /// string), not a style toggle. `text` also carries the same raw TeX so a caller that
    /// doesn't branch on `mathSource` (everything before the inline-math renderer lands) still
    /// shows literal text instead of nothing.
    var mathSource: String? = nil
}

/// Inline markdown emphasis a run can carry, independent of the block-level `MarkdownBlockKind`.
/// Mirrors `VFontTraits`'s OptionSet shape (NodeTable.swift).
struct StyleFlags: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let bold = StyleFlags(rawValue: 1 << 0)
    static let italic = StyleFlags(rawValue: 1 << 1)
    static let code = StyleFlags(rawValue: 1 << 2)
    static let strike = StyleFlags(rawValue: 1 << 3)
    static let link = StyleFlags(rawValue: 1 << 4)
}

/// Tokenizes one text block's content into styled spans. Pure and deterministic: toggles a
/// `StyleFlags` accumulator on delimiter runs, treats code spans as literal, and recurses into
/// `[text](url)` bodies for their own emphasis. Unclosed/malformed syntax degrades to literal
/// text instead of mis-nesting.
nonisolated func inlineRuns(_ text: String) -> [InlineRun] {
    var runs: [InlineRun] = []
    var buffer = ""
    var flags: StyleFlags = []

    func flush() {
        guard !buffer.isEmpty else { return }
        runs.append(InlineRun(text: buffer, style: flags, url: nil))
        buffer = ""
    }

    var chars = Substring(text)
    while !chars.isEmpty {
        if chars.hasPrefix("***") || chars.hasPrefix("___") {
            flush()
            flags.formSymmetricDifference([.bold, .italic])
            chars = chars.dropFirst(3)
            continue
        }
        if chars.hasPrefix("**") || chars.hasPrefix("__") {
            flush()
            flags.formSymmetricDifference(.bold)
            chars = chars.dropFirst(2)
            continue
        }
        if chars.hasPrefix("~~") {
            flush()
            flags.formSymmetricDifference(.strike)
            chars = chars.dropFirst(2)
            continue
        }
        if chars.hasPrefix("\\$") {
            // Escaped dollar is a literal '$', never a math delimiter.
            buffer.append("$")
            chars = chars.dropFirst(2)
            continue
        }
        if chars.hasPrefix("\\(") {
            let afterOpen = chars.dropFirst(2)
            if let closeRange = afterOpen.range(of: "\\)") {
                flush()
                let tex = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                runs.append(InlineRun(text: tex, style: flags, url: nil, mathSource: tex))
                chars = afterOpen[closeRange.upperBound...]
                continue
            }
            // No matching close yet — still streaming. Render the marker literally, same
            // discipline as an unclosed code span: no raw-TeX flash, no misparse.
            buffer.append(contentsOf: chars.prefix(2))
            chars = chars.dropFirst(2)
            continue
        }
        if chars.first == "$" {
            if chars.dropFirst().first == "$" {
                // "$$" mid-paragraph is neither the block form (only recognized at line-start
                // in parseTail) nor valid inline syntax — emit one literal '$' rather than guess.
                buffer.append("$")
                chars = chars.dropFirst()
                continue
            }
            let afterOpen = chars.dropFirst()
            // Pandoc's tex_math_dollars heuristic: the char right after the opening '$' and the
            // char right before the closing '$' must both be non-space. Without this, "$5 and
            // $10" (two literal prices) would misparse as one formula spanning "5 and ".
            if let openNext = afterOpen.first, openNext != " ", openNext != "\n" {
                var idx = afterOpen.startIndex
                var prevChar = openNext
                var closeIndex: Substring.Index?
                while idx < afterOpen.endIndex {
                    let c = afterOpen[idx]
                    if c == "$", prevChar != " " {
                        closeIndex = idx
                        break
                    }
                    prevChar = c
                    idx = afterOpen.index(after: idx)
                }
                if let closeIndex {
                    flush()
                    let tex = String(afterOpen[afterOpen.startIndex..<closeIndex])
                    runs.append(InlineRun(text: tex, style: flags, url: nil, mathSource: tex))
                    chars = afterOpen[afterOpen.index(after: closeIndex)...]
                    continue
                }
            }
            // Unclosed, or rejected by the guard above — literal dollar, no misparse.
            buffer.append("$")
            chars = chars.dropFirst()
            continue
        }
        if let first = chars.first, first == "*" || first == "_" {
            // A lone marker with nothing after it yet might still widen into "**"/"__" on the
            // next append. Drop it as a pending marker instead of toggling italic, so a trailing
            // '*' never commits to italic before we know whether its partner is coming.
            if chars.dropFirst().isEmpty {
                chars = chars.dropFirst()
                continue
            }
            flush()
            flags.formSymmetricDifference(.italic)
            chars = chars.dropFirst(1)
            continue
        }
        if chars.first == "`" {
            let markerLen = chars.prefix { $0 == "`" }.count
            let marker = String(repeating: "`", count: markerLen)
            let afterOpen = chars.dropFirst(markerLen)
            if let closeRange = afterOpen.range(of: marker) {
                flush()
                let code = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                runs.append(InlineRun(text: code, style: flags.union(.code), url: nil))
                chars = afterOpen[closeRange.upperBound...]
                continue
            }
            // No matching close yet — still streaming. Treat the marker literally.
            buffer.append(contentsOf: chars.prefix(markerLen))
            chars = chars.dropFirst(markerLen)
            continue
        }
        if chars.first == "[" {
            if let closeBracket = chars.dropFirst().firstIndex(of: "]") {
                let afterBracket = chars.index(after: closeBracket)
                if afterBracket < chars.endIndex, chars[afterBracket] == "(",
                   let closeParen = chars[afterBracket...].firstIndex(of: ")") {
                    let linkText = String(chars[chars.index(after: chars.startIndex)..<closeBracket])
                    let linkURL = String(chars[chars.index(after: afterBracket)..<closeParen])
                    flush()
                    let innerRuns = inlineRuns(linkText)
                    if innerRuns.isEmpty {
                        runs.append(InlineRun(text: "", style: flags.union(.link), url: linkURL))
                    } else {
                        for inner in innerRuns {
                            runs.append(InlineRun(text: inner.text, style: flags.union(inner.style).union(.link), url: linkURL, mathSource: inner.mathSource))
                        }
                    }
                    chars = chars[chars.index(after: closeParen)...]
                    continue
                }
            }
            buffer.append("[")
            chars = chars.dropFirst()
            continue
        }
        buffer.append(chars.first!)
        chars = chars.dropFirst()
    }
    flush()
    return runs
}

/// One cell of a `.table` block: its raw text plus tokenized inline emphasis spans
/// (`inlineRuns(_:)`), so table rendering never has to re-tokenize per cell.
struct TableCell: Equatable {
    var text: String
    var runs: [InlineRun]
}

/// One markdown block the incremental parser has classified: a kind plus its raw source text
/// (lines joined by `\n`, marker/underline syntax stripped where it isn't part of the rendered
/// content — e.g. a setext `===` underline or a table delimiter row) plus its tokenized inline
/// spans (empty for kinds that don't render as free-form styled text).
struct ParsedMDBlock: Equatable {
    var kind: MarkdownBlockKind
    var text: String
    var runs: [InlineRun] = []
    /// Populated only when `kind` is `.table`: `tableRows[0]` is the header row, `tableRows[1...]`
    /// are body rows, each cell already tokenized. Empty for every other kind.
    var tableRows: [[TableCell]] = []
}

// MARK: - IncrementalMarkdownParser

/// Consumes an appended markdown stream and splits it into two tiers at a monotonically
/// non-decreasing frontier `F`: **sealed** blocks (`source[0..<F)`), guaranteed never to
/// change and safe to `freeze()`, and **hot** blocks (the open tail), which may still be
/// retyped. A deliberately simplified CommonMark subset (heuristic list/blockquote
/// continuation, no fence nesting), not full compliance.
public struct IncrementalMarkdownParser: Sendable, Equatable {

    /// Finalized, immutable blocks — never touched again once appended here.
    private(set) var sealedBlocks: [ParsedMDBlock] = []
    private(set) var sealedBlockIDs: [BlockID] = []

    /// Unsealed tail of the source since the last seal — re-scanned in full on every
    /// `append(_:)` (bounded except during an open fence), never the whole message.
    private var hotTail: String = ""

    /// The hot region's current parse, kept alongside `hotTail` so `blocks(itemID:width:)`
    /// doesn't need to re-run the scanner.
    private(set) var hotBlocksState: [ParsedMDBlock] = []
    private(set) var hotBlockIDs: [BlockID] = []
    private var nextBlockID = 0

    public init() {}

    /// Sealed-block count — the frontier `F` passed to `diff(previous:new:frontier:)`.
    /// Monotonically non-decreasing: `sealedBlocks` is only ever appended to.
    public var frontier: Int { sealedBlocks.count }

    /// Appends `text` to the accumulated stream and re-parses the hot tail. Any block that
    /// becomes provably sealed (per `Self.parseTail`'s contract) is moved into `sealedBlocks`
    /// permanently; everything still open stays in the hot tier.
    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        hotTail += text
        let result = Self.parseTail(hotTail)
        let sealedIDs = reconciledIDs(existing: hotBlockIDs, count: result.sealed.count)
        if !result.sealed.isEmpty {
            sealedBlocks.append(contentsOf: result.sealed)
            sealedBlockIDs.append(contentsOf: sealedIDs)
            hotTail = String(hotTail[result.cutIndex...])
        }
        hotBlocksState = result.hot
        hotBlockIDs = reconciledIDs(
            existing: Array(hotBlockIDs.dropFirst(result.sealed.count)), count: result.hot.count
        )
    }

    /// Builds the `[Block]` list a caller feeds into `diff(previous:new:frontier:)` —
    /// `sealed + hot`, with `Block.key.index` matching each block's position in that combined
    /// list (so `BlockKey`'s positional identity lines up with `frontier`).
    public func blockList<ID: Hashable & Sendable>(
        itemID: ID, width: CGFloat, theme: MarkdownTheme = .default
    ) -> [Block] {
        var blocks: [Block] = []
        blocks.reserveCapacity(sealedBlocks.count + hotBlocksState.count)
        let combined = sealedBlocks + hotBlocksState
        let lastIndex = combined.count - 1
        for (index, pair) in zip(combined, sealedBlockIDs + hotBlockIDs).enumerated() {
            let lifecycle: BlockLifecycle = index < sealedBlocks.count ? .sealed : .hot
            // Only the still-open trailing block can retroactively promote paragraph -> table
            // (see parseTail's paragraph->table join). Any earlier single-line "|" paragraph
            // was already finalized as a plain paragraph by something else arriving after it, so
            // it is not ambiguous and must render its pipes literally.
            let isPendingTableHeader = index == lastIndex && lifecycle == .hot && Self.isPendingTableCandidate(pair.0)
            blocks.append(Self.makeBlock(pair.0, itemID: itemID, index: index, blockID: pair.1, width: width, lifecycle: lifecycle, theme: theme, isPendingTableHeader: isPendingTableHeader))
        }
        return blocks
    }

    /// True for a hot, one-line, unfinalized paragraph whose only line contains `|` — the window
    /// where `parseTail` cannot yet tell whether the next line will be a table delimiter row
    /// (-> promote to `.table`) or ordinary text (-> stays `.paragraph`, pipes literal).
    /// Painting this line's raw pipes would flash `|a|b|` for one or more frames before the
    /// table lays out; see VelocityUI-wmss.3.
    static func isPendingTableCandidate(_ parsed: ParsedMDBlock) -> Bool {
        guard case .paragraph = parsed.kind else { return false }
        return parsed.text.contains("|") && !parsed.text.contains("\n")
    }

    // MARK: - Block construction

    private static func makeBlock<ID: Hashable & Sendable>(
        _ parsed: ParsedMDBlock, itemID: ID, index: Int, blockID: BlockID, width: CGFloat,
        lifecycle: BlockLifecycle, theme: MarkdownTheme, isPendingTableHeader: Bool = false
    ) -> Block {
        let descriptor = makeDescriptor(parsed, theme: theme, isPendingTableHeader: isPendingTableHeader)
        let frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let fragment = Fragment(id: index, blockID: blockID, content: .text(descriptor), frame: frame)
        return Block(
            key: BlockKey(itemID: itemID, blockID: blockID),
            fragment: fragment,
            layout: ResolvedLayout(totalFrame: frame),
            lifecycle: lifecycle
        )
    }

    private mutating func reconciledIDs(existing: [BlockID], count: Int) -> [BlockID] {
        var ids = Array(existing.prefix(count))
        while ids.count < count {
            ids.append(BlockID(nextBlockID))
            nextBlockID += 1
        }
        return ids
    }

    /// A block's rendered text plus its font — shared by `makeDescriptor` and `renderNodes`
    /// so the two representations can't silently diverge. Color/line-break are each
    /// caller's own separate default. `runs` is empty for kinds `tokenizableRuns` never
    /// tokenizes (codeFence/table/thematicBreak) or when `parsed.runs` itself is empty —
    /// both `makeDescriptor` and `renderNodes` pass it straight through to their respective
    /// `TextDescriptor`/`TextNode`.
    struct StyledText {
        var content: String
        var font: VFontDescriptor
        var runs: [TextRun] = []
    }

    /// `isPendingTableHeader` is true only for the still-open trailing paragraph whose single
    /// line contains `|` with no `\n` yet — see `isPendingTableCandidate`. Rendered as empty
    /// text rather than the raw pipe source, so a header row never flashes literal `|`
    /// characters before the delimiter row confirms (or denies) the table.
    static func style(_ parsed: ParsedMDBlock, theme: MarkdownTheme = .default, isPendingTableHeader: Bool = false) -> StyledText {
        if isPendingTableHeader {
            return StyledText(content: "", font: theme.body, runs: [])
        }
        let font: VFontDescriptor
        var content = parsed.text
        var prefix = ""
        switch parsed.kind {
        case .heading(let level):
            font = theme.heading(level: level)
        case .codeFence:
            font = theme.code
            // Strip the fence marker lines. The opening line always exists; only drop the
            // closing line when it's actually shaped like one — otherwise a still-streaming
            // fence would hide its most recently typed line.
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty {
                lines.removeFirst()
            }
            if let last = lines.last, Self.isFenceCloseShaped(last) {
                lines.removeLast()
            }
            content = lines.joined(separator: "\n")
        case .table:
            font = theme.body
        case .mathBlock:
            font = theme.code
            // Strip the `$$`/`\[...\]` delimiters the same way codeFence strips its fence
            // markers — until gojy.3's rasterizer lands, this is what StreamingMarkdownText's
            // default TextNode branch shows: the bare TeX source as literal text, no raw
            // delimiter flash, no misparse of a still-streaming (unclosed) block.
            content = Self.stripMathBlockDelimiters(content)
        case .listItem(let ordered, let number, let depth):
            font = theme.body
            let indent = String(repeating: "  ", count: depth)
            prefix = indent + (ordered ? "\(number). " : "• ")
            content = Self.stripListMarker(content)
        case .blockquote:
            font = theme.body
        case .paragraph:
            font = theme.body
        case .thematicBreak:
            font = theme.body
        }
        let baseColor = VColorDescriptor.primary
        let (finalContent, runs) = Self.styledContentAndRuns(
            parsed, fallbackContent: content, prefix: prefix, baseFont: font, baseColor: baseColor
        )
        return StyledText(content: finalContent, font: font, runs: runs)
    }

    /// Folds `parsed.runs` (the tokenized inline spans) into the block's final rendered content
    /// and matching `TextRun`s. `fallbackContent` — already fence-stripped/marker-stripped by
    /// `style()` — is used verbatim when `parsed.runs` is empty (codeFence/table/thematicBreak,
    /// or a tokenizable block whose text tokenized to nothing): those kinds render as single-style
    /// text, same as before this bead. `prefix` (a listItem's indent + bullet/number) always
    /// renders in the base style ahead of the tokenized spans, so it never picks up the first
    /// span's emphasis.
    private static func styledContentAndRuns(
        _ parsed: ParsedMDBlock, fallbackContent: String, prefix: String,
        baseFont: VFontDescriptor, baseColor: VColorDescriptor
    ) -> (content: String, runs: [TextRun]) {
        guard !parsed.runs.isEmpty else { return (prefix + fallbackContent, []) }

        var content = prefix
        var runs: [TextRun] = []
        if !prefix.isEmpty {
            runs.append(TextRun(length: prefix.utf16.count, font: baseFont, color: baseColor))
        }
        for run in parsed.runs {
            content += run.text
            runs.append(Self.textRun(for: run, baseFont: baseFont, baseColor: baseColor))
        }
        return (content, runs)
    }

    /// Subtle background pill for inline code, drawn into the raster via `.backgroundColor` —
    /// never a CALayer cornerRadius.
    private static let codeBackgroundColor = VColorDescriptor(red: 0.51, green: 0.55, blue: 0.59, alpha: 0.2)
    private static let codeFontFamily = "Menlo"
    /// Matches UIColor.link's light-mode RGB (0, 122, 255).
    private static let linkColor = VColorDescriptor(red: 0, green: 0.478, blue: 1, alpha: 1)

    /// One `InlineRun`'s markdown emphasis mapped onto a `TextRun` layered over `baseFont`/
    /// `baseColor`. Bold becomes a heavier weight — `VFontTraits` only defines `.italic`
    /// (NodeTable.swift:37), so bold is never a symbolic trait. Flags combine freely: a code
    /// span nested inside bold gets both the heavier weight AND the mono family + pill.
    ///
    /// Internal (not private): `TableCellLayout.swift` reuses this so table-cell emphasis
    /// mapping never drifts from paragraph/heading emphasis mapping (Section 3 cross-site
    /// consistency) — one formula, two call sites.
    static func textRun(for run: InlineRun, baseFont: VFontDescriptor, baseColor: VColorDescriptor) -> TextRun {
        var weight = baseFont.weight
        var traits = baseFont.traits
        var family = baseFont.family
        var color = baseColor
        var backgroundColor: VColorDescriptor?
        var strikethroughStyle = 0
        var linkURL: URL?

        if run.style.contains(.bold) {
            weight = VFontDescriptor.boldWeight
        }
        if run.style.contains(.italic) {
            traits.insert(.italic)
        }
        if run.style.contains(.code) {
            family = Self.codeFontFamily
            backgroundColor = Self.codeBackgroundColor
        }
        if run.style.contains(.strike) {
            strikethroughStyle = VUnderlineStyle.single.rawValue
        }
        if run.style.contains(.link) {
            color = Self.linkColor
            linkURL = run.url.flatMap(URL.init(string:))
        }

        return TextRun(
            length: run.text.utf16.count,
            font: VFontDescriptor(size: baseFont.size, weight: weight, family: family, traits: traits),
            color: color,
            strikethroughStyle: strikethroughStyle,
            backgroundColor: backgroundColor,
            linkURL: linkURL,
            mathSource: run.mathSource
        )
    }

    private static func makeDescriptor(_ parsed: ParsedMDBlock, theme: MarkdownTheme, isPendingTableHeader: Bool = false) -> TextDescriptor {
        let styled = style(parsed, theme: theme, isPendingTableHeader: isPendingTableHeader)

        // `styled.runs` must fold into the hash: two blocks with identical rendered content but
        // different inline styling (e.g. plain "bold" vs "**bold**", both rendering to the
        // content "bold") would otherwise collide onto the same layoutHash/appearanceHash and
        // serve a stale cached raster from HotBlockRasterizerStore/BlockDiff.
        var hasher = Hasher()
        hasher.combine(parsed.kind)
        hasher.combine(styled.content)
        hasher.combine(styled.runs)
        let hash = hasher.finalize()

        return TextDescriptor(
            content: styled.content,
            font: styled.font,
            color: VColorDescriptor.primary,
            lineLimit: nil,
            lineBreakMode: 0,
            runs: styled.runs,
            layoutHash: hash,
            appearanceHash: hash
        )
    }

    private static func stripListMarker(_ line: String) -> String {
        var s = Substring(line)
        s = s.drop { $0 == " " }
        s = s.drop { $0 == "-" || $0 == "*" || $0 == "+" || $0.isNumber || $0 == "." || $0 == ")" }
        return s.drop { $0 == " " }.description
    }

    /// listItem tokenizes the same marker-stripped text `style()` renders, via the same
    /// `stripListMarker` helper, so runs never disagree with what's painted. codeFence/table/
    /// thematicBreak never render as free-form styled text, so they get no runs — a `.table`
    /// block's cells are tokenized separately, per cell, into `ParsedMDBlock.tableRows`.
    private static func tokenizableRuns(for kind: MarkdownBlockKind, text: String) -> [InlineRun] {
        switch kind {
        case .paragraph, .heading, .blockquote:
            return inlineRuns(text)
        case .listItem:
            return inlineRuns(Self.stripListMarker(text))
        case .codeFence, .table, .thematicBreak, .mathBlock:
            return []
        }
    }

    /// True when `line` is a run of >= 3 backticks or tildes (CommonMark's fence-marker
    /// minimum), optionally padded with whitespace.
    private static func isFenceCloseShaped(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "`" } || trimmed.allSatisfy { $0 == "~" }
    }

    /// Strips a `.mathBlock`'s `$$`/`\[...\]` delimiters from its raw multi-line text, leaving
    /// bare TeX — the same convention `style()` uses to strip codeFence's fence-marker lines.
    /// Only the LEADING marker is ever assumed present (block detection guarantees it); the
    /// TRAILING marker is stripped only when it's actually shaped like one, so a still-streaming
    /// (unclosed) block never hides its most recently typed line.
    private static func stripMathBlockDelimiters(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return text }
        let trimmedFirst = first.drop { $0 == " " }
        let closeMarker: String
        if trimmedFirst.hasPrefix("$$") {
            closeMarker = "$$"
        } else if trimmedFirst.hasPrefix("\\[") {
            closeMarker = "\\]"
        } else {
            return text
        }
        var afterOpen = trimmedFirst.dropFirst(2)
        if afterOpen.first == " " { afterOpen = afterOpen.dropFirst() }

        if lines.count == 1 {
            if let closeRange = afterOpen.range(of: closeMarker) {
                var body = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                if body.last == " " { body = body.dropLast() }
                return String(body)
            }
            return String(afterOpen)
        }

        // When the marker sits alone on the opening line (the common "$$\nformula\n$$" shape),
        // drop that line entirely rather than leaving an empty first element — otherwise the
        // join below would prepend a stray blank line ("\nformula") ahead of the real content.
        if afterOpen.isEmpty {
            lines.removeFirst()
        } else {
            lines[0] = afterOpen
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == closeMarker {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tail parse

    private struct TailParseResult {
        var sealed: [ParsedMDBlock]
        var hot: [ParsedMDBlock]
        var cutIndex: String.Index
    }

    /// Line-by-line scan of the hot tail: everything before the last unprotected blank
    /// line (not inside an open fence or container) is sealed. A just-closed fence is an
    /// additional, unconditional seal point — CommonMark never reopens a closed block.
    private static func parseTail(_ source: String) -> TailParseResult {
        var blocks: [ParsedMDBlock] = []
        var pendingSealBlockCount = 0
        var pendingSealCut = source.startIndex

        // Lines, each paired with the source index just past its line terminator (or
        // `source.endIndex` for a final, still-being-typed unterminated line).
        var lines: [(text: Substring, lineEnd: String.Index)] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if let newline = source[cursor...].firstIndex(of: "\n") {
                let lineEnd = source.index(after: newline)
                lines.append((source[cursor..<newline], lineEnd))
                cursor = lineEnd
            } else {
                lines.append((source[cursor...], source.endIndex))
                cursor = source.endIndex
            }
        }

        var openKind: MarkdownBlockKind?
        var openLines: [Substring] = []
        var inFence = false
        var fenceMarker: Substring = ""
        var inMathBlock = false
        var mathBlockCloseMarker = ""
        var inContainer = false
        var containerBlankSeen = false
        var containerBlankCut: (index: String.Index, count: Int)?

        func finalizeOpenBlock() {
            guard let kind = openKind, !openLines.isEmpty else { return }
            blocks.append(Self.makeParsedBlock(kind: kind, lines: openLines))
            openKind = nil
            openLines = []
        }

        func isBlank(_ line: Substring) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" }
        }
        func leadingSpaces(_ line: Substring) -> Int {
            line.prefix { $0 == " " }.count
        }
        func isFenceOpen(_ line: Substring) -> (marker: Substring, language: String?)? {
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
        func isMathBlockOpen(_ line: Substring) -> (closeMarker: String, rest: Substring)? {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("$$") {
                return ("$$", trimmed.dropFirst(2))
            }
            if trimmed.hasPrefix("\\[") {
                return ("\\]", trimmed.dropFirst(2))
            }
            return nil
        }
        func isFenceClose(_ line: Substring, opening: Substring) -> Bool {
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
        func listMarkerInfo(_ line: Substring) -> (ordered: Bool, number: Int, depth: Int)? {
            let spaces = leadingSpaces(line)
            guard spaces <= 3 else { return nil }
            let rest = line.drop { $0 == " " }
            guard let first = rest.first else { return nil }
            let depth = spaces / 2
            if "-*+".contains(first) {
                let after = rest.index(after: rest.startIndex)
                guard after < rest.endIndex, rest[after] == " " else { return nil }
                return (ordered: false, number: 0, depth: depth)
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
            return (ordered: true, number: number, depth: depth)
        }
        func isListMarker(_ line: Substring) -> Bool {
            listMarkerInfo(line) != nil
        }
        func isATXHeading(_ line: Substring) -> (level: Int, content: String)? {
            guard leadingSpaces(line) == 0, line.first == "#" else { return nil }
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
        func isThematicBreak(_ line: Substring) -> Bool {
            guard leadingSpaces(line) == 0 else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first) else { return false }
            return trimmed.allSatisfy { $0 == first }
        }
        func isBlockquoteMarker(_ line: Substring) -> Bool {
            guard leadingSpaces(line) <= 3 else { return false }
            return line.drop { $0 == " " }.first == ">"
        }
        // Validates a delimiter row AND parses its per-column alignment in the same pass —
        // one source of truth for "is this a delimiter row" and "what does it say", so the
        // promotion check and the alignment it commits to a `.table` block can never disagree.
        func tableDelimiterAlignments(_ line: Substring) -> [TableColumnAlignment]? {
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
        func isSetextUnderline(_ line: Substring) -> Int? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if t.allSatisfy({ $0 == "=" }) { return 1 }
            if t.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        for (line, lineEnd) in lines {
            if inFence {
                openLines.append(line)
                if isFenceClose(line, opening: fenceMarker) {
                    inFence = false
                    finalizeOpenBlock()
                    // A closed fence is an unconditional seal point — see doc comment.
                    pendingSealCut = lineEnd
                    pendingSealBlockCount = blocks.count
                }
                continue
            }

            if inMathBlock {
                openLines.append(line)
                if line.trimmingCharacters(in: .whitespaces) == mathBlockCloseMarker {
                    inMathBlock = false
                    finalizeOpenBlock()
                    // A closed math block is an unconditional seal point, same as a closed fence.
                    pendingSealCut = lineEnd
                    pendingSealBlockCount = blocks.count
                }
                continue
            }

            if isBlank(line) {
                if inContainer {
                    containerBlankSeen = true
                    containerBlankCut = (lineEnd, blocks.count)
                    continue
                }
                finalizeOpenBlock()
                pendingSealCut = lineEnd
                pendingSealBlockCount = blocks.count
                continue
            }

            if let (marker, language) = isFenceOpen(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                inFence = true
                fenceMarker = marker
                openKind = .codeFence(language: language)
                openLines = [line]
                continue
            }

            if let (closeMarker, rest) = isMathBlockOpen(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                if rest.range(of: closeMarker) != nil {
                    // Same-line close ("$$ E=mc^2 $$") — a one-line block, finalized right away
                    // like a heading/thematic-break; `style()` strips both markers at render.
                    openKind = .mathBlock
                    openLines = [line]
                    finalizeOpenBlock()
                    continue
                }
                inMathBlock = true
                mathBlockCloseMarker = closeMarker
                openKind = .mathBlock
                openLines = [line]
                continue
            }

            if let (level, headingText) = isATXHeading(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                openKind = .heading(level: level)
                openLines = [Substring(headingText)]
                finalizeOpenBlock()
                continue
            }

            if case .paragraph = openKind, openLines.count == 1, let level = isSetextUnderline(line) {
                openKind = .heading(level: level)
                continue
            }

            if isThematicBreak(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                openKind = .thematicBreak
                openLines = [line]
                finalizeOpenBlock()
                continue
            }

            if case .paragraph = openKind, openLines.count == 1, openLines[0].contains("|"),
               let alignments = tableDelimiterAlignments(line) {
                openKind = .table(alignments: alignments)
                openLines.append(line)
                continue
            }
            if case .table = openKind, line.contains("|") {
                openLines.append(line)
                continue
            }

            // A fresh column-0, non-marker line after a blank was seen inside an open container
            // definitively closes it — retroactively promotes the withheld blank-line seal.
            if inContainer, containerBlankSeen, !isListMarker(line), !isBlockquoteMarker(line), leadingSpaces(line) == 0 {
                inContainer = false
                containerBlankSeen = false
                if let cut = containerBlankCut {
                    pendingSealCut = cut.index
                    pendingSealBlockCount = cut.count
                }
                containerBlankCut = nil
            }

            if let info = listMarkerInfo(line) {
                finalizeOpenBlock()
                inContainer = true
                containerBlankSeen = false
                openKind = .listItem(ordered: info.ordered, number: info.number, depth: info.depth)
                openLines = [line]
                finalizeOpenBlock()  // each list marker line is its own block
                continue
            }
            if isBlockquoteMarker(line) {
                if case .blockquote = openKind {
                    openLines.append(line)
                } else {
                    finalizeOpenBlock()
                    openKind = .blockquote
                    openLines = [line]
                }
                inContainer = true
                containerBlankSeen = false
                continue
            }

            if openKind == nil {
                openKind = .paragraph
                openLines = [line]
            } else if case .paragraph = openKind {
                openLines.append(line)
            } else {
                finalizeOpenBlock()
                openKind = .paragraph
                openLines = [line]
            }
        }

        // Whatever remains open stays hot — not finalized here, so it never looks sealed.
        let sealedCount = min(pendingSealBlockCount, blocks.count)
        let sealed = Array(blocks[0..<sealedCount])
        var hot = Array(blocks[sealedCount...])
        if let kind = openKind, !openLines.isEmpty {
            hot.append(Self.makeParsedBlock(kind: kind, lines: openLines))
        }
        return TailParseResult(sealed: sealed, hot: hot, cutIndex: pendingSealCut)
    }

    /// Builds one `ParsedMDBlock` from an open/closing run of lines — the single construction
    /// site `finalizeOpenBlock()` and the tail's trailing hot block both call, so they can't
    /// drift on how `.table` blocks get their `tableRows` populated.
    private static func makeParsedBlock(kind: MarkdownBlockKind, lines: [Substring]) -> ParsedMDBlock {
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
    private static func splitTableRowCells(_ line: Substring, columnCount: Int) -> [String] {
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

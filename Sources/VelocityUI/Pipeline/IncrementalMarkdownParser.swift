// IncrementalMarkdownParser.swift

import Foundation
import CoreGraphics

// MARK: - MarkdownBlockKind

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
    /// GFM table row — `isHeader` is true only for the row retroactively joined with its
    /// delimiter row. Body rows that follow append with `false`.
    case tableRow(isHeader: Bool)
    /// A `---`/`***`/`___` rule line.
    case thematicBreak
}

/// A styled span within a text block's content, produced by `inlineRuns(_:)`. `url` is only
/// meaningful when `style` contains `.link`.
struct InlineRun: Equatable, Sendable {
    var text: String
    var style: StyleFlags
    var url: String?
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
        if let first = chars.first, first == "*" || first == "_" {
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
                            runs.append(InlineRun(text: inner.text, style: flags.union(inner.style).union(.link), url: linkURL))
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

/// One markdown block the incremental parser has classified: a kind plus its raw source text
/// (lines joined by `\n`, marker/underline syntax stripped where it isn't part of the rendered
/// content — e.g. a setext `===` underline or a table delimiter row) plus its tokenized inline
/// spans (empty for kinds that don't render as free-form styled text).
struct ParsedMDBlock: Equatable {
    var kind: MarkdownBlockKind
    var text: String
    var runs: [InlineRun] = []
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
        for (index, pair) in zip(sealedBlocks + hotBlocksState, sealedBlockIDs + hotBlockIDs).enumerated() {
            let lifecycle: BlockLifecycle = index < sealedBlocks.count ? .sealed : .hot
            blocks.append(Self.makeBlock(pair.0, itemID: itemID, index: index, blockID: pair.1, width: width, lifecycle: lifecycle, theme: theme))
        }
        return blocks
    }

    // MARK: - Block construction

    private static func makeBlock<ID: Hashable & Sendable>(
        _ parsed: ParsedMDBlock, itemID: ID, index: Int, blockID: BlockID, width: CGFloat,
        lifecycle: BlockLifecycle, theme: MarkdownTheme
    ) -> Block {
        let descriptor = makeDescriptor(parsed, theme: theme)
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
    /// tokenizes (codeFence/tableRow/thematicBreak) or when `parsed.runs` itself is empty —
    /// both `makeDescriptor` and `renderNodes` pass it straight through to their respective
    /// `TextDescriptor`/`TextNode`.
    struct StyledText {
        var content: String
        var font: VFontDescriptor
        var runs: [TextRun] = []
    }

    static func style(_ parsed: ParsedMDBlock, theme: MarkdownTheme = .default) -> StyledText {
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
        case .tableRow:
            font = theme.body
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
    /// `style()` — is used verbatim when `parsed.runs` is empty (codeFence/tableRow/thematicBreak,
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
    private static func textRun(for run: InlineRun, baseFont: VFontDescriptor, baseColor: VColorDescriptor) -> TextRun {
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
            linkURL: linkURL
        )
    }

    private static func makeDescriptor(_ parsed: ParsedMDBlock, theme: MarkdownTheme) -> TextDescriptor {
        let styled = style(parsed, theme: theme)

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
    /// `stripListMarker` helper, so runs never disagree with what's painted. codeFence/tableRow/
    /// thematicBreak never render as free-form styled text, so they get no runs.
    private static func tokenizableRuns(for kind: MarkdownBlockKind, text: String) -> [InlineRun] {
        switch kind {
        case .paragraph, .heading, .blockquote:
            return inlineRuns(text)
        case .listItem:
            return inlineRuns(Self.stripListMarker(text))
        case .codeFence, .tableRow, .thematicBreak:
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
        var inContainer = false
        var containerBlankSeen = false
        var containerBlankCut: (index: String.Index, count: Int)?

        func finalizeOpenBlock() {
            guard let kind = openKind, !openLines.isEmpty else { return }
            let text = openLines.map(String.init).joined(separator: "\n")
            blocks.append(ParsedMDBlock(kind: kind, text: text, runs: Self.tokenizableRuns(for: kind, text: text)))
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
        func isTableDelimiterRow(_ line: Substring) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            let cells = t.split(separator: "|", omittingEmptySubsequences: true)
            guard !cells.isEmpty else { return false }
            for cell in cells {
                let c = cell.trimmingCharacters(in: .whitespaces)
                guard !c.isEmpty, c.contains("-") else { return false }
                for ch in c where ch != "-" && ch != ":" { return false }
            }
            return true
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

            if case .paragraph = openKind, openLines.count == 1, openLines[0].contains("|"), isTableDelimiterRow(line) {
                openKind = .tableRow(isHeader: true)
                openLines.append(line)
                continue
            }
            if case .tableRow = openKind, line.contains("|") {
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
            let text = openLines.map(String.init).joined(separator: "\n")
            hot.append(ParsedMDBlock(kind: kind, text: text, runs: Self.tokenizableRuns(for: kind, text: text)))
        }
        return TailParseResult(sealed: sealed, hot: hot, cutIndex: pendingSealCut)
    }
}

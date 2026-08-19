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
    case listItem(ordered: Bool)
    case blockquote
    /// GFM table row — `isHeader` is true only for the row that was retroactively joined with
    /// its delimiter row (Hazard B). Body rows that follow the same table append with `false`.
    case tableRow(isHeader: Bool)
}

/// One markdown block the incremental parser has classified: a kind plus its raw source text
/// (lines joined by `\n`, marker/underline syntax stripped where it isn't part of the rendered
/// content — e.g. a setext `===` underline or a table delimiter row).
struct ParsedMDBlock: Equatable {
    var kind: MarkdownBlockKind
    var text: String
}

// MARK: - IncrementalMarkdownParser

/// Consumes an appended token/markdown stream and emits blocks split into two tiers at a
/// monotonically non-decreasing frontier `F`: **sealed** blocks (`source[0..<F)`), guaranteed
/// never to change, and **hot** blocks (the open right spine), which may still be retyped or
/// absorb more lines. This is the contract VelocityUI-qc7.1's spike proved sufficient to keep
/// `freeze()` valid under real streaming markdown (`INCREMENTAL_PARSER_STABILITY_SPIKE.md`) — a
/// caller may `freeze()` sealed blocks, never the hot region. `frontier` (== `sealedBlocks.count`)
/// is exactly `diff(previous:new:frontier:)`'s `frontier:` argument.
///
/// **Not a RenderEnvironment collaborator** — per-item streaming state, one instance per
/// in-flight message, owned by whatever holds that message's accumulated source (same lifetime
/// as `previousFragments`/`NodeTable`), not a composition-root collaborator.
///
/// **Deliberately simplified CommonMark subset, not full compliance:** list/blockquote
/// continuation is line-shape heuristics, not full lazy-continuation; GFM tables render each row
/// as one pipe-joined text line; fences don't nest inside list items. Guaranteed (tested by this
/// bead's acceptance criteria): a sealed block never moves, `F` never decreases, a blank line
/// inside an open fence never seals.
public struct IncrementalMarkdownParser: Sendable, Equatable {

    /// Finalized, immutable blocks — never touched again once appended here.
    private(set) var sealedBlocks: [ParsedMDBlock] = []
    private(set) var sealedBlockIDs: [BlockID] = []

    /// The unsealed tail of the source since the last seal — re-scanned in full on every
    /// `append(_:)` (bounded in size except during an open fence; see the spike's bounded-reach
    /// theorem), never the whole message.
    private var hotTail: String = ""

    /// The hot region's current parse, kept alongside `hotTail` so `blocks(itemID:width:)`
    /// doesn't need to re-run the scanner.
    private(set) var hotBlocksState: [ParsedMDBlock] = []
    private(set) var hotBlockIDs: [BlockID] = []
    private var nextBlockID = 0

    public init() {}

    /// The sealed-block count — the frontier `F` a caller passes to
    /// `diff(previous:new:frontier:)`. Monotonically non-decreasing across calls to
    /// `append(_:)` by construction: `sealedBlocks` is only ever appended to, never truncated.
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
    public func blockList<ID: Hashable & Sendable>(itemID: ID, width: CGFloat) -> [Block] {
        var blocks: [Block] = []
        blocks.reserveCapacity(sealedBlocks.count + hotBlocksState.count)
        for (index, pair) in zip(sealedBlocks + hotBlocksState, sealedBlockIDs + hotBlockIDs).enumerated() {
            blocks.append(Self.makeBlock(pair.0, itemID: itemID, index: index, blockID: pair.1, width: width))
        }
        return blocks
    }

    // MARK: - Block construction

    private static func makeBlock<ID: Hashable & Sendable>(
        _ parsed: ParsedMDBlock, itemID: ID, index: Int, blockID: BlockID, width: CGFloat
    ) -> Block {
        let descriptor = makeDescriptor(parsed)
        let frame = CGRect(x: 0, y: 0, width: width, height: 0)
        let fragment = Fragment(id: index, blockID: blockID, content: .text(descriptor), frame: frame)
        return Block(key: BlockKey(itemID: itemID, blockID: blockID), fragment: fragment, layout: ResolvedLayout(totalFrame: frame))
    }

    private mutating func reconciledIDs(existing: [BlockID], count: Int) -> [BlockID] {
        var ids = Array(existing.prefix(count))
        while ids.count < count {
            ids.append(BlockID(nextBlockID))
            nextBlockID += 1
        }
        return ids
    }

    /// A block's rendered text plus the font it renders with — the one place block-kind →
    /// content-transform/font-size/weight is decided, shared by `makeDescriptor` (Layer 2's
    /// `TextDescriptor`) and `renderNodes` (Layer 1's `TextNode`) so `content`/`font` can never
    /// silently diverge between the two representations.
    ///
    /// Covers `content` + `font` only — color/line-break are each caller's own default
    /// (`makeDescriptor`: opaque black + `lineBreakMode: 0`; `renderNodes`: `TextNode`'s
    /// `.primary` + `.byWordWrapping`). Independent decisions that render identically today but
    /// aren't a shared source of truth — harmless since the two paths never render the same
    /// block side-by-side. Don't extend the "can never diverge" claim past `content`/`font`
    /// without also unifying those.
    struct StyledText {
        var content: String
        var font: VFontDescriptor
    }

    static func style(_ parsed: ParsedMDBlock) -> StyledText {
        let size: CGFloat
        let weight: Int
        var content = parsed.text
        switch parsed.kind {
        case .heading(let level):
            size = CGFloat(max(15, 28 - (level - 1) * 3))
            weight = 7  // bold
        case .codeFence:
            size = 20
            weight = 4
            // Strip the fence marker lines — they are syntax, not renderable content. The
            // opening marker line always exists (a codeFence block can't be classified without
            // one), so it is safe to drop unconditionally. The closing marker line is only
            // present once the fence has actually closed — for a still-open (streaming) fence
            // the last line is real code, and unconditionally dropping it would hide the most
            // recently streamed line until the fence closes. Only drop the last line when it is
            // actually shaped like a closing fence marker.
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty {
                lines.removeFirst()
            }
            if let last = lines.last, Self.isFenceCloseShaped(last) {
                lines.removeLast()
            }
            content = lines.joined(separator: "\n")
        case .tableRow:
            size = 20
            weight = 4
        case .listItem:
            size = 20
            weight = 4
            content = "• " + Self.stripListMarker(content)
        case .blockquote:
            size = 20
            weight = 4
        case .paragraph:
            size = 20
            weight = 4
        }
        return StyledText(content: content, font: VFontDescriptor(size: size, weight: weight))
    }

    private static func makeDescriptor(_ parsed: ParsedMDBlock) -> TextDescriptor {
        let styled = style(parsed)

        var hasher = Hasher()
        hasher.combine(parsed.kind)
        hasher.combine(styled.content)
        let hash = hasher.finalize()

        return TextDescriptor(
            content: styled.content,
            font: styled.font,
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
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

    /// True when `line` is shaped like a closing fence marker — a run of backticks or tildes
    /// (length >= 3, matching CommonMark's fence-marker minimum), optionally surrounded by
    /// whitespace. Used by `makeDescriptor`'s `.codeFence` case to distinguish "this is the
    /// closing ``` line, strip it" from "this is real streamed code that merely ends the still-
    /// open fence's current content, keep it."
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

    /// Pure line-by-line scan of `source` (the current hot tail). Implements the blank-line
    /// seal lemma from the spike: everything before the last **unprotected** blank line (not
    /// inside an open fence, and not while a list/blockquote container is open) is sealed. A
    /// just-closed fence is an additional, unconditional seal point — CommonMark never reopens
    /// a closed block, so there is no need to wait for a further blank line after one.
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
            blocks.append(ParsedMDBlock(kind: kind, text: openLines.map(String.init).joined(separator: "\n")))
            openKind = nil
            openLines = []
        }

        func isBlank(_ line: Substring) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" }
        }
        func leadingSpaces(_ line: Substring) -> Int {
            line.prefix { $0 == " " }.count
        }
        func isFenceOpen(_ line: Substring) -> Substring? {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") { return trimmed.prefix { $0 == "`" } }
            if trimmed.hasPrefix("~~~") { return trimmed.prefix { $0 == "~" } }
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
        func isListMarker(_ line: Substring) -> Bool {
            guard leadingSpaces(line) <= 3 else { return false }
            let rest = line.drop { $0 == " " }
            guard let first = rest.first else { return false }
            if "-*+".contains(first) {
                let after = rest.index(after: rest.startIndex)
                return after < rest.endIndex && rest[after] == " "
            }
            var idx = rest.startIndex
            var digits = 0
            while idx < rest.endIndex, rest[idx].isNumber {
                idx = rest.index(after: idx)
                digits += 1
            }
            guard digits > 0, idx < rest.endIndex, rest[idx] == "." || rest[idx] == ")" else { return false }
            let after = rest.index(after: idx)
            return after < rest.endIndex && rest[after] == " "
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

            if let marker = isFenceOpen(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                inFence = true
                fenceMarker = marker
                openKind = .codeFence(language: nil)
                openLines = [line]
                continue
            }

            if case .paragraph = openKind, openLines.count == 1, let level = isSetextUnderline(line) {
                openKind = .heading(level: level)
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

            if isListMarker(line) {
                finalizeOpenBlock()
                inContainer = true
                containerBlankSeen = false
                let rest = line.drop { $0 == " " }
                let ordered = rest.first?.isNumber == true
                openKind = .listItem(ordered: ordered)
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

        // Whatever remains open (including an open fence/container/paragraph) stays hot — it is
        // NOT finalized here, so it never leaks into `blocks[pendingSealBlockCount...]`'s hot
        // slice as something that looks finalized.
        let sealedCount = min(pendingSealBlockCount, blocks.count)
        let sealed = Array(blocks[0..<sealedCount])
        var hot = Array(blocks[sealedCount...])
        if let kind = openKind, !openLines.isEmpty {
            hot.append(ParsedMDBlock(kind: kind, text: openLines.map(String.init).joined(separator: "\n")))
        }
        return TailParseResult(sealed: sealed, hot: hot, cutIndex: pendingSealCut)
    }
}

#if canImport(XCTest)
extension IncrementalMarkdownParser {
    /// Test-only contract tripwire (design doc §5.4): a sealed block's key+content must never
    /// differ from what an earlier snapshot already reported at the same index — the debug
    /// assert `assert(sealed.contentHash == frozen)` the spike calls for. Not used on any
    /// production path; gated on `canImport(XCTest)` (never `#if DEBUG`) per CLAUDE.md.
    func debugSealedPrefixMatches<ID: Hashable & Sendable>(_ previous: [Block], itemID: ID, width: CGFloat) -> Bool {
        let current = blockList(itemID: itemID, width: width)
        let count = min(previous.count, sealedBlocks.count)
        for i in 0..<count {
            guard previous[i].key == current[i].key, previous[i].contentHash == current[i].contentHash else {
                return false
            }
        }
        return true
    }
}
#endif

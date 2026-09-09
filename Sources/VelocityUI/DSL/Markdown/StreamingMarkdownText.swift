// StreamingMarkdownText.swift

#if canImport(os)
import os
#endif

#if canImport(os) && DEBUG
/// Temporary diagnostic for VelocityUI-pojd: compares the raw markdown line the model streamed
/// against the URL our image-line parser extracted from it, to catch any real-world image
/// syntax our parser mishandles (vs. the model simply hallucinating a dead/non-image URL).
private let markdownImageLog = Logger(subsystem: "com.velocityui", category: "MarkdownImage")
#endif

extension IncrementalMarkdownParser {

    /// One block's identity/lifecycle plus its parsed content, so a caching owner can decide
    /// per block whether to reuse a stored `TextNode` or call `style(_:)`.
    struct RenderableBlock {
        var blockID: BlockID
        var isSealed: Bool
        var parsed: ParsedMDBlock
    }

    /// Sealed blocks then the open hot region — the raw material `renderNodes` styles into
    /// `TextNode`s.
    var renderableBlocks: [RenderableBlock] {
        zip(sealedBlocks + hotBlocksState, sealedBlockIDs + hotBlockIDs).enumerated().map { index, pair in
            RenderableBlock(blockID: pair.1, isSealed: index < sealedBlocks.count, parsed: pair.0)
        }
    }

    /// Layer-1 DSL bridge: one `TextNode` per block, sealed then hot, re-derived from scratch
    /// on every read via `style(_:)`.
    ///
    ///     VStackNode(alignment: .leading, spacing: 8) { message.markdownParser.renderNodes }
    ///
    /// Fine when block count is bounded (a viewport); for an unboundedly growing transcript use
    /// `StreamingMarkdownController` below, which memoizes sealed blocks instead.
    public var renderNodes: [any RenderNode] {
        _renderNodes(theme: .default)
    }

    /// Themed variant of `renderNodes`. Pass the same `MarkdownTheme` you give the measurement
    /// path (`blockList(itemID:width:theme:)`) so styled font and measured layout agree.
    public func renderNodes(theme: MarkdownTheme) -> [any RenderNode] {
        _renderNodes(theme: theme)
    }

    /// One block's DSL node — a `CodeBlockNode` for a fenced code block, a `MarkdownTableNode`
    /// for a grouped table block, a `TextNode` otherwise. Shared by `_renderNodes` and
    /// `StreamingMarkdownController.renderNodes` so the live and cached paths can't drift on
    /// which blocks get code/table presentation.
    /// `isPendingTableHeader` must only be true for the last block in the full sealed+hot
    /// sequence — see `isPendingTableCandidate`. A non-trailing block matching that text shape
    /// has already been resolved as a plain paragraph by whatever followed it.
    static func renderNode(for block: RenderableBlock, theme: MarkdownTheme, isPendingTableHeader: Bool = false) -> any RenderNode {
        if case .image(let url) = block.parsed.kind {
            #if canImport(os) && DEBUG
            markdownImageLog.debug("raw line: \(block.parsed.text, privacy: .public) -> parsed url: \(url.absoluteString, privacy: .public)")
            #endif
            return AsyncImageNode(url: url)
        }
        let styled = Self.style(block.parsed, theme: theme, isPendingTableHeader: isPendingTableHeader)
        let lifecycle: BlockLifecycle = block.isSealed ? .sealed : .hot
        if case .codeFence(let language) = block.parsed.kind {
            return CodeBlockNode(
                language: language, rawCode: styled.content, font: theme.code,
                blockID: block.blockID, blockLifecycle: lifecycle
            )
        }
        if case .table(let alignments) = block.parsed.kind {
            return MarkdownTableNode(
                tableRows: block.parsed.tableRows, alignments: alignments, font: theme.body,
                blockID: block.blockID, blockLifecycle: lifecycle
            )
        }
        if case .mathBlock = block.parsed.kind {
            return MathBlockNode(
                rawTeX: styled.content, font: theme.body,
                blockID: block.blockID, blockLifecycle: lifecycle
            )
        }
        let decoration = IncrementalMarkdownParser.textDecoration(for: block.parsed.kind)
        return TextNode(
            styled.content, font: styled.font, color: decoration.color, runs: styled.runs,
            leadingBarColor: decoration.barColor, leadingBarWidth: decoration.barWidth, leadingBarGap: decoration.barGap,
            ruleColor: decoration.ruleColor,
            blockID: block.blockID, blockLifecycle: lifecycle
        )
    }

    private func _renderNodes(theme: MarkdownTheme) -> [any RenderNode] {
        let blocks = renderableBlocks
        let lastIndex = blocks.count - 1
        return blocks.enumerated().map { index, block in
            let isPending = index == lastIndex && !block.isSealed && IncrementalMarkdownParser.isPendingTableCandidate(block.parsed)
            return Self.renderNode(for: block, theme: theme, isPendingTableHeader: isPending)
        }
    }
}

// MARK: - StreamingMarkdownController

/// Caches `TextNode`s for sealed blocks so `renderNodes` costs O(hot blocks) per read, not
/// O(blocks appended so far). Lives outside `IncrementalMarkdownParser` on purpose — the parser
/// stays a pure value type, this cache is Layer-1 DSL state.
///
/// Sealed blocks never change (parser contract), so each one is styled once, on the read where
/// it first appears sealed, then served from cache forever after. The hot tail always rebuilds.
///
/// Lifetime matches whatever owns this controller (typically one chat message) — not a
/// feed-wide collaborator, so it isn't registered on `RenderEnvironment`.
///
///     let message = StreamingMarkdownController()
///     message.append(token)
///     VStackNode(alignment: .leading, spacing: 8) { message.renderNodes }
@MainActor
public final class StreamingMarkdownController {
    public private(set) var parser: IncrementalMarkdownParser
    /// Fonts every block styles against. Fixed for this controller's lifetime — set it here at
    /// construction; sealed blocks are cached, so changing it later won't restyle them.
    public let theme: MarkdownTheme
    private var sealedNodes: [BlockID: any RenderNode] = [:]

    public init(
        parser: IncrementalMarkdownParser = IncrementalMarkdownParser(),
        theme: MarkdownTheme = .default
    ) {
        self.parser = parser
        self.theme = theme
    }

    public func append(_ text: String) {
        parser.append(text)
    }

    /// Same shape/order as `IncrementalMarkdownParser.renderNodes`. Sealed + cached -> returned
    /// as-is. Everything else is built via `style(_:)` and, if sealed, cached.
    public var renderNodes: [any RenderNode] {
        let blocks = parser.renderableBlocks
        let lastIndex = blocks.count - 1
        return blocks.enumerated().map { index, block in
            if block.isSealed, let cached = sealedNodes[block.blockID] {
                return cached
            }
            _testHooks.styleCount += 1
            let isPending = index == lastIndex && !block.isSealed && IncrementalMarkdownParser.isPendingTableCandidate(block.parsed)
            let node = IncrementalMarkdownParser.renderNode(for: block, theme: theme, isPendingTableHeader: isPending)
            if block.isSealed {
                sealedNodes[block.blockID] = node
            }
            return node
        }
    }

    /// Stored test-only observability state. Always present (no XCTest guard) — production code
    /// (`renderNodes`) references it unconditionally. See `StreamingMarkdownControllerTestHooks`
    /// in StreamingMarkdownText+TestHooks.swift.
    let _testHooks = StreamingMarkdownControllerTestHooks()
}

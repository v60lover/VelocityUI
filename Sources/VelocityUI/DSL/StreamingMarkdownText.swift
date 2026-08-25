// StreamingMarkdownText.swift

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

    private func _renderNodes(theme: MarkdownTheme) -> [any RenderNode] {
        renderableBlocks.map { block in
            let styled = Self.style(block.parsed, theme: theme)
            return TextNode(
                styled.content, font: styled.font, runs: styled.runs,
                blockID: block.blockID, blockLifecycle: block.isSealed ? .sealed : .hot
            )
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
    private var sealedNodes: [BlockID: TextNode] = [:]

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
        parser.renderableBlocks.map { block in
            if block.isSealed, let cached = sealedNodes[block.blockID] {
                return cached
            }
            _testHooks.styleCount += 1
            let styled = IncrementalMarkdownParser.style(block.parsed, theme: theme)
            let node = TextNode(
                styled.content, font: styled.font, runs: styled.runs,
                blockID: block.blockID, blockLifecycle: block.isSealed ? .sealed : .hot
            )
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

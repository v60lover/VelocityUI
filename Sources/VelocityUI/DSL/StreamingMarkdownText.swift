// StreamingMarkdownText.swift

extension IncrementalMarkdownParser {

    /// Layer-1 DSL bridge: one `TextNode` per block the parser currently holds (sealed blocks then
    /// the open hot region, same order as `blockList(itemID:width:)`), styled via the shared
    /// `style(_:)` helper.
    ///
    /// The parser is caller-owned value-type state, stored on the `Item` and mutated with
    /// `.append(_:)` as tokens arrive (see `IncrementalMarkdownParser`'s doc for why it's not a
    /// `RenderEnvironment` collaborator). `renderNodes` re-derives the tree from whatever the parser
    /// holds at read time — no extra storage or wiring:
    ///
    ///     VStackNode(alignment: .leading, spacing: 8) { message.markdownParser.renderNodes }
    ///
    /// Flattens to a plain `.vstack` of `.text` children — the shape `FeedScrollView`'s C3 bind site
    /// already recognizes, so unchanged blocks reuse `FrozenBitmapStore` and only new/changed
    /// blocks re-measure per streaming update.
    public var renderNodes: [any RenderNode] {
        (sealedBlocks + hotBlocksState).map { parsed in
            let styled = Self.style(parsed)
            return TextNode(styled.content, font: styled.font)
        }
    }
}

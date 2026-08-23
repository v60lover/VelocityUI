// StreamingMarkdownText.swift

extension IncrementalMarkdownParser {

    /// Layer-1 DSL bridge: one `TextNode` per block the parser currently holds (sealed blocks then
    /// the open hot region), styled via the shared `style(_:)` helper.
    ///
    /// The parser is caller-owned value-type state, mutated with `.append(_:)` as tokens arrive.
    /// `renderNodes` re-derives the tree from whatever the parser holds at read time:
    ///
    ///     VStackNode(alignment: .leading, spacing: 8) { message.markdownParser.renderNodes }
    ///
    /// Flattens to a plain `.vstack` of `.text` children, so unchanged blocks reuse
    /// `FrozenBitmapStore` and only new/changed blocks re-measure per streaming update.
    public var renderNodes: [any RenderNode] {
        zip(sealedBlocks + hotBlocksState, sealedBlockIDs + hotBlockIDs).enumerated().map { index, pair in
            let (parsed, blockID) = pair
            let styled = Self.style(parsed)
            let lifecycle: BlockLifecycle = index < sealedBlocks.count ? .sealed : .hot
            return TextNode(styled.content, font: styled.font, blockID: blockID, blockLifecycle: lifecycle)
        }
    }
}

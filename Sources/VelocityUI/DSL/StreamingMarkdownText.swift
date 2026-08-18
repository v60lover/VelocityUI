// StreamingMarkdownText.swift

extension IncrementalMarkdownParser {

    /// Layer-1 DSL bridge: one `TextNode` per block the parser currently holds (sealed blocks
    /// followed by the still-open hot region, same order `blockList(itemID:width:)` uses),
    /// styled identically to that Layer 2/3 API via the shared `style(_:)` helper.
    ///
    /// The parser is value-type state the caller owns and mutates with `.append(_:)` as new
    /// tokens arrive — typically stored on the `Item` passed to `AsyncFeed`'s `cellBuilder`
    /// (see `IncrementalMarkdownParser`'s own doc for why it is deliberately NOT a
    /// `RenderEnvironment` collaborator). Reading `renderNodes` inside `renderBody` re-derives
    /// the current node tree from whatever the parser holds at that moment — no separate
    /// storage or wiring needed on VelocityUI's side:
    ///
    ///     struct Message: Identifiable, Sendable, Equatable {
    ///         let id: UUID
    ///         var markdownParser: IncrementalMarkdownParser
    ///     }
    ///
    ///     struct MessageCell: RenderView {
    ///         let message: Message
    ///         var renderBody: some RenderNode {
    ///             VStackNode(alignment: .leading, spacing: 8) {
    ///                 message.markdownParser.renderNodes
    ///             }
    ///         }
    ///     }
    ///
    /// This flattens to a plain `.vstack` of `.text` children — the exact shape
    /// `FeedScrollView`'s C3 bind site (`flatBlocks(for:itemID:width:)` /
    /// `applyInPlaceBlockDiff`) already recognizes, so unchanged blocks are reused from
    /// `FrozenBitmapStore` and only new/changed blocks are re-measured on each streaming update.
    public var renderNodes: [any RenderNode] {
        (sealedBlocks + hotBlocksState).map { parsed in
            let styled = Self.style(parsed)
            return TextNode(styled.content, font: styled.font)
        }
    }
}

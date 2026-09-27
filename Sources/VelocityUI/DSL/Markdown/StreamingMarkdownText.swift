// StreamingMarkdownText.swift

import CoreGraphics

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

    /// Borrowed views of the current hot block. All three slices retain the same raw buffer.
    struct OpenTextHandoff {
        var frozen: Substring
        var unsettled: Substring
        var tail: Substring
        var invalidatedLines: Range<Int>?

        /// 0 only when verified: frozen/unsettled/tail are contiguous slices of one buffer, so
        /// construction copied nothing. Falls back to the full byte count if that ever stops
        /// being true, so a future regression shows up here instead of being asserted away.
        var bytesCopied: Int {
            let totalBytes = frozen.utf8.count + unsettled.utf8.count + tail.utf8.count
            guard let f = Self.contiguousStorage(frozen), let u = Self.contiguousStorage(unsettled),
                  let t = Self.contiguousStorage(tail) else { return totalBytes }
            let adjacent = f.base.advanced(by: f.count) == u.base && u.base.advanced(by: u.count) == t.base
            return adjacent ? 0 : totalBytes
        }

        private static func contiguousStorage(_ s: Substring) -> (base: UnsafeRawPointer, count: Int)? {
            s.utf8.withContiguousStorageIfAvailable { buf in
                buf.baseAddress.map { (UnsafeRawPointer($0), buf.count) }
            }.flatMap { $0 }
        }
    }

    /// One block's identity/lifecycle plus its parsed content, so a caching owner can decide
    /// per block whether to reuse a stored `TextNode` or call `style(_:)`.
    struct RenderableBlock {
        var blockID: BlockID
        var isSealed: Bool
        var parsed: ParsedMDBlock
        var openText: OpenTextHandoff?

        /// `parsed.text` is already the flattened frozen+unsettled+tail content (they're always
        /// adjacent slices of it -- see `openTextHandoff(for:at:)`), so there's nothing to copy.
        func parsedAtRenderBoundary() -> (block: ParsedMDBlock, bytesCopied: Int) {
            (parsed, 0)
        }
    }

    /// Sealed blocks then the open hot region — the raw material `renderNodes` styles into
    /// `TextNode`s.
    var renderableBlocks: [RenderableBlock] {
        zip(sealedBlocks + hotBlocksState, sealedBlockIDs + hotBlockIDs).enumerated().map { index, pair in
            let isSealed = index < sealedBlocks.count
            return RenderableBlock(
                blockID: pair.1, isSealed: isSealed, parsed: pair.0,
                openText: isSealed ? nil : openTextHandoff(for: pair.0, at: index)
            )
        }
    }

    func renderableBlock(at index: Int) -> RenderableBlock {
        if index < sealedBlocks.count {
            return RenderableBlock(
                blockID: sealedBlockIDs[index], isSealed: true,
                parsed: sealedBlocks[index], openText: nil
            )
        }
        let hotIndex = index - sealedBlocks.count
        let block = hotBlocksState[hotIndex]
        return RenderableBlock(
            blockID: hotBlockIDs[hotIndex], isSealed: false,
            parsed: block, openText: openTextHandoff(for: block, at: index)
        )
    }

    private func openTextHandoff(for block: ParsedMDBlock, at index: Int) -> OpenTextHandoff? {
        guard index == sealedBlocks.count + hotBlocksState.count - 1 else { return nil }
        switch block.kind {
        case .paragraph, .heading, .blockquote: break
        default: return nil
        }
        let bytes = block.text.utf8
        let hasInlineWindow = inlineWindow.identity == index && inlineWindow.kind == block.kind
        let frozenCount = hasInlineWindow ? inlineWindow.frozenByteCount : 0
        let frozenEnd = bytes.index(bytes.startIndex, offsetBy: min(frozenCount, bytes.count))
        let pendingCount = min(hotPendingLine.utf8.count, bytes.distance(from: frozenEnd, to: bytes.endIndex))
        let tailStart = bytes.index(bytes.endIndex, offsetBy: -pendingCount)
        return OpenTextHandoff(
            frozen: block.text[..<frozenEnd], unsettled: block.text[frozenEnd..<tailStart],
            tail: block.text[tailStart...],
            invalidatedLines: hasInlineWindow ? inlineWindow.lastInvalidatedLineRange : nil
        )
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
    static func renderNode(
        for block: RenderableBlock, theme: MarkdownTheme, isPendingTableHeader: Bool = false
    ) -> (node: any RenderNode, bytesCopied: Int) {
        let (parsed, rawBytesCopied) = block.parsedAtRenderBoundary()
        if case .image(let url) = parsed.kind {
            #if canImport(os) && DEBUG
            markdownImageLog.debug("raw line: \(parsed.text, privacy: .public) -> parsed url: \(url.absoluteString, privacy: .public)")
            #endif
            return (AsyncImageNode(url: url), rawBytesCopied)
        }
        let styled = Self.style(parsed, theme: theme, isPendingTableHeader: isPendingTableHeader)
        let bytesCopied = rawBytesCopied + (block.openText == nil ? 0 : styled.content.utf8.count)
        let lifecycle: BlockLifecycle = block.isSealed ? .sealed : .hot
        if case .codeFence(let language) = parsed.kind {
            return (CodeBlockNode(
                language: language, rawCode: styled.content, font: theme.code,
                blockID: block.blockID, blockLifecycle: lifecycle
            ), bytesCopied)
        }
        if case .table(let alignments) = parsed.kind {
            return (MarkdownTableNode(
                tableRows: parsed.tableRows, alignments: alignments, font: theme.body,
                blockID: block.blockID, blockLifecycle: lifecycle
            ), bytesCopied)
        }
        if case .mathBlock = parsed.kind {
            return (MathBlockNode(
                rawTeX: styled.content, font: theme.body,
                blockID: block.blockID, blockLifecycle: lifecycle
            ), bytesCopied)
        }
        let decoration = IncrementalMarkdownParser.textDecoration(for: parsed.kind)
        return (TextNode(
            styled.content, font: styled.font, color: decoration.color, runs: styled.runs,
            leadingBarColor: decoration.barColor, leadingBarWidth: decoration.barWidth, leadingBarGap: decoration.barGap,
            ruleColor: decoration.ruleColor,
            blockID: block.blockID, blockLifecycle: lifecycle
        ), bytesCopied)
    }

    private func _renderNodes(theme: MarkdownTheme) -> [any RenderNode] {
        let blocks = renderableBlocks
        let lastIndex = blocks.count - 1
        return blocks.enumerated().map { index, block in
            let isPending = index == lastIndex && !block.isSealed && IncrementalMarkdownParser.isPendingTableCandidate(block.parsed)
            return Self.renderNode(for: block, theme: theme, isPendingTableHeader: isPending).node
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
    private var retainedNodes: [any RenderNode] = []
    private var retainedSealedCount = 0
    private var needsNodeUpdate = true
    private var documentRevision: UInt64 = 0
    private var changedStarts: [(revision: UInt64, index: Int)] = []

    public init(
        parser: IncrementalMarkdownParser = IncrementalMarkdownParser(),
        theme: MarkdownTheme = .default
    ) {
        self.parser = parser
        self.theme = theme
    }

    public func append(_ text: String) {
        guard !text.isEmpty else { return }
        let changedStart = parser.frontier
        parser.append(text)
        needsNodeUpdate = true
        documentRevision &+= 1
        changedStarts.append((documentRevision, changedStart))
        if changedStarts.count > 128 { changedStarts.removeFirst(changedStarts.count - 128) }
    }

    /// A single `RenderNode` standing in for this controller's whole document — sealed and hot
    /// blocks alike. Return this directly as an item's content (in place of `renderNodes`
    /// wrapped in a `VStackNode`) to let `FeedScrollView` splice only the changed suffix on
    /// later updates instead of re-flattening and re-diffing every block.
    ///
    ///     let message = StreamingMarkdownController()
    ///     message.append(token)
    ///     return message.documentNode()
    public func documentNode(alignment: VHorizontalAlignment = .leading, spacing: CGFloat = 8) -> RetainedDocumentNode {
        RetainedDocumentNode(
            documentID: ObjectIdentifier(self), revision: documentRevision,
            alignment: alignment, spacing: spacing, controller: self
        )
    }

    /// Returns the current changed suffix when `since` is still in the retained revision
    /// window. A nil result asks the caller to rebuild through the ordinary DSL path.
    /// `internal` — only `RetainedDocumentNode` calls this; nothing crosses Layer 1's public
    /// surface through it.
    func changedSuffix(since revision: UInt64?) -> (startBlock: Int, blocks: [any RenderNode])? {
        guard let revision else { return (0, renderNodes) }
        guard revision < documentRevision,
              let first = changedStarts.first,
              revision >= first.revision - 1 else { return nil }
        let start = changedStarts.lazy.filter { $0.revision > revision }.map(\.index).min() ?? 0
        return (start, Array(renderNodes.dropFirst(start)))
    }

    /// Same shape/order as `IncrementalMarkdownParser.renderNodes`. Sealed + cached -> returned
    /// as-is. Everything else is built via `style(_:)` and, if sealed, cached.
    public var renderNodes: [any RenderNode] {
        guard needsNodeUpdate else { return retainedNodes }
        let sealedCount = parser.sealedBlocks.count
        let blockCount = sealedCount + parser.hotBlocksState.count
        let start = min(retainedSealedCount, sealedCount, retainedNodes.count)
        retainedNodes.removeSubrange(start..<retainedNodes.count)
        retainedNodes.reserveCapacity(blockCount)
        for index in start..<blockCount {
            let block = parser.renderableBlock(at: index)
            _testHooks.handoffBytesCopiedTotal += block.openText?.bytesCopied ?? 0
            if block.isSealed, let cached = sealedNodes[block.blockID] {
                retainedNodes.append(cached)
                continue
            }
            _testHooks.styleCount += 1
            let isPending = index == blockCount - 1 && !block.isSealed && IncrementalMarkdownParser.isPendingTableCandidate(block.parsed)
            let rendered = IncrementalMarkdownParser.renderNode(for: block, theme: theme, isPendingTableHeader: isPending)
            _testHooks.renderBoundaryBytesCopiedTotal += rendered.bytesCopied
            if block.isSealed {
                sealedNodes[block.blockID] = rendered.node
            }
            retainedNodes.append(rendered.node)
        }
        retainedSealedCount = sealedCount
        needsNodeUpdate = false
        return retainedNodes
    }

    /// Stored test-only observability state. Always present (no XCTest guard) — production code
    /// (`renderNodes`) references it unconditionally. See `StreamingMarkdownControllerTestHooks`
    /// in StreamingMarkdownText+TestHooks.swift.
    let _testHooks = StreamingMarkdownControllerTestHooks()
}

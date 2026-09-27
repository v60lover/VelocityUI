// StreamingMarkdownTextTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-zuot: the Layer-1 DSL bridge from `IncrementalMarkdownParser`'s current
/// block state to a renderable node tree (`renderNodes`, `RenderNodeBuilder.buildExpression`
/// overload, `Equatable` conformance). Pure — no UIKit, runs on plain `swift test`.
final class StreamingMarkdownTextTests: XCTestCase {

    // MARK: - renderNodes shape

    func testRenderNodes_CountMatchesSealedPlusHotBlockCount() {
        var parser = IncrementalMarkdownParser()
        parser.append("# Title\n\nFirst paragraph.\n\nSecond ")

        let expectedCount = parser.sealedBlocks.count + parser.hotBlocksState.count
        XCTAssertEqual(parser.renderNodes.count, expectedCount)
        XCTAssertGreaterThan(expectedCount, 1, "Precondition: fixture must have produced more than one block")
    }

    func testRenderNodes_EmptyParser_IsEmpty() {
        let parser = IncrementalMarkdownParser()
        XCTAssertTrue(parser.renderNodes.isEmpty)
    }

    // MARK: - Content parity with blockList (the two representations must never diverge)

    /// `renderNodes` (Layer 1 `TextNode`) and `blockList(itemID:width:)` (Layer 2/3 `Block`)
    /// both route through the same `style(_:)` helper — this pins that they always agree on
    /// content, for every block kind the parser can classify.
    func testRenderNodes_ContentMatchesBlockList_ForEveryBlockKind() {
        var parser = IncrementalMarkdownParser()
        parser.append(
            "# Heading\n\n" +
            "A plain paragraph.\n\n" +
            "```swift\nlet x = 1\n```\n\n" +
            "- first item\n" +
            "- second item\n\n" +
            "> a quote\n\n" +
            "| a | b |\n|---|---|\n| 1 | 2 |\n\n"
        )

        let nodes = parser.renderNodes
        let blocks = parser.blockList(itemID: "msg", width: 300)
        XCTAssertEqual(nodes.count, blocks.count, "Precondition: same block count on both sides")
        XCTAssertGreaterThan(blocks.count, 5, "Precondition: fixture must exercise every block kind")

        var sawCodeBlock = false
        for (node, block) in zip(nodes, blocks) {
            // A fenced code block gets a dedicated CodeBlockNode in renderNodes
            // (VelocityUI-oz5q.1), but blockList is a separate legacy construction path this
            // bead intentionally leaves untouched — it still renders the fence as plain .text.
            // The two representations diverging for THIS ONE block kind is expected, not a bug.
            if let codeNode = node as? CodeBlockNode {
                sawCodeBlock = true
                XCTAssertEqual(codeNode.language, "swift")
                XCTAssertEqual(codeNode.rawCode, "let x = 1")
                continue
            }
            // A grouped table block gets a dedicated MarkdownTableNode (VelocityUI-8ge8.5),
            // same carve-out as the code fence above — blockList's separate legacy path still
            // renders the table as plain .text, so the two representations are expected to
            // diverge for this block kind too.
            if node is MarkdownTableNode {
                continue
            }
            guard let textNode = node as? TextNode else {
                return XCTFail("every non-code renderNodes entry must be a TextNode")
            }
            guard case .text(let descriptor) = block.fragment.content else {
                return XCTFail("every blockList entry in this fixture must be a text fragment")
            }
            XCTAssertEqual(textNode.content, descriptor.content)
            XCTAssertEqual(textNode.font.size, descriptor.font.size)
            XCTAssertEqual(textNode.font.weight, descriptor.font.weight)
        }
        XCTAssertTrue(sawCodeBlock, "Precondition: fixture must include a code fence")
    }

    /// VelocityUI-qmx5: `renderNodes` (flattened through `flatten()` into `TextDescriptor.runs`) and
    /// `blockList(itemID:width:)` must agree on inline styling (bold/italic/code/strike/link), not
    /// just plain content — the second half of the parity fzvf.2 established for the plain-text path.
    @MainActor
    func testRenderNodes_RunsMatchBlockList_ForInlineStyledMarkdown() {
        var parser = IncrementalMarkdownParser()
        parser.append(
            "**bold** _italic_ `code` ~~strike~~ [link](https://example.com)\n\n"
        )

        let root = VStackNode { parser.renderNodes }
        let table = flatten(root, itemID: "msg")
        let blocks = parser.blockList(itemID: "msg", width: 300)

        let flattenedRuns: [[TextRun]] = table.children(of: 0).compactMap { index in
            guard case .text(let d) = table.nodes[index] else { return nil }
            return d.runs
        }
        let blockRuns: [[TextRun]] = blocks.compactMap { block in
            guard case .text(let d) = block.fragment.content else { return nil }
            return d.runs
        }

        XCTAssertEqual(flattenedRuns.count, blockRuns.count, "Precondition: same block count on both sides")
        XCTAssertFalse(flattenedRuns.allSatisfy(\.isEmpty), "Precondition: fixture must actually produce styled runs")
        XCTAssertEqual(flattenedRuns, blockRuns)
    }

    // MARK: - Equatable

    func testEquatable_SameAppendHistory_AreEqual() {
        var a = IncrementalMarkdownParser()
        var b = IncrementalMarkdownParser()
        a.append("Hello ")
        a.append("world\n\n")
        b.append("Hello ")
        b.append("world\n\n")
        XCTAssertEqual(a, b)
    }

    func testEquatable_DivergentAppendHistory_AreNotEqual() {
        var a = IncrementalMarkdownParser()
        var b = IncrementalMarkdownParser()
        a.append("Hello world\n\n")
        b.append("Goodbye world\n\n")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Flatten integration: shape flatBlocks(for:itemID:width:) recognizes

    /// `VStackNode(alignment:spacing:) { parser.renderNodes }` must flatten into a root `.vstack`
    /// whose DIRECT children are all `.text` leaves — the exact shape
    /// `FeedScrollView.flatBlocks(for:itemID:width:)` requires (see its doc: "no nesting, no
    /// hstack/zstack"). This is what makes the existing, unmodified C3 bind site pick up parser
    /// output for free.
    @MainActor
    func testFlatten_StreamingMarkdownVStack_ProducesFlatLeafShape() {
        var parser = IncrementalMarkdownParser()
        parser.append("# Title\n\nFirst paragraph.\n\nSecond ")

        let root = VStackNode(alignment: .leading, spacing: 8) {
            parser.renderNodes
        }
        let table = flatten(root, itemID: "msg")

        guard case .vstack = table.nodes[0] else {
            return XCTFail("root must be a vstack")
        }
        let childIndices = table.children(of: 0)
        XCTAssertEqual(childIndices.count, table.nodes.count - 1, "every node besides the root must be a direct child — no nesting")
        XCTAssertEqual(childIndices.count, parser.renderNodes.count)
        for index in childIndices {
            guard case .text = table.nodes[index] else {
                return XCTFail("every direct child must be a .text leaf")
            }
        }
    }

    // MARK: - StreamingMarkdownController: memoized renderNodes (VelocityUI-re12)

    /// 100 sealed blocks, then a token appended to the hot tail: re-reading `renderNodes` must
    /// only style the hot block.
    @MainActor
    func testStreamingMarkdownController_AppendingToHotTail_OnlyRestylesTheHotBlock() {
        let message = StreamingMarkdownController()
        for i in 0..<100 {
            message.append("Paragraph \(i) content.\n\n")
        }
        message.append("Growing tail")
        _ = message.renderNodes // first read: derives + caches everything sealed so far

        XCTAssertGreaterThanOrEqual(message.parser.frontier, 100, "Precondition: fixture must have sealed ~100 blocks")
        XCTAssertEqual(message.parser.hotBlocksState.count, 1, "Precondition: exactly one open hot block")

        let callCountBefore = message._styleCallCount
        message.append(" more")
        _ = message.renderNodes
        let callCountAfter = message._styleCallCount

        XCTAssertEqual(
            callCountAfter - callCountBefore, 1,
            "appending to the hot tail must re-style exactly the hot block, not any sealed one"
        )
    }

    /// A newly-sealed block styles once, then serves from cache on every later read.
    @MainActor
    func testStreamingMarkdownController_NewlySealedBlock_StylesOnceThenCaches() {
        let message = StreamingMarkdownController()
        message.append("First paragraph")
        _ = message.renderNodes // still hot: rebuilt, not cached

        message.append("\n\n") // seals the paragraph above; opens nothing yet
        let callCountBeforeSeal = message._styleCallCount
        _ = message.renderNodes // this read must style the newly-sealed block once
        XCTAssertEqual(message._styleCallCount - callCountBeforeSeal, 1)

        let callCountAfterSeal = message._styleCallCount
        _ = message.renderNodes
        _ = message.renderNodes
        XCTAssertEqual(message._styleCallCount - callCountAfterSeal, 0, "a cached sealed block must never re-style")
    }

    /// Cached output must match what an uncached derivation would produce.
    @MainActor
    func testStreamingMarkdownController_CachedNode_MatchesUncachedParserOutput() {
        let message = StreamingMarkdownController()
        message.append("# Heading\n\n**bold** and *italic* text.\n\n")
        message.append("still hot")

        let cachedNodes = message.renderNodes // populates the cache
        _ = message.renderNodes // second read must hit the cache for sealed blocks
        let referenceNodes = message.parser.renderNodes // uncached, always-rederived baseline

        XCTAssertEqual(cachedNodes.count, referenceNodes.count)
        for (cached, reference) in zip(cachedNodes, referenceNodes) {
            guard let cachedText = cached as? TextNode, let referenceText = reference as? TextNode else {
                return XCTFail("every entry must be a TextNode")
            }
            XCTAssertEqual(cachedText.content, referenceText.content)
            XCTAssertEqual(cachedText.font.size, referenceText.font.size)
            XCTAssertEqual(cachedText.font.weight, referenceText.font.weight)
            XCTAssertEqual(cachedText.runs, referenceText.runs)
            XCTAssertEqual(cachedText.blockID, referenceText.blockID)
            XCTAssertEqual(cachedText.blockLifecycle, referenceText.blockLifecycle)
        }
    }

    // MARK: - MarkdownTheme

    /// The default theme's headings are bold, step down gently, and never render smaller than
    /// the 20pt body — the fix for the old ramp that jumped at h2 and shrank h4–h6 below body.
    func testDefaultTheme_HeadingsAreBoldAndNeverSmallerThanBody() {
        let bodySize = MarkdownTheme.default.body.size
        XCTAssertEqual(bodySize, 20)
        XCTAssertEqual(MarkdownTheme.default.body.weight, VFontDescriptor.regularWeight)

        XCTAssertEqual(MarkdownTheme.default.heading(level: 1).size, 28)
        XCTAssertEqual(MarkdownTheme.default.heading(level: 2).size, 24)
        XCTAssertEqual(MarkdownTheme.default.heading(level: 3).size, 22)
        XCTAssertEqual(MarkdownTheme.default.heading(level: 4).size, 20)

        var previous = CGFloat.greatestFiniteMagnitude
        for level in 1...6 {
            let font = MarkdownTheme.default.heading(level: level)
            XCTAssertEqual(font.weight, VFontDescriptor.boldWeight, "h\(level) must be bold")
            XCTAssertGreaterThanOrEqual(font.size, bodySize, "h\(level) must not be smaller than body")
            XCTAssertLessThanOrEqual(font.size, previous, "heading sizes must not grow as level deepens")
            previous = font.size
        }
    }

    /// An unmapped heading level falls back to `headingFallback` instead of crashing.
    func testTheme_UnmappedHeadingLevel_UsesFallback() {
        var theme = MarkdownTheme.default
        theme.headings[2] = nil
        XCTAssertEqual(theme.heading(level: 2), theme.headingFallback)
    }

    /// A custom theme actually changes the styled font for `##` — the whole point of the API.
    func testCustomTheme_RetunesHeadingFont() {
        var theme = MarkdownTheme.default
        theme.headings[2] = VFontDescriptor(size: 21, weight: VFontDescriptor.regularWeight)

        var parser = IncrementalMarkdownParser()
        parser.append("## Retuned heading\n\n")

        let nodes = parser.renderNodes(theme: theme)
        guard let heading = nodes.first as? TextNode else {
            return XCTFail("first block must be the heading TextNode")
        }
        XCTAssertEqual(heading.font.size, 21)
        XCTAssertEqual(heading.font.weight, VFontDescriptor.regularWeight)
    }

    /// A themed `renderNodes(theme:)` and a themed `blockList(itemID:width:theme:)` must still
    /// agree on font — measurement and render can't diverge just because a theme was supplied.
    func testThemedRenderNodesAndBlockList_AgreeOnFont() {
        var theme = MarkdownTheme.default
        theme.headings[2] = VFontDescriptor(size: 21, weight: VFontDescriptor.boldWeight)

        var parser = IncrementalMarkdownParser()
        parser.append("## Heading\n\nBody paragraph.\n\n")

        let nodes = parser.renderNodes(theme: theme)
        let blocks = parser.blockList(itemID: "msg", width: 300, theme: theme)
        XCTAssertEqual(nodes.count, blocks.count)

        for (node, block) in zip(nodes, blocks) {
            guard let textNode = node as? TextNode,
                  case .text(let descriptor) = block.fragment.content else {
                return XCTFail("every entry must be a text node/fragment")
            }
            XCTAssertEqual(textNode.font.size, descriptor.font.size)
            XCTAssertEqual(textNode.font.weight, descriptor.font.weight)
        }
    }

    /// The controller styles against the theme it was constructed with.
    @MainActor
    func testStreamingMarkdownController_UsesConstructedTheme() {
        var theme = MarkdownTheme.default
        theme.headings[2] = VFontDescriptor(size: 21, weight: VFontDescriptor.regularWeight)
        let message = StreamingMarkdownController(theme: theme)
        message.append("## Heading\n\n")

        guard let heading = message.renderNodes.first as? TextNode else {
            return XCTFail("first block must be the heading TextNode")
        }
        XCTAssertEqual(heading.font.size, 21)
        XCTAssertEqual(heading.font.weight, VFontDescriptor.regularWeight)
    }

    // MARK: - Borrowed open text handoff

    func testRenderableBlocks_OpenParagraphHeadingAndQuoteExposeBorrowedSlices() throws {
        let fixtures = ["# Heading", "> quoted text", "plain paragraph"]

        for source in fixtures {
            var parser = IncrementalMarkdownParser()
            parser.append(source)

            let block = try XCTUnwrap(parser.renderableBlocks.last)
            let handoff = try XCTUnwrap(block.openText, "Missing open handoff for \(source), kind \(block.parsed.kind), inline kind \(String(describing: parser.inlineWindow.kind))")
            XCTAssertEqual(
                String(handoff.frozen) + String(handoff.unsettled) + String(handoff.tail),
                block.parsed.text
            )
            XCTAssertEqual(handoff.frozen.utf8.count + handoff.unsettled.utf8.count + handoff.tail.utf8.count,
                           block.parsed.text.utf8.count)
            XCTAssertEqual(handoff.bytesCopied, 0)
        }
    }

    @MainActor
    func testStreamingMarkdownController_LongCharacterStreamCopiesOnlyAtRenderBoundary() {
        let controller = StreamingMarkdownController()
        let source = String(repeating: "plain line\n", count: 24) + "tail"
        var expectedRenderBytes = 0

        for character in source {
            controller.append(String(character))
            // R3 fix: render boundary no longer re-flattens already-flat block text, so this is
            // styled content only, not raw-flatten + styled.
            let nodes = controller.renderNodes
            expectedRenderBytes += (nodes.last as? TextNode)?.content.utf8.count ?? 0
        }

        XCTAssertEqual(controller._handoffBytesCopiedTotal, 0,
                       "borrowed slices must not copy bytes when the DSL handoff is built")
        XCTAssertEqual(controller._renderBoundaryBytesCopiedTotal, expectedRenderBytes,
                       "the named render boundary must account for each flattened open block")
        let handoff = controller.parser.renderableBlocks.last?.openText
        XCTAssertNotNil(handoff)
        XCTAssertGreaterThan(handoff?.frozen.utf8.count ?? 0, 0)
        XCTAssertEqual(handoff?.tail, "tail")

        controller.append("\n\n")
        _ = controller.renderNodes
        let afterSeal = controller._renderBoundaryBytesCopiedTotal
        _ = controller.renderNodes
        XCTAssertEqual(controller._renderBoundaryBytesCopiedTotal, afterSeal,
                       "reusing sealed cached nodes must not flatten their text again")
    }

    func testRenderableBlocks_RollbackInvalidatedRangeReachesOpenTextHandoff() throws {
        let source = "`code begins\n" + String(repeating: "plain line\n", count: 19) + "` closes here"
        var parser = IncrementalMarkdownParser()
        for character in source { parser.append(String(character)) }

        XCTAssertEqual(parser.inlineRollbackCount, 1, "Precondition: the late closer must roll back a frozen prefix")
        let block = try XCTUnwrap(parser.renderableBlocks.last)
        let handoff = try XCTUnwrap(block.openText)
        XCTAssertEqual(handoff.invalidatedLines, 0..<21)
        XCTAssertEqual(
            String(handoff.frozen) + String(handoff.unsettled) + String(handoff.tail),
            block.parsed.text
        )
    }

    @MainActor
    func testStreamingMarkdownController_OpenTextContentAndRunsMatchBlockList() {
        let controller = StreamingMarkdownController()
        controller.append("**bold** _italic_ `code` ~~strike~~ [link](https://example.com)\n\n")
        controller.append("still **growing**")

        let nodes = controller.renderNodes
        let blocks = controller.parser.blockList(itemID: "msg", width: 300)
        XCTAssertEqual(nodes.count, blocks.count)

        for (node, block) in zip(nodes, blocks) {
            guard let textNode = node as? TextNode,
                  case .text(let descriptor) = block.fragment.content else {
                return XCTFail("each fixture block must render as a text node and text fragment")
            }
            XCTAssertEqual(textNode.content, descriptor.content)
            XCTAssertEqual(textNode.runs, descriptor.runs)
        }
    }
}

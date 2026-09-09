// IncrementalMarkdownParserImageTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Markdown image block support: `![alt](url)` alone on its line seals as a block-level image
/// node, not a paragraph. Inline images in paragraph text degrade to literal "!" + link (out of scope).
final class IncrementalMarkdownParserImageTests: XCTestCase {

    // MARK: - Block kind: standalone image line must parse as .image, not .paragraph

    func testImageLine_ParsedBlockKind_SealsAsImageNotParagraph() {
        var parser = IncrementalMarkdownParser()
        parser.append("![alt](https://example.com/y.png)\n\n")

        guard parser.sealedBlocks.count > 0 else {
            return XCTFail("image line must seal a block")
        }
        guard case .image(let url) = parser.sealedBlocks[0].kind else {
            return XCTFail("standalone image line must parse as .image, not .paragraph")
        }
        XCTAssertEqual(url, URL(string: "https://example.com/y.png"))
    }

    // MARK: - BlockList: image blocks carry FragmentContent.image with matching URL

    func testImageBlock_BlockList_CarriesImageDescriptorWithMatchingURL() {
        var parser = IncrementalMarkdownParser()
        parser.append("![alt](https://example.com/y.png)\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)

        guard blocks.count > 0 else {
            return XCTFail("blockList must produce at least one block")
        }
        guard case .image(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("image block must render as FragmentContent.image")
        }
        XCTAssertEqual(descriptor.url, URL(string: "https://example.com/y.png"))
    }

    // MARK: - RenderNodes: image blocks produce AsyncImageNode with matching URL

    @MainActor
    func testImageBlock_RenderNodes_ProducesAsyncImageNodeWithMatchingURL() {
        var parser = IncrementalMarkdownParser()
        parser.append("![alt](https://example.com/y.png)\n\n")
        let nodes = parser.renderNodes

        guard nodes.count > 0 else {
            return XCTFail("renderNodes must produce at least one node")
        }
        guard let imageNode = nodes[0] as? AsyncImageNode else {
            return XCTFail("image block must render as AsyncImageNode, not TextNode")
        }
        XCTAssertEqual(imageNode.url, URL(string: "https://example.com/y.png"))
    }

    // MARK: - Regression: inline ![alt](url) degrades to literal "!" + link, not image

    func testInlineImage_InlineRuns_DegradesToLiteralExclamationPlusLink() {
        let runs = inlineRuns("see ![x](https://example.com/y) here")

        // "!" has no special handling in inlineRuns, so it merges into the surrounding literal
        // text ("see !") rather than becoming its own run — the invariant under test is that
        // this merged run carries no link style, not that "!" is isolated.
        let literalRuns = runs.filter { $0.text.contains("!") }
        guard !literalRuns.isEmpty else {
            return XCTFail("inline image must degrade to literal text containing '!'")
        }
        let exclamation = literalRuns[0]
        XCTAssertFalse(exclamation.style.contains(.link), "literal '!' text must not carry link style")

        // Find the "x" run — it must carry .link style and point to the URL.
        let xRuns = runs.filter { $0.text == "x" }
        guard !xRuns.isEmpty else {
            return XCTFail("link text 'x' must appear as a separate run")
        }
        let linkRun = xRuns[0]
        XCTAssertTrue(linkRun.style.contains(.link), "'x' must carry .link style")
        XCTAssertEqual(linkRun.url, "https://example.com/y")
    }

    // MARK: - Streaming: incomplete image line stays in paragraph until closed

    func testStreamingImageLine_IncompleteURLParsesAsParagraph_CompletesParsesAsImage() {
        var parser = IncrementalMarkdownParser()

        // Append the URL in two pieces — closing `)` is missing on first append.
        parser.append("![alt](https://example.com/y")

        // The incomplete line must stay hot as a paragraph, not yet recognized as an image.
        guard parser.hotBlocksState.count > 0 else {
            return XCTFail("incomplete image must remain in hot blocks as open paragraph")
        }
        guard case .paragraph = parser.hotBlocksState[0].kind else {
            return XCTFail("incomplete image URL must not yet parse as .image block")
        }

        // Complete the URL and close the block.
        parser.append(".png)\n\n")

        // Now it must be sealed as an image.
        guard parser.sealedBlocks.count > 0 else {
            return XCTFail("completed image line must seal a block")
        }
        guard case .image(let url) = parser.sealedBlocks[0].kind else {
            return XCTFail("completed image line must parse as .image")
        }
        XCTAssertEqual(url, URL(string: "https://example.com/y.png"))
    }
}
#endif

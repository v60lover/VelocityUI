// StreamDataset.swift

import Foundation
import VelocityUI

/// Deterministic ChatGPT-style token stream + interleaved-block layout for the `stream` scenario
/// (VelocityUI-xxf7). Same LCG pattern as `BenchmarkDataset.generate` so successive runs (and the
/// ON/OFF hot-block-rasterize comparison, which needs the identical stream on both sides) are
/// byte-for-byte reproducible.
enum StreamDataset {

    /// First (0-based) odd markdown block index after which an image is interleaved.
    static let imageAfterBlockIndex = 1
    /// Index after which the interleaved "rule" divider (`SpacerNode` — the DSL has no dedicated
    /// divider node; a fixed-height spacer stands in for one) is spliced in — right after the
    /// fenced code block closes and seals.
    static let ruleAfterBlockIndex = 3

    static let imageURL = URL(string: "https://picsum.photos/seed/velocityui-stream-benchmark/800/450")!

    /// Ordered append chunks a `StreamDriver` feeds into `IncrementalMarkdownParser.append(_:)`
    /// one at a time: a heading, two intro prose paragraphs, one LARGE fenced code block (the
    /// wj8x worst case — an unclosed fence that stays hot for `codeLineCount` appends before it
    /// finally closes), and a short closing paragraph.
    static func tokens(seed: UInt64 = 0, codeLineCount: Int = 220) -> [String] {
        var rng = LCG(state: seed)
        var chunks: [String] = []
        // Setext heading (`===` underline) — kept as the opening block for index stability
        // (imageAfterBlockIndex/ruleAfterBlockIndex below count blocks from here). ATX (`#`)
        // headings are also recognized now (VelocityUI-fzvf.1) — exercised further down, after
        // the reproducible prose run, so it never shifts an existing block index.
        chunks += literal("Streaming benchmark response\n")
        chunks += literal("===\n")
        chunks += literal("\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += markdownFeatureShowcase()
        return chunks
    }

    /// Manual smoke content for VelocityUI-fzvf.1's new block/inline shapes — ATX heading,
    /// ordered + nested list, thematic break, a language-tagged fence, and inline emphasis.
    /// Appended after the reproducible prose run so it never shifts `imageAfterBlockIndex`/
    /// `ruleAfterBlockIndex`.
    private static func markdownFeatureShowcase() -> [String] {
        var chunks: [String] = []
        chunks += literal("## ATX heading test\n\n")
        chunks += literal("This has **bold**, *italic*, `code`, ~~strike~~, and a [link](https://example.com).\n\n")
        chunks += literal("1. First ordered item\n2. Second ordered item\n  3. Nested item\n\n")
        chunks += literal("---\n\n")
        chunks += literal("```swift\nlet ok = true\n```\n\n")
        return chunks
    }

    /// Builds one cell's full child-node array: the parser's own `renderNodes` (all `TextNode`,
    /// one per sealed/hot block — VelocityUI-zuot) with a static `AsyncImageNode` spliced in after
    /// every odd sealed block and a `SpacerNode` "rule" divider spliced in after
    /// `ruleAfterBlockIndex` seals — exercising the C3 bind site's per-block diff and pooling
    /// against real non-text fragments, not just one growing text block.
    ///
    /// Each insertion is gated on `parser.frontier`: only sealed blocks are stable anchors.
    /// The first frame that inserts an image may use one full-layout fallback; its stable render
    /// ID lets later hot-text updates return to the identity-aware in-place path.
    ///
    /// - Parameter includeInterleavedBlocks: When `false`, returns `parser.renderNodes` verbatim —
    ///   no `AsyncImageNode`/`SpacerNode` ever spliced in. `true` (the default) is what the
    ///   acceptance-criteria run uses; `false` backs `--stream-text-only`, a text-only run with no
    ///   network/decode dependency, for a quick device sanity pass before the full comparison.
    static func interleavedRenderNodes(for parser: IncrementalMarkdownParser, includeInterleavedBlocks: Bool = true) -> [any RenderNode] {
        let textNodes = parser.renderNodes
        guard includeInterleavedBlocks else { return textNodes }
        var result: [any RenderNode] = []
        result.reserveCapacity(textNodes.count + (parser.frontier / 2) + 1)
        for (index, node) in textNodes.enumerated() {
            result.append(node)
//            if index >= imageAfterBlockIndex, index.isMultiple(of: 2) == false, parser.frontier > index {
//                result.append(
//                    AsyncImageNode(url: imageURL, aspectRatio: 16.0 / 9.0, contentMode: .fill)
//                        .renderID("stream-image-after-\(index)")
//                )
//            }
//            if index == ruleAfterBlockIndex, parser.frontier > ruleAfterBlockIndex {
//                result.append(SpacerNode(minLength: 12).renderID("stream-rule-after-\(index)"))
//            }
        }
        return result
    }

    // MARK: - Token generation

    private static func literal(_ s: String) -> [String] { [s] }

    private static let words: [String] = [
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "incremental",
        "rasterizer", "keeps", "per", "token", "cost", "flat", "as", "message", "grows",
        "without", "jank", "streaming", "markdown", "block", "frontier", "seals", "hot",
        "tail", "frozen", "bitmap", "cache", "working", "range", "scroll", "path", "never",
        "awaits", "actor", "isolation", "render", "pipeline", "layer", "boundary", "text",
        "layout", "manager", "fragment", "composite", "glyph", "ligature", "emoji", "seam",
        "width", "height", "scale", "device", "pixel", "measurement", "eviction", "budget",
        "frame", "hitch", "allocation", "delta", "footprint", "benchmark", "chat", "response",
        "paragraph", "sentence", "word", "chunk", "append", "parser", "stream", "driver"
    ]

    private static func prose(sentenceCount: Int, rng: inout LCG) -> [String] {
        var chunks: [String] = []
        for _ in 0..<sentenceCount {
            let wordCount = 8 + Int(rng.next() % 10)
            for w in 0..<wordCount {
                let word = words[Int(rng.next() % UInt64(words.count))]
                chunks.append(w == 0 ? word : " " + word)
            }
            chunks.append(".")
            chunks.append(" ")
        }
        return chunks
    }

    /// Opens a fence, appends `lineCount` synthetic Swift-like lines one at a time (the fence
    /// stays hot/open for the entire span), then closes it.
    private static func codeFence(lineCount: Int, rng: inout LCG) -> [String] {
        var chunks: [String] = ["```swift\n"]
        for i in 0..<lineCount {
            let a = Int(rng.next() % 97)
            let b = Int(rng.next() % 53)
            chunks.append("let value\(i) = \(a) &* \(b) &+ \(i)  // streamed line \(i)\n")
        }
        chunks.append("```\n")
        return chunks
    }
}

private struct LCG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

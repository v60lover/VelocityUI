// StreamDataset.swift

import Foundation
import VelocityUI

/// Deterministic ChatGPT-style token stream + interleaved-block layout for the `stream` scenario
/// (VelocityUI-xxf7). Same LCG pattern as `BenchmarkDataset.generate` so successive runs (and the
/// ON/OFF hot-block-rasterize comparison, which needs the identical stream on both sides) are
/// byte-for-byte reproducible.
enum StreamDataset {

    /// Index (0-based, in the parser's combined sealed+hot block list) of the block after which
    /// the interleaved `AsyncImageNode` is spliced in — once the two intro paragraphs have sealed,
    /// before the fenced code block opens.
    static let imageAfterBlockIndex = 0
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
        // Setext heading (`===` underline) — the parser has no ATX (`#`) heading recognition
        // (see `IncrementalMarkdownParser.parseTail`'s `isSetextUnderline`), so this is the only
        // shape that actually classifies as `.heading` rather than a plain paragraph.
        chunks += literal("Streaming benchmark response\n")
        chunks += literal("===\n")
        chunks += literal("\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 10, rng: &rng)
//        chunks += literal("\n\n")
//        chunks += codeFence(lineCount: codeLineCount, rng: &rng)
//        chunks += literal("\n\n")
        return chunks
    }

    /// Builds one cell's full child-node array: the parser's own `renderNodes` (all `TextNode`,
    /// one per sealed/hot block — VelocityUI-zuot) with a static `AsyncImageNode` spliced in after
    /// `imageAfterBlockIndex` seals and a `SpacerNode` "rule" divider spliced in after
    /// `ruleAfterBlockIndex` seals — exercising the C3 bind site's per-block diff and pooling
    /// against real non-text fragments, not just one growing text block.
    ///
    /// Gated on `parser.frontier` (not raw block count): a block only becomes a stable insertion
    /// anchor once it's provably sealed (parser contract — sealed blocks never move again), so the
    /// interleaved node's own position in the flattened list is stable from the frame it first
    /// appears. The insertion frame itself IS a one-time position shift for every later block —
    /// `applyInPlaceBlockDiff`'s per-block diff treats that shifted position as a changed/non-text
    /// sealed entry it can't freeze (image/geometry reuse lives in ImageActor's decode cache, not
    /// this diff — see `FeedScrollView.applyInPlaceBlockDiff`'s doc) and safely falls back to a
    /// full re-layout for that ONE update, same for both ON and OFF hot-rasterize runs, before
    /// steady state (unchanged-by-position-and-hash) resumes.
    ///
    /// - Parameter includeInterleavedBlocks: When `false`, returns `parser.renderNodes` verbatim —
    ///   no `AsyncImageNode`/`SpacerNode` ever spliced in. `true` (the default) is what the
    ///   acceptance-criteria run uses; `false` backs `--stream-text-only`, a text-only run with no
    ///   network/decode dependency, for a quick device sanity pass before the full comparison.
    static func interleavedRenderNodes(for parser: IncrementalMarkdownParser, includeInterleavedBlocks: Bool = true) -> [any RenderNode] {
        let textNodes = parser.renderNodes
        guard includeInterleavedBlocks else { return textNodes }
        var result: [any RenderNode] = []
        result.reserveCapacity(textNodes.count + 2)
        for (index, node) in textNodes.enumerated() {
            result.append(node)
            if index == imageAfterBlockIndex, parser.frontier > imageAfterBlockIndex {
                result.append(AsyncImageNode(url: imageURL, aspectRatio: 16.0 / 9.0, contentMode: .fill))
            }
            if index == ruleAfterBlockIndex, parser.frontier > ruleAfterBlockIndex {
                result.append(SpacerNode(minLength: 12))
            }
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

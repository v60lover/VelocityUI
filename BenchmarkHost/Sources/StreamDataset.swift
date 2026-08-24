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
    /// one at a time. Reads like a real chat answer, not a word-salad stress load: a setext
    /// title, several `##`-headed sections of real prose, an inline-styled paragraph plus a
    /// list and a rule, and one LARGE fenced code block (the wj8x worst case — an unclosed
    /// fence that stays hot for `codeLineCount` appends before it finally closes).
    static func tokens(seed: UInt64 = 0, codeLineCount: Int = 220) -> [String] {
        var rng = LCG(state: seed)
        var chunks: [String] = []
        // Setext heading (`===` underline) — kept as the opening block for index stability
        // (imageAfterBlockIndex/ruleAfterBlockIndex below count blocks from here). ATX (`#`)
        // headings are also recognized now (VelocityUI-fzvf.1).
        chunks += literal("Streaming benchmark response\n")
        chunks += literal("===\n")
        chunks += literal("\n")
        chunks += literal("## Why token-by-token rendering doesn't jank\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 10, rng: &rng)
        chunks += literal("\n\n")
        chunks += markdownFeatureShowcase()
        chunks += prose(sentenceCount: 15, rng: &rng)
        chunks += literal("\n")
        chunks += literal("## A single append, traced\n\n")
        chunks += literal("Here's the shape of one `append(_:)` call while a fence is still open — a line streams in, the fence stays hot, and nothing before it moves:\n\n")
        chunks += codeFence(lineCount: codeLineCount, rng: &rng)
        chunks += literal("\n")
        chunks += prose(sentenceCount: 20, rng: &rng)
        chunks += literal("\n\n")
        chunks += literal("## Trade-offs\n\n")
        chunks += prose(sentenceCount: 25, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 10, rng: &rng)
        chunks += literal("\n\n")
        chunks += literal("## What this means while scrolling\n\n")
        chunks += prose(sentenceCount: 15, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 20, rng: &rng)
        chunks += literal("\n\n")
        chunks += literal("## Summary\n\n")
        chunks += prose(sentenceCount: 25, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 5, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 10, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 15, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 20, rng: &rng)
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 25, rng: &rng)
        chunks += literal("\n\n")
        return chunks
    }

    /// Exercises the same block/inline shapes as before (VelocityUI-fzvf.1: ATX heading,
    /// ordered + nested list, thematic break, a language-tagged fence, inline emphasis) but
    /// framed as real content instead of a "test" label, so the stream still reads as one
    /// answer end to end.
    private static func markdownFeatureShowcase() -> [String] {
        var chunks: [String] = []
        chunks += literal("## Key implementation details\n\n")
        chunks += literal("A few invariants make this possible: the *working range* is a **ring buffer**, never a `[Int: ResolvedLayout]` dictionary — a plain dictionary can't answer 'give me the next visible cell' without scanning every key. ~~A flat array indexed by position~~ almost works, but it can't grow from one end while shrinking from the other the way a ring buffer can. See the [architecture notes](https://example.com) for the rest of the invariants.\n\n")
        chunks += literal("What happens on every appended token, in order:\n\n")
        chunks += literal("1. A token lands in the parser's buffer.\n2. Only the still-open blocks are re-tokenized; sealed blocks are left untouched.\n  3. Runs that actually changed are re-styled — bold, italic, code, and link spans included.\n4. The block seals the moment its closing delimiter appears, and its bitmap is cached from then on.\n\n")
        chunks += literal("---\n\n")
        chunks += literal("```swift\nlet frontier = parser.frontier // sealed block count\n```\n\n")
        return chunks
    }

    /// Builds one cell's full child-node array: the caller's already-derived `textNodes` (all
    /// `TextNode`, one per sealed/hot block — VelocityUI-zuot) with a static `AsyncImageNode`
    /// spliced in after every odd sealed block and a `SpacerNode` "rule" divider spliced in after
    /// `ruleAfterBlockIndex` seals — exercising the C3 bind site's per-block diff and pooling
    /// against real non-text fragments, not just one growing text block.
    ///
    /// Takes `textNodes`/`frontier` rather than an `IncrementalMarkdownParser` (VelocityUI-8g6l):
    /// the caller derives `textNodes` from a `StreamingMarkdownController` so sealed blocks stay
    /// cached; calling `parser.renderNodes` in here would re-derive everything uncached on every
    /// read and defeat that caching.
    ///
    /// Each insertion is gated on `frontier`: only sealed blocks are stable anchors. The first
    /// frame that inserts an image may use one full-layout fallback; its stable render ID lets
    /// later hot-text updates return to the identity-aware in-place path.
    ///
    /// - Parameter includeInterleavedBlocks: When `false`, returns `textNodes` verbatim — no
    ///   `AsyncImageNode`/`SpacerNode` ever spliced in. `true` (the default) is what the
    ///   acceptance-criteria run uses; `false` backs `--stream-text-only`, a text-only run with no
    ///   network/decode dependency, for a quick device sanity pass before the full comparison.
    static func interleavedRenderNodes(textNodes: [any RenderNode], frontier: Int, includeInterleavedBlocks: Bool = true) -> [any RenderNode] {
        guard includeInterleavedBlocks else { return textNodes }
        var result: [any RenderNode] = []
        result.reserveCapacity(textNodes.count + (frontier / 2) + 1)
        for (index, node) in textNodes.enumerated() {
            result.append(node)
            if index >= imageAfterBlockIndex, index > 10, index % 2 == 0 {
                result.append(
                    AsyncImageNode(url: imageURL, aspectRatio: 16.0 / 9.0, contentMode: .fill)
                        .renderID("stream-image-after-\(index)")
                )
            }
//            if index == ruleAfterBlockIndex, frontier > ruleAfterBlockIndex {
//                result.append(SpacerNode(minLength: 12).renderID("stream-rule-after-\(index)"))
//            }
        }
        return result
    }

    // MARK: - Token generation

    private static func literal(_ s: String) -> [String] { [s] }

    /// A real explanation of how VelocityUI's incremental streaming renderer stays smooth,
    /// broken into standalone sentences (no trailing period — `prose` appends it) so `prose`
    /// can pick and stream them individually while keeping the whole thing readable regardless
    /// of which subset a given seed lands on.
    private static let sentences: [String] = [
        "When a chat response streams in token by token, the renderer's job is to keep every frame's cost flat, no matter how long the message has already grown",
        "Each markdown block moves through a small lifecycle: open, hot, and finally sealed once nothing can change its content anymore",
        "A block seals the moment the parser sees whatever closes it — a blank line after a paragraph, or the closing fence of a code block",
        "Only the hot tail, the handful of blocks still receiving new tokens, gets re-measured and re-rasterized on every append",
        "Everything before the frontier is frozen — its bitmap is cached, and the renderer just reuses that bitmap frame after frame",
        "That is what keeps the per-token cost flat instead of letting it grow with the length of the whole message",
        "The scroll path itself never awaits anything, so no async call ever sits between a gesture and the next frame",
        "All of the async work, decoding an image, measuring text, preparing a GIF or a video, happens off that path entirely",
        "Text never goes through a live text layer, instead the layout manager lays out each fragment once, rasterizes it to a bitmap, and hands that bitmap straight to a plain layer",
        "That sidesteps a whole category of per-frame text costs: glyph composition, ligature substitution, and emoji seam handling all happen once, at rasterization time",
        "Rounding corners works the same way, nothing gets rounded by the layer itself, rounding happens once, at decode time, by clipping the drawing context",
        "A block's identity is tracked by a stable id, so a hot paragraph that gains a few more words this frame is still recognized as the same block it was last frame",
        "That identity is what keeps the diff cheap: only blocks whose content actually changed get re-styled, everything else is served straight from the cache",
        "Under load, the hardest block to keep smooth is usually a fenced code block, because it can stay open and growing for hundreds of lines before it finally closes",
        "While a fence is still open, every appended line means one more re-measure of the whole block, so that path gets the most attention during benchmarking",
        "The moment the fence closes, the block seals, its bitmap freezes, and every later frame skips straight past it",
        "None of this changes how the message looks on screen, it only changes how much work the renderer repeats to keep drawing it",
        "A naive implementation would re-measure and re-draw the entire message on every single token, and the cost would grow without bound as the reply gets longer",
        "The incremental approach instead keeps a working range of only the blocks near the visible viewport, so cost stays bounded by what is actually on screen",
        "That working range behaves like a ring buffer rather than a plain dictionary, because a ring buffer can grow and shrink from either end without touching the middle",
        "Every image or video that streams in alongside the text gets the same treatment, it waits for its anchor block to seal before it is inserted, so nothing shifts underneath text that has not settled yet",
        "Once inserted, a piece of media keeps a stable identity of its own, so later text growth never causes it to be recreated or to flicker",
        "None of the actors doing this work share state through a global singleton, each long-lived collaborator is owned by one environment object, created once per feed",
        "That separation is also what makes the whole pipeline testable in isolation, a fake image loader can stand in for the real one without touching anything else",
        "On a real device the effect shows up as a flat frame time graph instead of a sawtooth, because no frame pays for more than the tokens that just arrived",
        "Allocation counts follow the same shape, a few small allocations per append, not a spike that scales with how much of the message has streamed in so far",
        "The eviction budget exists for the opposite case, when a message finally scrolls off screen and its cached bitmaps are no longer worth keeping around",
        "Cache eviction runs off the scroll path too, so freeing memory for an old message never competes with rendering the one currently on screen",
        "None of this is free to build, getting a stable per-token cost took careful separation between what must run synchronously and what can run anywhere else",
        "The trade-off is a bit more bookkeeping up front, one identity and one lifecycle state per block, in exchange for a render loop that never has to guess what changed",
        "A simpler design that re-derived everything from scratch on every read would have been far less code but would not have scaled past a short reply",
        "In practice, most chat messages are short enough that either approach looks fine, the difference shows up once a reply runs long or arrives quickly",
        "That is exactly the scenario this benchmark is built to stress, a long reply, streamed fast, with an oversized code block in the middle to keep the hot path hot",
        "Scrolling while a message is still streaming is the harder case, because the visible cells keep changing at the same time the content underneath them keeps growing",
        "Handling both at once is why the scroll path stays synchronous, it can react to a gesture immediately, using whatever was already measured, without waiting on the stream",
        "If scrolling ever had to await a measurement, a fast flick during a long reply would visibly stutter, which is precisely the failure mode this design avoids",
        "The same discipline extends to layer boundaries, nothing above layer one ever holds a reference to a node type from a layer below it",
        "That boundary is what lets each layer be reasoned about, and tested, without pulling in the rest of the pipeline just to check one piece of it"
    ]

    /// Streams `sentenceCount` sentences word by word (each chunk is one token append) so the
    /// content still reads as real prose while exercising the same per-word streaming path the
    /// old word-salad generator did. Rerolls once on an immediate repeat so two picks never land
    /// back to back — sentences.count is well below the total picks a long stream makes.
    private static func prose(sentenceCount: Int, rng: inout LCG) -> [String] {
        var chunks: [String] = []
        var previousIndex = -1
        for _ in 0..<sentenceCount {
            var index = Int(rng.next() % UInt64(sentences.count))
            if index == previousIndex {
                index = Int(rng.next() % UInt64(sentences.count))
            }
            previousIndex = index
            for (w, word) in sentences[index].split(separator: " ").enumerated() {
                chunks.append(w == 0 ? String(word) : " " + word)
            }
            chunks.append(".")
            chunks.append(" ")
        }
        return chunks
    }

    /// Opens a fence, appends `lineCount` synthetic Swift-like lines one at a time (the fence
    /// stays hot/open for the entire span), then closes it.
    private static func codeFence(lineCount: Int, rng: inout LCG) -> [String] {
        var chunks: [String] = ["`swift\n"]
        for i in 0..<lineCount {
            let a = Int(rng.next() % 97)
            let b = Int(rng.next() % 53)
            chunks.append("let value\(i) = \(a) &* \(b) &+ \(i)  // streamed line \(i)\n")
        }
        chunks.append("`\n")
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

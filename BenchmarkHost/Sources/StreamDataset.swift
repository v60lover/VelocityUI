// StreamDataset.swift

import Foundation
import VelocityUI

/// Deterministic ChatGPT-style token stream + interleaved-block layout for the `stream` scenario
/// (VelocityUI-xxf7). Same LCG pattern as `BenchmarkDataset.generate` so successive runs (and the
/// ON/OFF hot-block-rasterize comparison, which needs the identical stream on both sides) are
/// byte-for-byte reproducible.
enum StreamDataset {

    /// 0-based block indices (in the `tokens()` stream) where splicing in an `AsyncImageNode`
    /// actually matches what the prose right above it is describing, instead of a blind parity
    /// rule that would scatter images across unrelated paragraphs. Block 3 is the "here's a
    /// diagram of the eviction order" paragraph; block 16 is the "here's the shape of one
    /// `get(_:)` call" paragraph — see `tokens()`. Both must be recounted if blocks are added or
    /// removed above them in `tokens()`.
    static let imageAfterBlockIndices: Set<Int> = [3, 16]
    /// Index after which the interleaved "rule" divider (`SpacerNode` — the DSL has no dedicated
    /// divider node; a fixed-height spacer stands in for one) is spliced in — right after the
    /// first large fenced code block closes and seals (block 7 in `tokens()`).
    static let ruleAfterBlockIndex = 7

    // picsum.photos has been down (503s) — pulled straight from Unsplash's CDN instead.
    static let imageURL = URL(string: "https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=800&h=450&fit=crop&q=80")!

    /// Ordered append chunks a `StreamDriver` feeds into `IncrementalMarkdownParser.append(_:)`
    /// one at a time. Reads like an actual LLM chat answer to a real question ("how would you
    /// implement an LRU cache in Swift, and when would you reach for something else instead"),
    /// not a word-salad stress load: a setext title, several `##`-headed sections of real prose,
    /// an inline-styled paragraph plus a list and a rule, a diagram image, and one LARGE fenced
    /// code block (the wj8x worst case — an unclosed fence that stays hot for `codeLineCount`
    /// appends before it finally closes).
    static func tokens(seed: UInt64 = 0, codeLineCount: Int = 220) -> [String] {
        var rng = LCG(state: seed)
        var chunks: [String] = []
        // Setext heading (`===` underline) — kept as the opening block for index stability
        // (imageAfterBlockIndex/ruleAfterBlockIndex below count blocks from here). ATX (`#`)
        // headings are also recognized now (VelocityUI-fzvf.1).
        chunks += literal("Implementing an LRU cache in Swift\n")
        chunks += literal("===\n")
        chunks += literal("\n")
        chunks += literal("## How an LRU cache works\n\n")
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 10, rng: &rng)
        chunks += literal("\n\n")
        chunks += literal("Here's a diagram of the eviction order — the tail is always the least recently used entry:\n\n")
        chunks += literal("\n\n")
        chunks += prose(sentenceCount: 10, rng: &rng)
        chunks += literal("\n\n")
        chunks += literal("## The implementation\n\n")
        chunks += literal("A dictionary alone gets you O(1) lookups but no ordering, and a linked list alone gets you ordering but O(n) lookups. Combining the two — a hash map from key to node, plus a doubly linked list threading the nodes in recency order — gets O(1) for both:\n\n")
        chunks += codeFence(lineCount: codeLineCount, rng: &rng)
        chunks += literal("\n\n")
        chunks += markdownFeatureShowcase()
        chunks += prose(sentenceCount: 15, rng: &rng)
        chunks += literal("\n")
        chunks += literal("## Walking through a `get`, step by step\n\n")
        chunks += literal("Here's the shape of one `get(_:)` call — the node is found, unlinked from wherever it sits, and relinked at the front:\n\n")
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
        chunks += literal("## When you'd reach for something else\n\n")
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
        chunks += literal("## A few implementation details worth calling out\n\n")
        chunks += literal("A couple of invariants make this correct: the *node-to-key map* is a **plain dictionary**, never a linear scan over the list — a linked list alone can't answer 'is this key already cached' without walking every node. ~~A sorted array keyed by last-access time~~ almost works, but insertion and removal in the middle both cost O(n). See the [Swift collections docs](https://example.com) for more on `Dictionary`'s amortized guarantees.\n\n")
        chunks += literal("What happens on every `set(_:forKey:)` call, in order:\n\n")
        chunks += literal("1. If the key already exists, its node is unlinked and its value updated.\n2. A new node is linked at the front of the list — the most-recently-used position.\n  3. The dictionary entry for the key is pointed at that node.\n4. If the cache is now over capacity, the tail node is unlinked and its key removed from the dictionary.\n\n")
        chunks += literal("---\n\n")
        chunks += literal("```swift\nlet evicted = list.tail // about to be removed once count > capacity\n```\n\n")
        return chunks
    }

    /// Builds one cell's full child-node array: the caller's already-derived `textNodes` (all
    /// `TextNode`, one per sealed/hot block — VelocityUI-zuot) with a static `AsyncImageNode`
    /// spliced in after each block index in `imageAfterBlockIndices` and a `SpacerNode` "rule"
    /// divider spliced in after `ruleAfterBlockIndex` seals — exercising the C3 bind site's
    /// per-block diff and pooling against real non-text fragments, not just one growing text
    /// block.
    ///
    /// Takes `textNodes`/`frontier` rather than an `IncrementalMarkdownParser` (VelocityUI-8g6l):
    /// the caller derives `textNodes` from a `StreamingMarkdownController` so sealed blocks stay
    /// cached; calling `parser.renderNodes` in here would re-derive everything uncached on every
    /// read and defeat that caching.
    ///
    /// Each insertion is gated on `index < frontier`: only sealed blocks are stable anchors, so
    /// an image/rule never appears above text that's still hot and could still reflow. The first
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
        result.reserveCapacity(textNodes.count + imageAfterBlockIndices.count + 1)
        for (index, node) in textNodes.enumerated() {
            result.append(node)
            guard index < frontier else { continue }
            if imageAfterBlockIndices.contains(index) {
                result.append(
                    AsyncImageNode(url: imageURL, aspectRatio: 16.0 / 9.0, contentMode: .fill)
                        .renderID("stream-image-after-\(index)")
                )
            }
            if index == ruleAfterBlockIndex {
                result.append(SpacerNode(minLength: 12).renderID("stream-rule-after-\(index)"))
            }
        }
        return result
    }

    // MARK: - Token generation

    private static func literal(_ s: String) -> [String] { [s] }

    /// A real explanation of how an LRU cache works and why you'd build one this way, broken
    /// into standalone sentences (no trailing period — `prose` appends it) so `prose` can pick
    /// and stream them individually while keeping the whole thing readable regardless of which
    /// subset a given seed lands on.
    private static let sentences: [String] = [
        "An LRU cache is a fixed-size store that, once full, throws away whatever entry hasn't been touched in the longest time to make room for a new one",
        "The two operations that matter are get, which looks up a value and marks it as freshly used, and set, which inserts or updates a value and may trigger an eviction",
        "The whole design hinges on doing both of those in constant time, no matter how many entries the cache is holding",
        "A plain dictionary alone gives you constant-time lookups, but it has no idea which entry was used most recently, so it can't tell you what to evict",
        "A plain linked list alone gives you a clear recency order, but finding a given key means walking the list from the front, which is linear time",
        "Putting the two together is what makes the whole thing work: the dictionary maps a key straight to its node, and the list orders those same nodes by recency",
        "Every time a key is read or written, its node gets unlinked from wherever it currently sits in the list and relinked at the front",
        "The front of the list is always the most recently used entry, and the tail is always the least recently used one, which is exactly the entry to evict",
        "Because the dictionary holds a direct reference to each node, unlinking and relinking never requires searching the list, so the whole operation stays O(1)",
        "Eviction, when the cache is over capacity, just means removing the tail node and deleting its key from the dictionary, both constant-time operations",
        "A doubly linked list is what makes the unlink step cheap, since a node with both a previous and next pointer can remove itself without a search",
        "A singly linked list would still work but removal would need the previous node, which means either extra bookkeeping or walking from the head",
        "Some implementations skip the linked list entirely and use a queue keyed by a logical clock instead, trading a bit of memory for simpler code",
        "That clock-based version still needs a way to skip stale entries during eviction, so it usually ends up doing more work per eviction on average",
        "Language runtimes rarely leave this to you from scratch, Python's functools has an lru_cache decorator and Java's LinkedHashMap has a built-in access-order mode",
        "Swift doesn't ship one in the standard library, which is exactly why implementing it by hand is a common interview and systems-design exercise",
        "Thread safety is a separate concern from the core data structure, a cache used from multiple threads needs its own lock or actor isolation around both operations",
        "Wrapping the whole thing in an actor is the natural Swift answer, since it serializes access without the caller ever managing a lock directly",
        "Capacity planning matters more than people expect, too small and the hit rate collapses, too large and you're holding memory for entries nobody re-reads",
        "A common mismatch is using an LRU cache for data with no locality of reference, in that case recency isn't a useful eviction signal at all",
        "Cache size is usually tuned empirically, watching the actual hit rate against a real workload rather than guessing a number up front",
        "A related structure is an LFU cache, which evicts based on how often an entry is used rather than how recently, useful when frequency matters more than recency",
        "LFU costs more to maintain because every access needs to update a frequency count, and eviction has to scan for the true minimum unless you keep a frequency-bucketed structure",
        "For most application-level caches, recency turns out to be a better proxy for future use than raw frequency, which is why LRU shows up so much more often in practice",
        "A cache without any eviction policy at all is really just a memory leak with a lookup table attached to it",
        "The eviction policy is the entire reason the structure exists, without it you'd just use a dictionary and let it grow forever",
        "One subtlety worth catching in review: updating an existing key should still move it to the front, since a set is itself a use of that key",
        "Getting that wrong is a classic bug — the entry looks fresh because it was just written, but the cache still treats it as the oldest and evicts it first",
        "Testing this kind of structure well means covering the eviction boundary specifically: capacity minus one, exactly at capacity, and one over",
        "It's also worth testing that a get on a missing key doesn't insert anything and doesn't disturb the existing ordering",
        "None of this is free to build correctly, most of the subtlety is in the pointer bookkeeping around unlinking and relinking nodes, not the dictionary part",
        "The trade-off is a bit more code up front, two data structures kept in sync instead of one, in exchange for both operations staying O(1) regardless of cache size",
        "A simpler version that just tracked a timestamp per entry and scanned for the minimum on eviction would be far less code but would cost O(n) per eviction",
        "In practice, that simpler version is fine for small caches, the difference only shows up once the cache holds enough entries that a linear scan gets expensive",
        "That's exactly the kind of workload this example is meant to illustrate, real code, not pseudocode, with the eviction path spelled out end to end",
        "Once you've built one LRU cache by hand, recognizing where a system could use one becomes a lot easier: rate limiters, connection pools, and view caches all show up with the same shape",
        "The version below keeps the node's key alongside its value specifically so eviction can remove the matching dictionary entry without a reverse lookup",
        "That's a small detail that's easy to miss the first time through, and it's the kind of thing worth calling out explicitly in code review"
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

    /// Opens a fence, appends `lineCount` lines of real Swift source (`realCodeLines`, cycling
    /// from a seed-chosen offset if `lineCount` exceeds the corpus) one at a time — the fence
    /// stays hot/open for the entire span — then closes it.
    ///
    /// Real code exercises the tree-sitter highlighter's actual token distribution (keywords,
    /// types, string/comment runs, nesting) instead of one repeated synthetic statement shape,
    /// which is what the wj8x worst-case fence is meant to stress.
    private static func codeFence(lineCount: Int, rng: inout LCG) -> [String] {
        var chunks: [String] = ["```swift\n"]
        let start = Int(rng.next() % UInt64(realCodeLines.count))
        for i in 0..<lineCount {
            chunks.append(realCodeLines[(start + i) % realCodeLines.count] + "\n")
        }
        chunks.append("```\n")
        return chunks
    }

    /// A real, working Swift LRU cache implementation used as the fenced-code-block content in
    /// `tokens()` — a dictionary of nodes plus a doubly linked list threading them in recency
    /// order, exactly what the surrounding prose walks through. Streamed and cycled line by line
    /// by `codeFence` so the "hot fence" benchmark scenario highlights real keyword/type/comment
    /// token shapes instead of one repeated synthetic arithmetic statement.
    private static let realCodeLines: [String] = """
    /// Fixed-capacity cache that evicts the least-recently-used entry once it's full.
    /// `get` and `set` are both O(1): a dictionary maps each key straight to its node, and a
    /// doubly linked list keeps those same nodes ordered from most- to least-recently used.
    final class LRUCache<Key: Hashable, Value> {
        private final class Node {
            let key: Key
            var value: Value
            var prev: Node?
            var next: Node?

            init(key: Key, value: Value) {
                self.key = key
                self.value = value
            }
        }

        private let capacity: Int
        private var nodes: [Key: Node] = [:]
        private var head: Node?   // most recently used
        private var tail: Node?   // least recently used

        init(capacity: Int) {
            precondition(capacity > 0, "LRUCache capacity must be positive")
            self.capacity = capacity
        }

        func get(_ key: Key) -> Value? {
            guard let node = nodes[key] else { return nil }
            moveToFront(node)
            return node.value
        }

        func set(_ key: Key, value: Value) {
            if let existing = nodes[key] {
                existing.value = value
                moveToFront(existing)
                return
            }

            let node = Node(key: key, value: value)
            nodes[key] = node
            linkAtFront(node)

            if nodes.count > capacity, let lru = tail {
                unlink(lru)
                nodes.removeValue(forKey: lru.key)
            }
        }

        // MARK: - Linked-list bookkeeping

        private func moveToFront(_ node: Node) {
            guard head !== node else { return }
            unlink(node)
            linkAtFront(node)
        }

        private func linkAtFront(_ node: Node) {
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
            if tail == nil { tail = node }
        }

        private func unlink(_ node: Node) {
            node.prev?.next = node.next
            node.next?.prev = node.prev
            if head === node { head = node.next }
            if tail === node { tail = node.prev }
            node.prev = nil
            node.next = nil
        }
    }
    """.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private struct LCG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

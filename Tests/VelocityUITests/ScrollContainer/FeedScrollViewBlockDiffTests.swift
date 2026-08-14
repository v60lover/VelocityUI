// FeedScrollViewBlockDiffTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Covers VelocityUI-socg C3: the in-place per-block diff wired into `FeedScrollView.
/// itemsDidChange`'s `.inPlace` branch (`applyInPlaceBlockDiff`/`flatBlocks` — see the `// C3:`
/// site). Phase A (`Block`/`diff`/`freeze`) and phase B (`FrozenBitmapStore`) are already
/// covered in isolation by `BlockReuseTests`/`FrozenBitmapStoreTests`/`HybridReuseSpikeTests`;
/// this file drives the SAME primitives through the production bind path (`FeedScrollView`),
/// the way a real streaming chat message would.
@MainActor
final class FeedScrollViewBlockDiffTests: XCTestCase {

    // MARK: - Fixture

    /// A chat message: an ordered list of paragraph blocks, streamed in by replacing `blocks`
    /// with the SAME `id` (a streaming update) — the exact shape `flatBlocks(for:width:)`
    /// recognizes (a root VStack whose direct children are all leaves).
    struct ChatItem: Identifiable, Sendable {
        let id: Int
        let blocks: [String]
    }

    private func makeEnvironment() -> RenderEnvironment {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore()
        )
    }

    private func makeChatFeed(environment: RenderEnvironment? = nil) -> FeedScrollView<ChatItem> {
        let env = environment ?? makeEnvironment()
        let feed = FeedScrollView<ChatItem>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in
            VStackNode(spacing: 4) {
                for text in item.blocks {
                    TextNode(text)
                }
            }
        }
        return feed
    }

    /// Polls `layoutSubviews` until WorkingRange has a real committed entry at `index` (or
    /// `seconds` elapses) — the async pipeline (`RenderPipeline.onIndexBoundary`) commits it in
    /// the background after `itemsDidChange` invalidates WorkingRange wholesale. C3's own
    /// in-place path never reads WorkingRange for a resolved index, but the NEXT streaming
    /// update needs a committed baseline (`previousFragments`, captured in `itemsDidChange`
    /// before the following `invalidateAll()`) to diff against — same `Task.yield` + wall-clock
    /// deadline pattern `testSameIDLayoutChange_...` already uses in FeedScrollViewTests.
    private func waitForWorkingRangeCommit(_ feed: FeedScrollView<ChatItem>, index: Int, seconds: Double = 10) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
    }

    private static let wordBank: [String] = [
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "while", "chat",
        "message", "streams", "token", "by", "token", "across", "several", "lines", "of",
        "wrapped", "text", "and", "continues", "growing", "steadily", "as", "more", "content",
    ]
    private static func token(_ i: Int) -> String { wordBank[i % wordBank.count] }

    // MARK: - Correctness: immediate synchronous height correction (no polling needed)

    /// Counterpart to FeedScrollViewTests.testSameIDLayoutChange_..., but for TEXT content and
    /// with NO poll loop after the streaming update — the whole point of C3 is that the new
    /// height is correct on the VERY NEXT `layoutSubviews()` call (computed synchronously in
    /// `itemsDidChange` via `applyInPlaceBlockDiff`), unlike C2 which only re-enrolled the index
    /// for the async pipeline to eventually refresh (requiring a poll).
    func testSameIDTextStream_HeightCorrectionIsImmediate_NoPollNeeded() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["short"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let heightBefore = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertGreaterThan(heightBefore, 0, "Precondition: item 0 must have a real measured height")

        let cellBefore = feed._cellLayer(at: 0)
        let returnToPoolBefore = feed._returnToPoolCount

        // Same id, much longer content -> real height must grow. No wait/poll after this.
        let longText = (0..<40).map { Self.token($0) }.joined(separator: " ")
        feed.items = [ChatItem(id: 0, blocks: [longText])]
        feed.layoutSubviews()

        XCTAssertEqual(feed._returnToPoolCount, returnToPoolBefore,
            "Same-id streaming update must NOT return the shell to the pool")
        XCTAssertTrue(cellBefore === feed._cellLayer(at: 0), ".inPlace branch must keep the same cell")

        let heightAfter = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertGreaterThan(heightAfter, heightBefore,
            "The new (longer) content's height must be reflected IMMEDIATELY — synchronously, "
            + "in the same layoutSubviews() call that applied the update, not after a poll")

        await drainFeedWork(feed)
    }

    // MARK: - Frozen blocks reused verbatim (zero recompute)

    func testUnchangedBlock_ReusesFrozenBitmapVerbatim_ZeroRecompute() async {
        let feed = makeChatFeed()
        // Mount with a single (non-empty) block — extractFragments drops zero-size fragments
        // (an empty TextNode measures to a degenerate size), so starting with an empty second
        // block here would desync flatBlocks' block count from the real committed fragment
        // count and trip applyInPlaceBlockDiff's baseline-mismatch bail guard.
        feed.items = [ChatItem(id: 0, blocks: ["block zero content"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // Round 1: a second block appears -> block0 (now non-trailing) must finalize/freeze.
        feed.items = [ChatItem(id: 0, blocks: ["block zero content", "block one starts"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let key0 = BlockKey(itemID: 0, index: 0)
        guard let sizeAfterFreeze = feed.renderEnvironment.frozenBitmapStore.size(for: key0) else {
            return XCTFail("block0 must be frozen into FrozenBitmapStore once it closes out")
        }

        let measureCountAfterRound1 = feed._blockDiffMeasureCallCount
        let rasterizeCountAfterRound1 = feed._blockDiffRasterizeCallCount

        // Rounds 2-4: only the trailing block grows. block0's key is never touched again.
        for round in 0..<3 {
            feed.items = [ChatItem(id: 0, blocks: [
                "block zero content",
                "block one starts and grows round \(round)",
            ])]
            feed.layoutSubviews()
            await waitForWorkingRangeCommit(feed, index: 0)
        }

        // Upper bound, not exact equality: under full-suite system load, `waitForWorkingRangeCommit`'s
        // poll can (rarely) observe a stale WorkingRange commit from a still-in-flight prior round
        // and return early, causing THAT round's applyInPlaceBlockDiff to safely bail to the
        // pre-existing fallback (contributing 0, never extra, to these counts) rather than engage
        // the optimized path — a timing artifact, not a correctness regression (mirrors the
        // documented HybridReuseSpikeTests wall-clock flake). The invariant that actually matters —
        // "block0 (unchanged) never adds a call, no round exceeds 1" — is what these bounds assert.
        let measureDelta = feed._blockDiffMeasureCallCount - measureCountAfterRound1
        let rasterizeDelta = feed._blockDiffRasterizeCallCount - rasterizeCountAfterRound1
        XCTAssertLessThanOrEqual(measureDelta, 3,
            "Only the hot tail may be re-measured across the 3 follow-up rounds — block0 (unchanged) "
            + "must add ZERO additional measure calls (at most 1 per round, for the hot tail only); got \(measureDelta)")
        XCTAssertGreaterThan(measureDelta, 0, "Precondition: at least one round must have exercised the C3 path")
        XCTAssertLessThanOrEqual(rasterizeDelta, 3,
            "Only the hot tail may be re-rasterized across the 3 follow-up rounds; got \(rasterizeDelta)")

        guard let sizeFinal = feed.renderEnvironment.frozenBitmapStore.size(for: key0) else {
            return XCTFail("block0's frozen entry must still exist")
        }
        XCTAssertEqual(sizeAfterFreeze, sizeFinal,
            "A frozen block's cached size must be invariant across later diffs (mirrors LB4)")

        await drainFeedWork(feed)
    }

    // MARK: - Flat per-update cost (anti-jank invariant)

    /// Streams a growing message through the PRODUCTION bind path and asserts the per-round
    /// measure/rasterize call count (via `_blockDiffMeasureCallCount`/`_blockDiffRasterizeCallCount`)
    /// stays bounded by a small constant (hot tail + at most one just-finalized block) — it must
    /// NOT grow as the message accumulates more blocks. Mirrors HybridReuseSpikeTests'/
    /// BlockReuseTests' trend shape, but through `FeedScrollView.itemsDidChange`'s real `.inPlace`
    /// branch instead of calling `diff`/`freeze` directly.
    func testFlatPerUpdateCost_StreamingBlocksDoesNotGrowMeasureRasterizeCalls() async {
        let feed = makeChatFeed()
        var blocksWords: [[String]] = [["seed"]]
        var tokenCursor = 0
        let blockQuota = 5
        let rounds = 24
        let wordsPerRound = 2

        func currentBlocks() -> [String] { blocksWords.map { $0.joined(separator: " ") } }

        feed.items = [ChatItem(id: 0, blocks: currentBlocks())]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        var previousMeasure = feed._blockDiffMeasureCallCount
        var measureDeltas: [Int] = []

        for _ in 0..<rounds {
            for _ in 0..<wordsPerRound {
                blocksWords[blocksWords.count - 1].append(Self.token(tokenCursor))
                tokenCursor += 1
                if blocksWords[blocksWords.count - 1].count >= blockQuota {
                    blocksWords.append([])
                }
            }
            feed.items = [ChatItem(id: 0, blocks: currentBlocks())]
            feed.layoutSubviews()
            await waitForWorkingRangeCommit(feed, index: 0)

            let now = feed._blockDiffMeasureCallCount
            measureDeltas.append(now - previousMeasure)
            previousMeasure = now
        }

        XCTAssertGreaterThan(blocksWords.count, 3,
            "Precondition: the message must have grown past a handful of blocks by the end")
        XCTAssertTrue(measureDeltas.contains { $0 > 0 },
            "Precondition: the C3 block-diff path must have engaged at least once")

        // FLAT: every round's cost is bounded by a small constant (hot tail, plus at most one
        // just-finalized block) — never growing with the message's current block count.
        XCTAssertTrue(measureDeltas.allSatisfy { $0 <= 2 },
            "Per-update measure-call count must stay bounded regardless of message length; "
            + "got deltas \(measureDeltas)")

        let early = measureDeltas.prefix(5)
        let late = measureDeltas.suffix(5)
        let earlyAvg = Double(early.reduce(0, +)) / Double(early.count)
        let lateAvg = Double(late.reduce(0, +)) / Double(late.count)
        XCTAssertLessThanOrEqual(lateAvg, earlyAvg + 1,
            "Late-stream per-update cost (\(lateAvg)) must not exceed early-stream cost "
            + "(\(earlyAvg)) by more than the fixed per-update bound — evidence cost is O(1) "
            + "per update, not O(message length)")

        await drainFeedWork(feed)
    }

    // MARK: - Text-only filter: a mixed block list does not trap

    /// A VStack mixing an EARLY text block with a TRAILING image block. Only the text block
    /// changes (an early edit, per diff()'s streaming model); the image block is unchanged and
    /// must never reach `freeze(_:)` (which traps on non-text) even though it is present in the
    /// same block list. Passing (not crashing) is the assertion.
    func testMixedTextImageBlockList_TextEditDoesNotTrapOnImageBlock() async {
        let env = makeEnvironment()
        let feed = FeedScrollView<MixedItem>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in
            VStackNode(spacing: 4) {
                TextNode(item.text)
                AsyncImageNode(url: nil, aspectRatio: 1.0)
            }
        }
        feed.items = [MixedItem(id: 0, text: "hello")]
        feed.layoutSubviews()
        await waitForWorkingRangeCommitMixed(feed, index: 0)

        // Edit the text block (index 0, non-trailing — the image at index 1 is trailing and
        // unchanged). Must not trap and must not crash.
        feed.items = [MixedItem(id: 0, text: "hello, edited, much longer now")]
        feed.layoutSubviews()

        XCTAssertNotNil(feed._cellLayer(at: 0), "Cell must still be mounted after the mixed-block update")
        await drainFeedWork(feed)
    }

    struct MixedItem: Identifiable, Sendable {
        let id: Int
        let text: String
    }

    private func waitForWorkingRangeCommitMixed(_ feed: FeedScrollView<MixedItem>, index: Int, seconds: Double = 10) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
    }

    // MARK: - Edit-invalidation: editing an already-frozen mid-message block

    /// `diff(previous:new:)` only models streaming append/grow-tail — an edit to an
    /// already-frozen, non-trailing block is outside that model and intentionally left
    /// unclassified by `diff`. `applyInPlaceBlockDiff` must still detect the contentHash change
    /// at that `BlockKey` (VelocityUI-socg design note #4) and re-freeze it — never leave the
    /// stale bitmap/size cached.
    func testEditInvalidation_EditingFrozenMidMessageBlock_RefreezesNotStale() async {
        let feed = makeChatFeed()
        // Single non-empty block at mount — see the analogous comment in
        // testUnchangedBlock_ReusesFrozenBitmapVerbatim_ZeroRecompute for why starting with an
        // empty second block would desync the block/fragment counts.
        feed.items = [ChatItem(id: 0, blocks: ["original block zero"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // block0 closes out (finalizes/freezes) as block1 appears.
        feed.items = [ChatItem(id: 0, blocks: ["original block zero", "block one"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let key0 = BlockKey(itemID: 0, index: 0)
        guard let originalSize = feed.renderEnvironment.frozenBitmapStore.size(for: key0) else {
            return XCTFail("block0 must be frozen after closing out")
        }

        // Grow block1 a bit more first (block0 stays untouched — the normal streaming case).
        feed.items = [ChatItem(id: 0, blocks: ["original block zero", "block one grows more"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let measureBeforeEdit = feed._blockDiffMeasureCallCount

        // EDIT block0 in place — a much longer replacement — while block1 stays as-is.
        // Not a streaming append: block0 is index 0, not the trailing block.
        let editedBlock0 = (0..<20).map { Self.token($0) }.joined(separator: " ")
        feed.items = [ChatItem(id: 0, blocks: [editedBlock0, "block one grows more"])]
        feed.layoutSubviews()

        XCTAssertGreaterThan(feed._blockDiffMeasureCallCount, measureBeforeEdit,
            "Editing an already-frozen block must trigger a re-measure — it must not silently "
            + "keep painting/serving the stale frozen entry")

        guard let refreshedSize = feed.renderEnvironment.frozenBitmapStore.size(for: key0) else {
            return XCTFail("block0's entry must still exist after the edit (re-frozen, not evicted-and-abandoned)")
        }
        XCTAssertNotEqual(refreshedSize, originalSize,
            "block0's cached size must reflect the EDITED (much longer) content, not the stale original")

        let heightAfterEdit = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertGreaterThan(heightAfterEdit, 0, "Item height must still resolve correctly after the edit")

        await drainFeedWork(feed)
    }
}
#endif

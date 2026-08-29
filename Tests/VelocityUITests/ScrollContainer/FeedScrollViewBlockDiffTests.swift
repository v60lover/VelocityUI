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
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore()
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
        guard let sizeAfterFreeze = feed.renderEnvironment.visibleBlockStore.size(for: key0) else {
            return XCTFail("block0 must remain resident once it closes out while still visible")
        }

        let measureCountAfterRound1 = feed._blockDiffMeasureCallCount
        let rasterizeCountAfterRound1 = feed._blockDiffRasterizeCallCount
        let hotAppendCountAfterRound1 = feed._blockDiffHotAppendCallCount

        // PIXELS, not just residency: block0's bitmap must actually be on screen — a sublayer's
        // contents must be the exact CGImage instance the visible tier holds for key0.
        guard let expectedBlock0Bitmap = feed.renderEnvironment.visibleBlockStore.bitmap(for: key0) else {
            return XCTFail("block0 must have a resident bitmap once sealed")
        }
        let paintedAfterRound1 = feed._debugPaintedBitmaps(at: 0)
        XCTAssertEqual(paintedAfterRound1.count, 2,
            "both blocks (frozen block0 + hot block1) must be painting a real bitmap, not left blank")
        XCTAssertTrue(paintedAfterRound1.values.contains(where: { $0 === expectedBlock0Bitmap }),
            "block0's resident bitmap must be the exact instance painted on its sublayer")

        // Rounds 2-4: only the trailing block grows. block0's key is never touched again.
        for round in 0..<3 {
            feed.items = [ChatItem(id: 0, blocks: [
                "block zero content",
                "block one starts and grows round \(round)",
            ])]
            feed.layoutSubviews()
            await waitForWorkingRangeCommit(feed, index: 0)
        }

        // VelocityUI-x4q0: pure hot-tail growth (rounds 2-4) routes ENTIRELY through
        // `HotBlockRasterizerStore.append` — the old measure/rasterize call-count deltas must be
        // EXACTLY zero (stronger than the old `<=3` bound: proves the O(block) path is fully
        // bypassed, not merely bounded). `_blockDiffHotAppendCallCount` is the new proxy for
        // "C3's hot-tail path engaged."
        //
        // Upper bound, not exact equality, for the new counter: under full-suite load,
        // `waitForWorkingRangeCommit`'s poll can rarely observe a stale commit and bail that
        // round to the fallback instead of the optimized path — a timing artifact, not a
        // regression (mirrors the documented HybridReuseSpikeTests flake). What matters: hot
        // tail engages at least once, no round contributes >1 call, and block0 (unchanged)
        // never adds a call to any of these counters.
        let measureDelta = feed._blockDiffMeasureCallCount - measureCountAfterRound1
        let rasterizeDelta = feed._blockDiffRasterizeCallCount - rasterizeCountAfterRound1
        let hotAppendDelta = feed._blockDiffHotAppendCallCount - hotAppendCountAfterRound1
        XCTAssertEqual(measureDelta, 0,
            "Pure hot-tail growth must route entirely through HotBlockRasterizerStore.append, "
            + "adding ZERO calls to the old full-measure path (block0, unchanged, was already "
            + "excluded from this path even before this bead); got \(measureDelta)")
        XCTAssertEqual(rasterizeDelta, 0,
            "Pure hot-tail growth must route entirely through HotBlockRasterizerStore.append, "
            + "adding ZERO calls to the old full-rasterize path; got \(rasterizeDelta)")
        XCTAssertGreaterThan(hotAppendDelta, 0, "Precondition: at least one round must have exercised the new hot-append path")
        XCTAssertLessThanOrEqual(hotAppendDelta, 3,
            "Only the hot tail may be re-appended across the 3 follow-up rounds — at most 1 per round; got \(hotAppendDelta)")

        guard let sizeFinal = feed.renderEnvironment.visibleBlockStore.size(for: key0) else {
            return XCTFail("block0's resident entry must still exist")
        }
        XCTAssertEqual(sizeAfterFreeze, sizeFinal,
            "A frozen block's cached size must be invariant across later diffs (mirrors LB4)")

        // PIXELS again: after 3 rounds of pure hot-tail growth, exactly ONE of the two painted
        // fragments (block0, frozen) must still show the EXACT SAME CGImage instance it painted
        // after round 1 — the other (block1, hot tail) must show a NEW instance reflecting its
        // growth. Same fragment id set throughout (the item's block COUNT never changes across
        // rounds 2-4) — this is what "re-validate C3 reuse by pixels, not just frame height"
        // (the C3-activation checklist) actually means: not just that a cache entry didn't
        // change, but that the SAME bitmap stayed on screen without ever being re-painted.
        let paintedFinal = feed._debugPaintedBitmaps(at: 0)
        XCTAssertEqual(Set(paintedAfterRound1.keys), Set(paintedFinal.keys),
            "the same two fragment ids must still be painting — pure hot-tail growth must not "
            + "change which fragments exist")
        let unchangedInstanceCount = paintedAfterRound1.keys.filter { paintedAfterRound1[$0] === paintedFinal[$0] }.count
        let changedInstanceCount = paintedAfterRound1.keys.filter { paintedAfterRound1[$0] !== paintedFinal[$0] }.count
        XCTAssertEqual(unchangedInstanceCount, 1,
            "exactly one block (the frozen, unchanged block0) must keep painting the IDENTICAL "
            + "CGImage instance across all 3 growth rounds — pixel proof of zero re-rasterize")
        XCTAssertEqual(changedInstanceCount, 1,
            "exactly one block (the hot tail, block1) must show a NEW CGImage instance reflecting "
            + "its growth each round")

        await drainFeedWork(feed)
    }

    // MARK: - C4: suppressed redundant background re-measure

    /// Before this bead's C4 fix, `itemsDidChange` called `workingRange.invalidateAll()`
    /// UNCONDITIONALLY on any item layout change — even when C3's in-place block-diff already
    /// resolved the new height/fragments synchronously — wiping WorkingRange for EVERY item and
    /// forcing `RenderPipeline.onIndexBoundary`'s next crossing to re-measure the whole prefetch
    /// window per streaming token. Asserts the opposite: after a pure same-position update with
    /// no add/remove, every item's WorkingRange entry (neighbors and the streamed item) is still
    /// present — zero misses — checked immediately after one `layoutSubviews()`, no poll.
    func testStreamingUpdate_PatchesWorkingRangeInPlace_NeighborsNeverInvalidated() async {
        let feed = makeChatFeed()
        let itemCount = 5
        feed.items = (0..<itemCount).map { ChatItem(id: $0, blocks: ["seed message \($0)"]) }
        feed.layoutSubviews()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, feed._workingRangeMissCount(from: 0, to: itemCount) > 0 {
            await Task.yield()
            feed.layoutSubviews()
        }
        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: itemCount), 0,
            "Precondition: all items must be warmed up before the streaming update")

        // Stream a token into item 0 only — every other item's NodeTable is byte-identical, so
        // the differ classifies them `.survived`, and item 0 classifies `.layoutChanged` at a
        // stable position (prevIdx == nextIdx) while mounted — exactly C4's fast-path shape.
        var items = feed.items
        items[0] = ChatItem(id: 0, blocks: ["seed message 0 grew a lot longer just now"])
        feed.items = items
        feed.layoutSubviews()

        // NO poll here — this is the point. If the old unconditional invalidateAll() ran, every
        // index (including the untouched neighbors) would read back as a miss right now, and
        // item 0 itself would ALSO miss until the async pipeline refills it later.
        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: itemCount), 0,
            "A pure same-position streaming update must not invalidate ANY WorkingRange entry — "
            + "neighbors were never touched, and the streamed item was patched synchronously by "
            + "the C3 block-diff path, not left for the async pipeline to refill")

        await drainFeedWork(feed)
    }

    /// Companion to `testStreamingUpdate_PatchesWorkingRangeInPlace_NeighborsNeverInvalidated`
    /// (proves WorkingRange stays intact) — this proves the downstream effect: `itemsDidChange`
    /// used to reset `lastNotifiedLeadingIndex = -1` UNCONDITIONALLY, forcing
    /// `notifyPipelineIfNeeded`'s next call to spawn a pipeline `Task` that would just
    /// early-return in `onIndexBoundary` since the fast path invalidated nothing. Streams K
    /// same-position tokens and asserts `_taskSpawnCount` stays flat, then confirms the slow
    /// path (an added item) still spawns as before — the fix must not swallow a genuine notify.
    func testStreamingFastPath_DoesNotReNotifyPipelinePerToken() async {
        let feed = makeChatFeed()
        let itemCount = 5
        feed.items = (0..<itemCount).map { ChatItem(id: $0, blocks: ["seed message \($0)"]) }
        feed.layoutSubviews()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, feed._workingRangeMissCount(from: 0, to: itemCount) > 0 {
            await Task.yield()
            feed.layoutSubviews()
        }
        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: itemCount), 0,
            "Precondition: all items must be warmed up before the streaming update")

        // One more settled pass so notifyPipelineIfNeeded's guard has already latched the
        // current leading index BEFORE the snapshot below — otherwise the snapshot could itself
        // land right before a legitimate first notify and produce a false failure.
        feed.layoutSubviews()
        let spawnCountBeforeStream = feed._taskSpawnCount

        // K same-position token updates into item 0 only — each individually assigned + laid
        // out (not batched into one coalesced burst), so K separate fast-path passes actually run.
        let k = 5
        var accumulated = "seed message 0"
        for i in 0..<k {
            accumulated += " tok\(i)"
            var items = feed.items
            items[0] = ChatItem(id: 0, blocks: [accumulated])
            feed.items = items
            feed.layoutSubviews()
        }

        XCTAssertEqual(feed._taskSpawnCount, spawnCountBeforeStream,
            "The fully-resolved C4 fast path must not spawn any additional pipeline Task per "
            + "streaming token — the leading index never changed and WorkingRange was patched "
            + "directly in place, so there is nothing for notifyPipelineIfNeeded to re-notify")

        // Slow path sanity: an added item takes the full-invalidation branch (not the fast
        // path), which must still reset lastNotifiedLeadingIndex and trigger a real notify —
        // the fix must only skip the reset on the fully-resolved fast path, never generally.
        var itemsWithAppend = feed.items
        itemsWithAppend.append(ChatItem(id: itemCount, blocks: ["new item"]))
        feed.items = itemsWithAppend
        feed.layoutSubviews()

        XCTAssertGreaterThan(feed._taskSpawnCount, spawnCountBeforeStream,
            "The slow path (an added item) must still trigger a real pipeline notify — the fast-"
            + "path fix must not suppress notification generally, only on the resolved fast path")

        await drainFeedWork(feed)
    }

    /// A mounted block belongs to `VisibleBlockStore`. Once its item leaves the keep range,
    /// `updateVisibleCells` demotes the same artifact into the evictable frozen cache.
    func testScrollingPastFrozenBlocks_EvictsThemFromStore() async {
        let feed = makeChatFeed()
        let itemCount = 30
        feed.items = (0..<itemCount).map { ChatItem(id: $0, blocks: ["seed \($0)"]) }
        feed.layoutSubviews()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, feed._workingRangeMissCount(from: 0, to: itemCount) > 0 {
            await Task.yield()
            feed.layoutSubviews()
        }

        // Finalize block0 for every item so each visible artifact becomes resident.
        feed.items = (0..<itemCount).map { ChatItem(id: $0, blocks: ["seed \($0)", "block one"]) }
        feed.layoutSubviews()

        let earlyKey = BlockKey(itemID: 0, index: 0)
        guard feed.renderEnvironment.visibleBlockStore.size(for: earlyKey) != nil else {
            return XCTFail("Precondition: item 0's block0 must be resident before scrolling")
        }

        // Scroll far enough that item 0 falls outside keepRange (visRange.lowerBound - prefetchBehindCount).
        feed.contentOffset = CGPoint(x: 0, y: 100_000)
        feed.layoutSubviews()

        XCTAssertNil(feed.renderEnvironment.visibleBlockStore.size(for: earlyKey),
            "Scrolling item 0 out of the keep range must release its resident entry")
        XCTAssertNotNil(feed.renderEnvironment.frozenBitmapStore.size(for: earlyKey),
            "A leaving resident block must be demoted into the evictable frozen cache")

        await drainFeedWork(feed)
    }

    /// VelocityUI-socg C4's core streaming-coalesce acceptance criterion: "a burst of K token
    /// appends within one display frame produces exactly ONE relayout / refineFrames pass, not
    /// K." `items =` no longer diffs synchronously (see its doc comment) — it defers to the next
    /// `layoutSubviews()`. Counts `cellBuilder` invocations (which `itemsDidChange` calls once
    /// per item per pass when `itemSignature` is nil, as here) to prove K assignments made BEFORE
    /// the next `layoutSubviews()` collapse into exactly one pass, not K.
    func testStreamingBurst_CoalescesToOneRelayoutPerDisplayFrame() async {
        let env = makeEnvironment()
        let feed = FeedScrollView<ChatItem>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        final class Counter { var value = 0 }
        let counter = Counter()
        feed.cellBuilder = { item in
            counter.value += 1
            return VStackNode(spacing: 4) {
                for text in item.blocks { TextNode(text) }
            }
        }

        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        counter.value = 0
        // Burst: K token appends, no layoutSubviews between them — simulates K tokens arriving
        // within the same display frame.
        let k = 5
        var accumulated = "seed"
        for i in 0..<k {
            accumulated += " tok\(i)"
            feed.items = [ChatItem(id: 0, blocks: [accumulated])]
        }
        XCTAssertEqual(counter.value, 0,
            "burst assignments before the next layoutSubviews() must not process synchronously — "
            + "that's what 'deferred to next layoutSubviews' means")

        feed.layoutSubviews()
        XCTAssertEqual(counter.value, 1,
            "the K-assignment burst must coalesce into exactly ONE itemsDidChange pass (one "
            + "cellBuilder call), not K — this is C4's anti-jank invariant for a fast token stream")

        // The coalesced pass must reflect the FINAL accumulated state, not an intermediate one —
        // diffing against the pre-burst baseline, not against whatever the didSet's oldValue was
        // on some intermediate assignment.
        let heightAfter = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertGreaterThan(heightAfter, 0, "final coalesced state must resolve to a real height")

        await drainFeedWork(feed)
    }

    /// VelocityUI-socg design notes, "Open questions/gaps": C4's WorkingRange patch commits a
    /// SYNTHETIC `ResolvedLayout` (built directly from the block-diff's resolved fragments, never
    /// run through the real `measureNode` tree walk) so a LATER appearanceChanged/mediaChanged
    /// classification on the SAME item — which re-derives fragments via `extractFragments(table:
    /// layout:)`, not by reading `.fragments` directly — still gets correct output instead of
    /// walking a bogus/empty tree. Confirms that round-trip directly instead of only by inspection.
    func testWorkingRangePatch_SyntheticLayoutRoundTripsThroughExtractFragments() async {
        let feed = makeChatFeed()
        feed.items = [ChatItem(id: 0, blocks: ["block zero content"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        feed.items = [ChatItem(id: 0, blocks: ["block zero content", "block one starts"])]
        feed.layoutSubviews()

        let painted = feed._debugPaintedBitmaps(at: 0)
        XCTAssertEqual(painted.count, 2, "Precondition: both blocks must be painting")

        guard let rederived = feed._debugExtractFragmentsFromWorkingRange(at: 0) else {
            return XCTFail("extractFragments must succeed against the synthetic ResolvedLayout "
                + "C4 committed — a later appearanceChanged/mediaChanged event on this item "
                + "depends on this exact code path")
        }
        XCTAssertEqual(Set(rederived.map(\.id)), Set(painted.keys),
            "extractFragments walking the synthetic layout must produce the SAME fragment ids "
            + "that are actually painted on screen")

        let totalHeight = feed._debugResolvedFrame(at: 0)?.height ?? -1
        let rederivedMaxY = rederived.map { $0.frame.maxY }.max() ?? -1
        XCTAssertEqual(rederivedMaxY, totalHeight, accuracy: 0.01,
            "the re-derived fragments' combined extent must match the item's real resolved height")

        await drainFeedWork(feed)
    }

    // MARK: - Flat per-update cost (anti-jank invariant)

    /// Streams a growing message through the PRODUCTION bind path and asserts the per-round
    /// measure/rasterize call count stays bounded by a small constant, NOT growing as the message
    /// accumulates blocks. Mirrors HybridReuseSpikeTests'/BlockReuseTests' trend shape, but
    /// through `FeedScrollView.itemsDidChange`'s real `.inPlace` branch, not `diff`/`freeze`
    /// directly.
    ///
    /// Before `HotBlockRasterizerStore.catchUpAndFinalize` existed, finalizing a block cost "at
    /// most one just-finalized block" full measure/rasterize call — this test originally asserted
    /// that cost was bounded, not absent. `catchUpAndFinalize` closes the gap: a block that grew
    /// within the same round it sealed now gets a cheap incremental hot-append instead of a full
    /// re-measure, so `measureDeltas` must now be uniformly zero. The C3 path is still proven
    /// engaged via `_blockDiffHotAppendCallCount`, not the (now silent) measure counter.
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
        var previousHotAppend = feed._blockDiffHotAppendCallCount
        var measureDeltas: [Int] = []
        var hotAppendDeltas: [Int] = []

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

            let nowHotAppend = feed._blockDiffHotAppendCallCount
            hotAppendDeltas.append(nowHotAppend - previousHotAppend)
            previousHotAppend = nowHotAppend
        }

        XCTAssertGreaterThan(blocksWords.count, 3,
            "Precondition: the message must have grown past a handful of blocks by the end")
        XCTAssertTrue(hotAppendDeltas.contains { $0 > 0 },
            "Precondition: the C3 block-diff path must have engaged at least once (proven via the "
            + "hot-append counter now — see this test's doc for why the old measure-counter check "
            + "no longer applies)")
        XCTAssertTrue(measureDeltas.allSatisfy { $0 == 0 },
            "catchUpAndFinalize must make sealing a block that was hot a moment ago ZERO-cost on "
            + "the old full-measure path — any nonzero delta here means a hot block fell through "
            + "to a full re-measure instead of being caught up incrementally; got \(measureDeltas)")

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
        guard let originalSize = feed.renderEnvironment.visibleBlockStore.size(for: key0) else {
            return XCTFail("block0 must be resident after closing out")
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

        guard let refreshedSize = feed.renderEnvironment.visibleBlockStore.size(for: key0) else {
            return XCTFail("block0's resident entry must still exist after the edit")
        }
        XCTAssertNotEqual(refreshedSize, originalSize,
            "block0's cached size must reflect the EDITED (much longer) content, not the stale original")

        let heightAfterEdit = feed._debugResolvedFrame(at: 0)?.height ?? -1
        XCTAssertGreaterThan(heightAfterEdit, 0, "Item height must still resolve correctly after the edit")

        await drainFeedWork(feed)
    }

    /// Pixel-level counterpart to `testEditInvalidation_EditingFrozenMidMessageBlock_RefreezesNotStale`
    /// (which only checks the cache's `size(for:)`) — proves the edit-invalidation path re-paints
    /// real pixels for the edited block while leaving an UNRELATED frozen block's on-screen bitmap
    /// completely untouched. Uses three blocks so block index 1 is unambiguously a frozen,
    /// non-trailing MID block (not the trailing hot tail) at the moment it gets edited.
    func testEditingFrozenMidBlock_ReRasterizes_UnchangedBlocksStillReused() async {
        let feed = makeChatFeed()

        // Round 1 (mount): single block — trailing/hot, not yet frozen.
        feed.items = [ChatItem(id: 0, blocks: ["block zero text"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // Round 2: block0 becomes non-trailing as block1 appears -> block0 finalizes/freezes.
        feed.items = [ChatItem(id: 0, blocks: ["block zero text", "block one text"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        // Round 3: block1 becomes non-trailing as block2 appears -> block1 finalizes/freezes.
        // block2 is now the new hot trailing block (never frozen).
        feed.items = [ChatItem(id: 0, blocks: ["block zero text", "block one text", "block two text"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let key0 = BlockKey(itemID: 0, index: 0)
        let key1 = BlockKey(itemID: 0, index: 1)
        guard let block0BitmapBeforeEdit = feed.renderEnvironment.visibleBlockStore.bitmap(for: key0) else {
            return XCTFail("Precondition: block0 must be resident before the edit")
        }
        guard let block1BitmapBeforeEdit = feed.renderEnvironment.visibleBlockStore.bitmap(for: key1) else {
            return XCTFail("Precondition: block1 must be resident before the edit")
        }
        let paintedBeforeEdit = feed._debugPaintedBitmaps(at: 0)
        XCTAssertTrue(paintedBeforeEdit.values.contains(where: { $0 === block0BitmapBeforeEdit }),
            "Precondition: block0's frozen bitmap must actually be on screen before the edit")
        XCTAssertTrue(paintedBeforeEdit.values.contains(where: { $0 === block1BitmapBeforeEdit }),
            "Precondition: block1's frozen bitmap must actually be on screen before the edit")

        // EDIT block1 in place — block0 and block2 keep their exact prior text, only block1's
        // content differs. Not a streaming append: block1 is index 1, not the trailing block
        // (index 2), so diff() intentionally leaves it out of both `unchanged` and `hotTail`.
        feed.items = [ChatItem(id: 0, blocks: ["block zero text", "EDITED block one text", "block two text"])]
        feed.layoutSubviews()

        guard let block1BitmapAfterEdit = feed.renderEnvironment.visibleBlockStore.bitmap(for: key1) else {
            return XCTFail("block1 must still have a resident bitmap after the edit")
        }
        XCTAssertFalse(block1BitmapAfterEdit === block1BitmapBeforeEdit,
            "block1's cached bitmap must be a NEW CGImage instance after the edit — re-rasterized, not stale")

        let paintedAfterEdit = feed._debugPaintedBitmaps(at: 0)
        XCTAssertTrue(paintedAfterEdit.values.contains(where: { $0 === block0BitmapBeforeEdit }),
            "block0 (untouched by the edit) must still paint the EXACT SAME CGImage instance — proof "
            + "an unrelated block's edit does not collaterally re-rasterize blocks that did not change")
        XCTAssertFalse(paintedAfterEdit.values.contains(where: { $0 === block1BitmapBeforeEdit }),
            "The STALE pre-edit block1 bitmap must no longer be painted anywhere on screen")
        XCTAssertTrue(paintedAfterEdit.values.contains(where: { $0 === block1BitmapAfterEdit }),
            "block1's NEW post-edit bitmap must actually be on screen — pixels, not just the cache entry")

        await drainFeedWork(feed)
    }

    // MARK: - VelocityUI-yvjr: sealed code block body, edited in place

    struct CodeChatItem: Identifiable, Sendable {
        let id: Int
        let code: String
        /// Inserts an ordinary sibling before the code block.
        var showPreface: Bool = false
    }

    private func makeCodeChatFeed(environment: RenderEnvironment? = nil) -> FeedScrollView<CodeChatItem> {
        let env = environment ?? makeEnvironment()
        let feed = FeedScrollView<CodeChatItem>(environment: env, frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in
            VStackNode(spacing: 4) {
                if item.showPreface {
                    TextNode("preface")
                }
                // `.sealed` keeps this block on the synchronous per-block path.
                CodeBlockNode(language: "swift", rawCode: item.code, blockID: BlockID("code"), blockLifecycle: .sealed)
            }
        }
        return feed
    }

    struct CodeAndImageItem: Identifiable, Sendable {
        let id: Int
        let code: String
    }

    private func makeCodeAndImageFeed() -> FeedScrollView<CodeAndImageItem> {
        let feed = FeedScrollView<CodeAndImageItem>(environment: makeEnvironment(), frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        feed.cellBuilder = { item in
            VStackNode(spacing: 4) {
                CodeBlockNode(language: "swift", rawCode: item.code, blockID: BlockID("code"), blockLifecycle: .sealed)
                AsyncImageNode(url: nil).renderID("image")
            }
        }
        return feed
    }

    /// End-to-end paint check: after an in-place edit (same item id) to an already-sealed code
    /// block, the cell's on-screen layer must show the real non-wrapping raster -- wider than the
    /// 375pt container -- not a stale or container-clipped one. This is the ONLY test that asserts
    /// actual `layer.contents` after an edit; the RenderPipeline-level sibling only checks the
    /// `frozenBitmapStore` entry, which stays correct even when the wrong pixels are on screen.
    ///
    /// Regression test for VelocityUI-93um: the resident tier (`visibleBlockStore`) held the
    /// pre-edit raster under a content-independent `BlockKey`, and `buildSyncMap` served it instead
    /// of the fresh wide one the full-refresh path committed to `frozenBitmapStore`. The fix
    /// (`evictChangedResidentRasters`) drops the stale resident entry so the fresh raster paints.
    ///
    /// The edit must take the synchronous per-block path. It then paints the same wide raster the
    /// full pipeline would have produced, without invalidating the item's WorkingRange entry.
    func testSealedCodeBlockBody_InPlaceEdit_PaintsWideRasterOnScreen() async {
        let feed = makeCodeChatFeed()
        // Long enough to exceed the 375pt container regardless of the exact per-character advance
        // width Menlo reports at 15pt (the CodeBlockRasterizerTests/RenderPipelineTests siblings
        // use a narrower 100pt container, where a shorter line is already enough to prove the point).
        let longLine = "let \(String(repeating: "x", count: 150)) = 1"

        // Inlined counterpart of `waitForWorkingRangeCommit` (that helper is typed to
        // `FeedScrollView<ChatItem>` specifically) -- polls until the async pipeline has
        // committed a real entry at index 0, or 10s elapses.
        func waitForCommit() async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            // Phase 1: pump until the async pipeline commits a real WorkingRange entry at index 0.
            while ContinuousClock.now < deadline {
                if feed._workingRangeMissCount(from: 0, to: 1) == 0 { break }
                await Task.yield()
                feed.layoutSubviews()
            }
            // Phase 2: a committed WorkingRange entry is not yet on-screen -- the layer repaints
            // from it on the NEXT layout pass (refineKnownFrames -> buildSyncMap). Keep pumping so
            // the fresh raster actually reaches `layer.contents` before the assertion reads it.
            for _ in 0..<30 {
                await Task.yield()
                feed.layoutSubviews()
            }
        }

        feed.items = [CodeChatItem(id: 0, code: "let x = 1")]
        feed.layoutSubviews()
        await waitForCommit()

        let measureCountBeforeEdit = feed._blockDiffMeasureCallCount
        feed.items = [CodeChatItem(id: 0, code: "let x = 1\n\(longLine)")]
        feed.layoutSubviews()

        XCTAssertGreaterThan(feed._blockDiffMeasureCallCount, measureCountBeforeEdit,
            "a code-block body edit must use applyInPlaceBlockDiff rather than the async full-refresh path")
        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "the in-place path must patch the code block's WorkingRange entry")

        let painted = feed._debugPaintedBitmaps(at: 0)
        guard let widest = painted.values.map({ CGFloat($0.width) }).max() else {
            return XCTFail("edited sealed code block body must paint a bitmap")
        }
        XCTAssertGreaterThan(widest, 375, "raster must be wider than the 375pt container, not clipped to it")

        await drainFeedWork(feed)
    }

    func testSealedCodeBlockBody_InPlaceEdit_ReusesHeaderAndChromeAndRoundTripsLayout() async {
        let feed = makeCodeChatFeed()
        feed.items = [CodeChatItem(id: 0, code: "let x = 1")]
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            feed.layoutSubviews()
            if feed._workingRangeMissCount(from: 0, to: 1) == 0 { break }
            await Task.yield()
        }

        let backgroundID = -4
        let headerID = -5
        let bodyID = 1
        let headerKey = BlockKey(
            itemID: 0,
            blockID: codePartID(owner: BlockID("code"), nodeIndex: bodyID, part: .codeHeader)
        )
        let beforeFragments = feed._debugFragments(at: 0)
        guard beforeFragments.map(\.id) == [backgroundID, headerID, bodyID],
              let header = feed.renderEnvironment.visibleBlockStore.bitmap(for: headerKey)
                    ?? feed.renderEnvironment.frozenBitmapStore.bitmap(for: headerKey)
        else {
            return XCTFail("precondition: committed code block must retain its header artifact")
        }
        let cell = RenderCell()
        cell.layer.frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        cell.applyLayout(beforeFragments, synchronousContent: [headerID: header])
        guard let background = cell._debugPaintedBitmaps[backgroundID] else {
            return XCTFail("precondition: chrome layer must have a bitmap")
        }
        let measureBefore = feed._blockDiffMeasureCallCount

        feed.items = [CodeChatItem(id: 0, code: "let x = 1\nlet y = 2")]
        feed.layoutSubviews()

        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "body-only edit must patch the existing WorkingRange entry")
        XCTAssertEqual(feed._blockDiffMeasureCallCount - measureBefore, 1,
            "only the changed code body may be measured")

        let afterFragments = feed._debugFragments(at: 0)
        guard let reusedHeader = feed.renderEnvironment.visibleBlockStore.bitmap(for: headerKey)
                ?? feed.renderEnvironment.frozenBitmapStore.bitmap(for: headerKey)
        else {
            return XCTFail("unchanged header must remain available through its part cache")
        }
        cell.applyLayout(afterFragments, synchronousContent: [headerID: reusedHeader])
        let after = cell._debugPaintedBitmaps
        XCTAssertTrue(after[backgroundID] === background, "unchanged chrome must retain its bitmap identity")
        XCTAssertTrue(after[headerID] === header, "unchanged header must retain its bitmap identity")

        guard let roundTripped = feed._debugExtractFragmentsFromWorkingRange(at: 0) else {
            return XCTFail("synthetic code-block layout must be extractable")
        }
        XCTAssertEqual(roundTripped.map(\.id), [backgroundID, headerID, bodyID],
            "synthetic tree must preserve background → header → body order")
        XCTAssertEqual(roundTripped.map(\.frame), feed._debugFragments(at: 0).map(\.frame),
            "synthetic extraction must reproduce the visible fast-path fragments")

        await drainFeedWork(feed)
    }

    func testCodeBlockEdit_ReusesMeasuredImageGeometryByPreviousFragmentID() async {
        let feed = makeCodeAndImageFeed()
        feed.items = [CodeAndImageItem(id: 0, code: "let x = 1")]
        feed.layoutSubviews()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: 0, to: 1) == 0 { break }
            await Task.yield()
            feed.layoutSubviews()
        }

        guard let imageBefore = feed._debugFragments(at: 0).first(where: {
            if case .image = $0.content { return true }
            return false
        }) else {
            return XCTFail("precondition: initial code card followed by an image must be committed")
        }

        feed.items = [CodeAndImageItem(id: 0, code: "let x = 1\nlet y = 2")]
        feed.layoutSubviews()

        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "the code edit must keep the item on the synchronous in-place path")
        guard let imageAfter = feed._debugFragments(at: 0).first(where: {
            if case .image = $0.content { return true }
            return false
        }) else {
            return XCTFail("the reused image fragment must remain in the patched layout")
        }
        XCTAssertEqual(imageAfter.frame.size, imageBefore.frame.size,
            "a reused measured image must recover its prior geometry by fragment id, not the code header's array index")
        XCTAssertEqual(imageAfter.frame.height, 375, accuracy: 0.5,
            "the image keeps its measured square height rather than inheriting the code header height")

        await drainFeedWork(feed)
    }

    /// Stable owner identities survive sibling insertions.
    func testCodeBlockHeaderIdentity_SurvivesSiblingInsertionShiftingNodeIndex() async {
        let feed = makeCodeChatFeed()
        feed.items = [CodeChatItem(id: 0, code: "let x = 1")]
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            feed.layoutSubviews()
            if feed._workingRangeMissCount(from: 0, to: 1) == 0 { break }
            await Task.yield()
        }

        // Before the insertion the code block is NodeTable index 1 (0 = root VStack).
        let headerKeyBefore = BlockKey(
            itemID: 0, blockID: codePartID(owner: BlockID("code"), nodeIndex: 1, part: .codeHeader)
        )
        guard let headerBefore = feed.renderEnvironment.visibleBlockStore.bitmap(for: headerKeyBefore)
                ?? feed.renderEnvironment.frozenBitmapStore.bitmap(for: headerKeyBefore)
        else {
            return XCTFail("precondition: committed code block must retain its header artifact")
        }

        // Insert a sibling paragraph before the code block -- its NodeTable index moves to 2.
        feed.items = [CodeChatItem(id: 0, code: "let x = 1", showPreface: true)]
        feed.layoutSubviews()

        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "inserting a sibling ahead of a stably-identified code block must still take the in-place path")

        // The stable-owner identity must be independent of nodeIndex -- looking it up with EITHER
        // the old (1) or the new (2) nodeIndex must resolve to the very same BlockID.
        let keyWithOldIndex = codePartID(owner: BlockID("code"), nodeIndex: 1, part: .codeHeader)
        let keyWithNewIndex = codePartID(owner: BlockID("code"), nodeIndex: 2, part: .codeHeader)
        XCTAssertEqual(keyWithOldIndex, keyWithNewIndex,
            "a code block with a stable owner BlockID must keep the same part identity regardless of nodeIndex")

        guard let headerAfter = feed.renderEnvironment.visibleBlockStore.bitmap(for: headerKeyBefore)
                ?? feed.renderEnvironment.frozenBitmapStore.bitmap(for: headerKeyBefore)
        else {
            return XCTFail("header artifact must still be reachable under its pre-insertion key")
        }
        XCTAssertTrue(headerAfter === headerBefore,
            "the unchanged header must keep its bitmap identity across a sibling insertion, not re-render")

        await drainFeedWork(feed)
    }

    /// An empty language label remains in the extractable code-card triple.
    func testSealedCodeBlockWithNilLanguage_InPlaceEdit_StillRoundTripsAllThreeParts() async {
        let feed = makeCodeChatFeed()
        feed.cellBuilder = { item in
            VStackNode(spacing: 4) {
                CodeBlockNode(language: nil, rawCode: item.code, blockID: BlockID("code"), blockLifecycle: .sealed)
            }
        }
        feed.items = [CodeChatItem(id: 0, code: "let x = 1")]
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            feed.layoutSubviews()
            if feed._workingRangeMissCount(from: 0, to: 1) == 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "a nil-language code block must still commit to WorkingRange, not fall back forever")

        let backgroundID = -4
        let headerID = -5
        let bodyID = 1
        XCTAssertEqual(feed._debugFragments(at: 0).map(\.id), [backgroundID, headerID, bodyID],
            "all three parts must be present even though the header label is empty")

        feed.items = [CodeChatItem(id: 0, code: "let x = 1\nlet y = 2")]
        feed.layoutSubviews()

        XCTAssertEqual(feed._workingRangeMissCount(from: 0, to: 1), 0,
            "a body-only edit on a nil-language code block must patch WorkingRange in place")
        XCTAssertEqual(feed._debugFragments(at: 0).map(\.id), [backgroundID, headerID, bodyID],
            "the empty header part must survive a body edit, not disappear from the fragment list")

        guard let roundTripped = feed._debugExtractFragmentsFromWorkingRange(at: 0) else {
            return XCTFail("synthetic code-block layout must be extractable even with an empty header")
        }
        XCTAssertEqual(roundTripped.map(\.id), [backgroundID, headerID, bodyID],
            "synthetic extraction must reproduce all three parts, including the empty header")

        await drainFeedWork(feed)
    }

    // MARK: - FrozenBitmapStore budget: driver-sized, GROW-ONLY above the constructed floor
    //
    // `updateVisibleCells` sizes the budget from `keepRange.count` (ITEMS), but the flagship
    // scenario is one streaming message — ONE item holding many frozen BLOCKS — so a small
    // item-count window computes a budget far below the 16 MB default. `sizeBudget` is grow-only
    // (see its docstring) so this never starves a real message's live blocks: below, a small
    // window's budget must stay AT the floor, and only RAISE when a real window's budget exceeds it.

    /// With the default 16 MB floor, a small (3-item) window's computed budget is far below it —
    /// `updateVisibleCells`' `sizeBudget` call must be a no-op here. Proves the driver wiring
    /// never lowers `byteBudget`, which is the device regression this test guards against.
    func testFirstLayout_SmallWindow_KeepsDefaultBudgetFloor_NeverLowers() async {
        let feed = makeChatFeed()
        let defaultBudget = feed.renderEnvironment.frozenBitmapStore.byteBudget

        // Three short items, viewport tall enough (812pt) that all three are visible at once —
        // so `keepRange.count` is known exactly: 3 (see the analogous comment this test used to
        // carry, still accurate: `visRange` collapses to `0..<3` regardless of prefetch counts).
        let knownWindowCount = 3
        feed.items = (0..<knownWindowCount).map { ChatItem(id: $0, blocks: ["short block \($0)"]) }
        feed.layoutSubviews()

        XCTAssertEqual(feed.renderEnvironment.frozenBitmapStore.byteBudget, defaultBudget,
            "A 3-item window's computed budget is far below the 16 MB floor — sizeBudget must "
            + "leave byteBudget untouched, never lowering it below the constructed default")

        await drainFeedWork(feed)
    }

    /// Counterpart proving the wiring genuinely RAISES the budget when the real window's
    /// computed footprint exceeds the floor: constructs the env's store with a deliberately tiny
    /// 1-byte floor (below which ANY real window's computed budget sits), lays out a known
    /// window, and asserts `byteBudget` lands at exactly `budget(forWindowCount:)` for that
    /// window — the raise wins, not a no-op that would leave `byteBudget` stuck at 1.
    func testFirstLayout_TinyFloor_RaisesBudgetToRealWindowFootprint() async {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        let env = RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(byteBudget: 1),
            hotBlockRasterizerStore: HotBlockRasterizerStore()
        )
        let feed = makeChatFeed(environment: env)

        let knownWindowCount = 3
        feed.items = (0..<knownWindowCount).map { ChatItem(id: $0, blocks: ["short block \($0)"]) }
        feed.layoutSubviews()

        let sizedBudget = feed.renderEnvironment.frozenBitmapStore.byteBudget
        let expectedBudget = FrozenBitmapStore.budget(forWindowCount: knownWindowCount)

        XCTAssertEqual(sizedBudget, expectedBudget,
            "byteBudget must be raised to exactly budget(forWindowCount:) for the real keepRange item count")
        XCTAssertGreaterThan(sizedBudget, 1, "Sanity: the budget must actually have been raised above the tiny floor")

        await drainFeedWork(feed)
    }
}
#endif

// FeedScrollViewTailFollowTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Covers VelocityUI-8otc.4: `TailFollowMode.llmChat` — the reserved-height tail spacer and
/// scroll-to-bottom follow for a top-down LLM-chat transcript. Reuses the `ChatItem`/
/// `makeChatFeed`/`waitForWorkingRangeCommit` fixture shape from `FeedScrollViewGrowHotBlockTests`.
@MainActor
final class FeedScrollViewTailFollowTests: XCTestCase {

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
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            hotCodeStreamStore: HotCodeStreamStore()
        )
    }

    private func makeChatFeed(
        tailFollowMode: TailFollowMode = .llmChat,
        width: CGFloat = 375, height: CGFloat = 812
    ) -> FeedScrollView<ChatItem> {
        let env = makeEnvironment()
        let feed = FeedScrollView<ChatItem>(
            environment: env,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            tailFollowMode: tailFollowMode
        )
        feed.cellBuilder = { item in
            VStackNode(spacing: 4) {
                for text in item.blocks {
                    TextNode(text)
                }
            }
        }
        return feed
    }

    private func waitForWorkingRangeCommit(_ feed: FeedScrollView<ChatItem>, index: Int, seconds: Double = 10) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if feed._workingRangeMissCount(from: index, to: index + 1) == 0 { return }
            await Task.yield()
            feed.layoutSubviews()
        }
    }

    private func settleTailFollow(_ feed: FeedScrollView<ChatItem>, frameCount: Int = 180) {
        feed._tailFollowDisplayLink?.cancel()
        feed._followAnimator.reset()
        feed.applyTailFollowIfNeeded(now: 1)
        for frame in 1...frameCount where feed._tailFollowDisplayLink != nil {
            feed.advanceTailFollowFromDisplayLink(now: 1 + CFTimeInterval(frame) / 120)
        }
    }

    private func makeDisplayDrivenTailFollowFeed() -> FeedScrollView<ChatItem> {
        let feed = makeChatFeed()
        feed._debugScrollAtRestOverride = true
        feed._debugIsFollowingTail = true
        feed.contentSize = CGSize(width: feed.bounds.width, height: feed.bounds.height + 500)
        feed.contentOffset = .zero
        feed._followAnimator.reset()
        return feed
    }

    // MARK: - FollowAnimator

    func testFollowAnimator_SettlesMonotonicallyWithoutOvershoot() {
        var animator = FollowAnimator()
        var previous: CGFloat = 0
        var result = animator.step(current: 0, target: 500, now: 0)
        XCTAssertLessThan(result.offset, 250, "the first spring step must not jump most of the distance")

        for frame in 1...240 {
            result = animator.step(current: result.offset, target: 500, now: CFTimeInterval(frame) / 120)
            XCTAssertGreaterThanOrEqual(result.offset, previous)
            XCTAssertLessThanOrEqual(result.offset, 500)
            previous = result.offset
            if result.settled { break }
        }

        XCTAssertTrue(result.settled)
        XCTAssertLessThanOrEqual(abs(result.offset - 500), 0.5)
    }

    func testFollowAnimator_60HzAnd120HzMatchAtEqualWallTime() {
        var at60 = FollowAnimator()
        var at120 = FollowAnimator()
        var offset60: CGFloat = 0
        var offset120: CGFloat = 0

        for frame in 0...60 {
            offset60 = at60.step(current: offset60, target: 500, now: CFTimeInterval(frame) / 60).offset
        }
        for frame in 0...120 {
            offset120 = at120.step(current: offset120, target: 500, now: CFTimeInterval(frame) / 120).offset
        }

        XCTAssertEqual(offset60, offset120, accuracy: 0.5)
    }

    func testFollowAnimator_ClampsElapsedTimeAndLatchesAtEpsilon() {
        var clamped = FollowAnimator()
        var reference = FollowAnimator()
        let firstClamped = clamped.step(current: 0, target: 500, now: 0)
        let firstReference = reference.step(current: 0, target: 500, now: 1.0 / 30)
        XCTAssertEqual(firstClamped.offset, firstReference.offset, accuracy: 0.001)

        let secondClamped = clamped.step(current: firstClamped.offset, target: 500, now: 10)
        let secondReference = reference.step(current: firstReference.offset, target: 500, now: 2.0 / 30)
        XCTAssertEqual(secondClamped.offset, secondReference.offset, accuracy: 0.001)

        var latch = FollowAnimator()
        let result = latch.step(current: 499.8, target: 500, now: 0)
        XCTAssertTrue(result.settled)
        XCTAssertEqual(result.offset, 500, accuracy: 0.001)
        XCTAssertEqual(latch.velocity, 0, accuracy: 0.001)
    }

    func testFollowAnimator_TargetShrinkStaysWithinNewBounds() {
        var animator = FollowAnimator()
        var offset: CGFloat = 0
        for frame in 0...30 {
            offset = animator.step(current: offset, target: 500, now: CFTimeInterval(frame) / 60).offset
        }
        XCTAssertGreaterThan(offset, 100, "Precondition: the old position must exceed the shrunken target")

        let result = animator.step(current: offset, target: 100, now: 31.0 / 60)
        XCTAssertGreaterThanOrEqual(result.offset, 0)
        XCTAssertLessThanOrEqual(result.offset, 100)
    }

    func testFollowAnimator_ResetClearsMomentum() {
        var reset = FollowAnimator()
        _ = reset.step(current: 0, target: 500, now: 0)
        reset.reset()

        var fresh = FollowAnimator()
        let resetResult = reset.step(current: 0, target: 500, now: 100)
        let freshResult = fresh.step(current: 0, target: 500, now: 0)
        XCTAssertEqual(reset.velocity, fresh.velocity, accuracy: 0.001)
        XCTAssertEqual(resetResult.offset, freshResult.offset, accuracy: 0.001)
    }

    // MARK: - Display-link tail-follow driver

    func testTailFollow_LayoutEntryDoesNotAdvanceAnActiveDisplayDrivenArc() {
        let feed = makeDisplayDrivenTailFollowFeed()

        feed.applyTailFollowIfNeeded(now: 1)
        let offsetAfterStart = feed.contentOffset.y
        let velocityAfterStart = feed._followAnimator.velocity
        XCTAssertTrue(feed._tailFollowDisplayLink?.isRunning == true)

        feed.applyTailFollowIfNeeded(now: 1 + 1.0 / 60)
        feed.applyTailFollowIfNeeded(now: 1 + 2.0 / 60)

        XCTAssertEqual(feed.contentOffset.y, offsetAfterStart, accuracy: 0.001,
            "layout entry must expose a fresh target without taking another spring step")
        XCTAssertEqual(feed._followAnimator.velocity, velocityAfterStart, accuracy: 0.001,
            "layout entry must not mutate the active spring while the display link is running")

        feed._tailFollowDisplayLink?.cancel()
    }

    func testTailFollow_DisplayLinkAdvanceMovesTheActiveArc() {
        let feed = makeDisplayDrivenTailFollowFeed()

        feed.applyTailFollowIfNeeded(now: 1)
        let offsetAfterStart = feed.contentOffset.y
        XCTAssertTrue(feed._tailFollowDisplayLink?.isRunning == true)

        feed.advanceTailFollowFromDisplayLink(now: 1 + 1.0 / 120)

        XCTAssertGreaterThan(feed.contentOffset.y, offsetAfterStart,
            "a later display-link timestamp must advance the spring toward the bottom")

        feed._tailFollowDisplayLink?.cancel()
    }

    func testTailFollow_SettlingCancelsTheDisplayLinkDriver() {
        let feed = makeDisplayDrivenTailFollowFeed()

        feed.applyTailFollowIfNeeded(now: 1)
        XCTAssertTrue(feed._tailFollowDisplayLink?.isRunning == true)

        for frame in 1...600 where feed._tailFollowDisplayLink != nil {
            feed.advanceTailFollowFromDisplayLink(now: 1 + CFTimeInterval(frame) / 120)
        }

        XCTAssertNil(feed._tailFollowDisplayLink,
            "settling must invalidate the display-link driver")
        XCTAssertEqual(feed.contentOffset.y, 500, accuracy: 0.5)
    }

    func testTailFollow_UserTrackingCancelsDriverAndClearsMomentum() {
        let feed = makeDisplayDrivenTailFollowFeed()
        feed.applyTailFollowIfNeeded(now: 1)
        XCTAssertTrue(feed._tailFollowDisplayLink?.isRunning == true)
        XCTAssertNotEqual(feed._followAnimator.velocity, 0)

        feed._debugUserScrollMotionOverride = true
        feed._debugUserTrackingOverride = true
        feed.updateTailFollowFromUserScroll()

        XCTAssertNil(feed._tailFollowDisplayLink)
        XCTAssertEqual(feed._followAnimator.velocity, 0, accuracy: 0.001)
    }

    // MARK: - 4. Top-down list — no inverted/bottom-anchored layout

    func testLLMChatMode_UsesDefaultTopDownVerticalLayoutProvider() {
        let feed = makeChatFeed()
        XCTAssertTrue(feed.layoutProvider is VerticalLayoutProvider,
            "llmChat composes with the existing top-down VerticalLayoutProvider — no coordinate flip, no inverted provider")
    }

    // MARK: - 1. New user message rises near the top of the viewport on send

    func testPinTailSpacer_ScrollsNewTurnToTopOfViewport() async throws {
        let feed = makeChatFeed()
        feed._debugScrollAtRestOverride = true

        // Seed a short history, then append the new turn's first item (the user message).
        feed.items = [ChatItem(id: 0, blocks: ["hi"]), ChatItem(id: 1, blocks: ["how are you"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        await waitForWorkingRangeCommit(feed, index: 1)

        feed.items += [ChatItem(id: 2, blocks: ["a brand new user question"])]
        feed.pinTailSpacer()
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 2)
        settleTailFollow(feed)

        let newTurnFrame = try XCTUnwrap(feed._debugResolvedFrame(at: 2),
            "Precondition: the new turn must have a resolved frame")
        let pinnedMinY = newTurnFrame.minY

        // The reserved floor is pinnedMinY + viewportHeight, so scrolling to the bottom
        // (contentSize.height - viewportHeight) lands exactly at the new turn's top.
        XCTAssertEqual(feed.contentOffset.y, pinnedMinY, accuracy: 0.5,
            "sending a new turn must scroll it to the top of the viewport, with reserved room below")
        XCTAssertEqual(feed.contentSize.height, pinnedMinY + feed.bounds.height, accuracy: 0.5,
            "the reserved-height floor must be exactly one viewport below the pinned turn's top")

        await drainFeedWork(feed)
    }

    // MARK: - 2. Spacer collapses as the answer grows; no permanent dead space

    func testTailSpacer_CollapsesOnceAnswerGrowsPastTheFloor() async throws {
        let feed = makeChatFeed()
        feed._debugScrollAtRestOverride = true

        feed.items = [ChatItem(id: 0, blocks: ["a brand new user question"])]
        feed.pinTailSpacer()
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let floor = feed.contentSize.height
        let pinnedFrame = try XCTUnwrap(feed._debugResolvedFrame(at: 0))
        XCTAssertEqual(floor, pinnedFrame.minY + feed.bounds.height, accuracy: 0.5,
            "Precondition: the floor must be exactly one viewport below the pinned turn's top")

        // Grow the same item (as if streaming) with a large paragraph — many times the viewport's
        // worth of text — until natural height clears the reserved floor.
        let longText = (0..<400).map { "word\($0)" }.joined(separator: " ")
        feed.items = [ChatItem(id: 0, blocks: ["a brand new user question", longText])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        let grownFrame = try XCTUnwrap(feed._debugResolvedFrame(at: 0))
        let naturalHeight = grownFrame.maxY
        XCTAssertGreaterThan(naturalHeight, floor,
            "Precondition: the streamed answer must have grown past the originally reserved floor")

        // No permanent dead space: once natural content exceeds the floor, contentSize.height
        // tracks it exactly — nothing left over from the collapsed spacer.
        XCTAssertEqual(feed.contentSize.height, naturalHeight, accuracy: 0.5,
            "the spacer must fully collapse once real content exceeds the reserved floor")

        await drainFeedWork(feed)
    }

    // MARK: - 3a. Auto scroll-to-bottom follows the stream while engaged

    func testAutoFollow_TracksBottomAsContentGrows() async {
        let feed = makeChatFeed()
        feed._debugScrollAtRestOverride = true

        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        XCTAssertEqual(feed.contentOffset.y, max(0, feed.contentSize.height - feed.bounds.height), accuracy: 0.5,
            "tail-follow starts engaged and pins to the bottom on first layout")

        let longText = (0..<1000).map { "word\($0)" }.joined(separator: " ")
        feed.items = [ChatItem(id: 0, blocks: ["seed", longText])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        settleTailFollow(feed)

        XCTAssertEqual(feed.contentOffset.y, max(0, feed.contentSize.height - feed.bounds.height), accuracy: 0.5,
            "while following, the viewport must keep tracking the bottom as content streams in")

        await drainFeedWork(feed)
    }

    // MARK: - 3b. Disengages when the user scrolls away from bottom

    func testAutoFollow_DisengagesWhenUserScrollsAwayFromBottom() async {
        let feed = makeChatFeed()
        feed._debugScrollAtRestOverride = true

        let longText = (0..<1000).map { "word\($0)" }.joined(separator: " ")
        feed.items = [ChatItem(id: 0, blocks: ["seed", longText])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        XCTAssertTrue(feed._debugIsFollowingTail, "Precondition: follow starts engaged")
        XCTAssertGreaterThan(feed.contentSize.height, feed.bounds.height * 2,
            "Precondition: content must be tall enough to have real scrollable range")

        // Simulate the user dragging away from the bottom.
        feed._debugUserScrollMotionOverride = true
        feed.contentOffset = CGPoint(x: 0, y: 0)
        feed.updateTailFollowFromUserScroll()

        XCTAssertFalse(feed._debugIsFollowingTail,
            "scrolling away from the bottom must disengage auto-follow")

        // Disengaged: further content growth must NOT yank the viewport back to bottom.
        let offsetAfterDisengage = feed.contentOffset.y
        feed.items = [ChatItem(id: 0, blocks: ["seed", longText, "more streamed text"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        settleTailFollow(feed)

        XCTAssertEqual(feed.contentOffset.y, offsetAfterDisengage, accuracy: 0.5,
            "disengaged follow must let the user keep reading history uninterrupted")

        await drainFeedWork(feed)
    }

    // MARK: - 3c. Re-engages when the user scrolls back to the bottom

    func testAutoFollow_ReengagesWhenUserScrollsBackToBottom() async {
        let feed = makeChatFeed()
        feed._debugScrollAtRestOverride = true

        let longText = (0..<1000).map { "word\($0)" }.joined(separator: " ")
        feed.items = [ChatItem(id: 0, blocks: ["seed", longText])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        XCTAssertGreaterThan(feed.contentSize.height, feed.bounds.height * 2,
            "Precondition: content must be tall enough to have real scrollable range")

        // Disengage first (same trigger as the previous test).
        feed._debugUserScrollMotionOverride = true
        feed.contentOffset = CGPoint(x: 0, y: 0)
        feed.updateTailFollowFromUserScroll()
        XCTAssertFalse(feed._debugIsFollowingTail, "Precondition: must be disengaged before re-engaging")

        // User manually scrolls back down, within reach of the bottom.
        let maxOffset = max(0, feed.contentSize.height - feed.bounds.height)
        feed.contentOffset = CGPoint(x: 0, y: maxOffset)
        feed.updateTailFollowFromUserScroll()

        XCTAssertTrue(feed._debugIsFollowingTail,
            "returning to the bottom must re-engage auto-follow")

        // Re-engaged: the next layout pass keeps the viewport pinned to bottom on further growth.
        feed._debugUserScrollMotionOverride = nil
        feed.items = [ChatItem(id: 0, blocks: ["seed", longText, "more streamed text"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)
        settleTailFollow(feed)

        XCTAssertEqual(feed.contentOffset.y, max(0, feed.contentSize.height - feed.bounds.height), accuracy: 0.5,
            "once re-engaged, growth must resume tracking the bottom")

        await drainFeedWork(feed)
    }

    // MARK: - Regression: .off mode is a total no-op

    func testTailFollowOff_NeverForcesContentOffsetOrFloorsContentSize() async {
        let feed = makeChatFeed(tailFollowMode: .off)
        feed._debugScrollAtRestOverride = true

        feed.items = [ChatItem(id: 0, blocks: ["seed"])]
        feed.layoutSubviews()
        await waitForWorkingRangeCommit(feed, index: 0)

        feed.pinTailSpacer()  // must be a no-op when tailFollowMode == .off
        feed.contentOffset = CGPoint(x: 0, y: 5)
        feed.layoutSubviews()

        XCTAssertEqual(feed.contentOffset.y, 5, accuracy: 0.01,
            ".off must never force contentOffset back to the bottom")
        XCTAssertNil(feed._debugTailSpacerPinIndex, "pinTailSpacer() must no-op when tailFollowMode == .off")

        await drainFeedWork(feed)
    }
}
#endif

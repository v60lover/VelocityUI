// StreamGestureCoalescerTests.swift

import XCTest
import VelocityUI
@testable import BenchmarkHost

// MARK: - streamGestureCoalescerShouldFlushOnIdle (pure transition table)

final class StreamGestureCoalescerShouldFlushOnIdleTests: XCTestCase {
    func testActiveToInactiveFlushes() {
        XCTAssertTrue(streamGestureCoalescerShouldFlushOnIdle(wasActive: true, isActive: false))
    }

    func testInactiveToInactiveDoesNotFlush() {
        XCTAssertFalse(streamGestureCoalescerShouldFlushOnIdle(wasActive: false, isActive: false))
    }

    func testActiveToActiveDoesNotFlush() {
        XCTAssertFalse(streamGestureCoalescerShouldFlushOnIdle(wasActive: true, isActive: true))
    }

    func testInactiveToActiveDoesNotFlush() {
        XCTAssertFalse(streamGestureCoalescerShouldFlushOnIdle(wasActive: false, isActive: true))
    }
}

// MARK: - StreamGestureCoalescer (CADisplayLink-driven) behavior

@MainActor
final class StreamGestureCoalescerTests: XCTestCase {

    private func parser(appending tokens: [String]) -> IncrementalMarkdownParser {
        var p = IncrementalMarkdownParser()
        for t in tokens { p.append(t) }
        return p
    }

    func testGestureActiveSubmitDoesNotFlush() {
        let coalescer = StreamGestureCoalescer()
        var flushed: [IncrementalMarkdownParser] = []
        var active = true
        coalescer.start(isGestureActive: { active }, flush: { flushed.append($0) })

        coalescer.submit(parser(appending: ["a"]))
        coalescer.submit(parser(appending: ["a", "b"]))
        coalescer.submit(parser(appending: ["a", "b", "c"]))

        XCTAssertTrue(flushed.isEmpty, "buffered updates must not flush while a gesture is active")
        coalescer.stop()
    }

    func testGestureEndFlushesExactlyOnceWithLatestAccumulatedValue() {
        let coalescer = StreamGestureCoalescer()
        var flushed: [IncrementalMarkdownParser] = []
        var active = true
        coalescer.start(isGestureActive: { active }, flush: { flushed.append($0) })

        coalescer.submit(parser(appending: ["a"]))
        coalescer.submit(parser(appending: ["a", "b"]))
        let latest = parser(appending: ["a", "b", "c"])
        coalescer.submit(latest)

        active = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(flushed.count, 1, "catch-up pass must fire exactly once on scroll-idle")
        XCTAssertEqual(flushed.first, latest, "catch-up pass must carry the latest accumulated parser, not an earlier buffered one")
        coalescer.stop()
    }

    func testGestureInactiveSubmitFlushesImmediatelyWithoutBuffering() {
        let coalescer = StreamGestureCoalescer()
        var flushed: [IncrementalMarkdownParser] = []
        let value = parser(appending: ["a"])
        coalescer.start(isGestureActive: { false }, flush: { flushed.append($0) })

        coalescer.submit(value)

        XCTAssertEqual(flushed, [value], "submit must flush synchronously when no gesture is active")
        coalescer.stop()
    }

    func testStopSuppressesAnyFurtherFlush() {
        let coalescer = StreamGestureCoalescer()
        var flushed: [IncrementalMarkdownParser] = []
        var active = true
        coalescer.start(isGestureActive: { active }, flush: { flushed.append($0) })

        coalescer.submit(parser(appending: ["a"]))
        coalescer.stop()
        active = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertTrue(flushed.isEmpty, "stop() must suppress the pending value's catch-up flush")
    }
}

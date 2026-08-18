// StreamDriverTests.swift

import XCTest
@testable import BenchmarkHost

final class StreamDriverTokenCadenceTests: XCTestCase {

    // MARK: - streamDriverDueTokenCount

    func testZeroAtStart() {
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: 0, tokensPerSecond: 20, totalTokens: 100), 0)
    }

    func testCountsAtConstantRate() {
        // 20 tokens/s → 1 token due every 0.05s.
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: 0.5, tokensPerSecond: 20, totalTokens: 100), 10)
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: 1.0, tokensPerSecond: 20, totalTokens: 100), 20)
    }

    func testClampsToTotalTokens() {
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: 100, tokensPerSecond: 20, totalTokens: 5), 5)
    }

    func testNegativeElapsedReturnsZero() {
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: -1, tokensPerSecond: 20, totalTokens: 100), 0)
    }

    func testZeroOrNegativeRateReturnsZero() {
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: 5, tokensPerSecond: 0, totalTokens: 100), 0)
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: 5, tokensPerSecond: -1, totalTokens: 100), 0)
    }

    func testZeroTotalTokensReturnsZero() {
        XCTAssertEqual(streamDriverDueTokenCount(elapsed: 5, tokensPerSecond: 20, totalTokens: 0), 0)
    }

    func testIsMonotonicNonDecreasing() {
        var prev = 0
        for i in 0...200 {
            let t = CFTimeInterval(i) * 0.05
            let v = streamDriverDueTokenCount(elapsed: t, tokensPerSecond: 20, totalTokens: 100)
            XCTAssertGreaterThanOrEqual(v, prev, "Non-monotonic at t=\(t)")
            prev = v
        }
    }
}

// MARK: - StreamDriver (CADisplayLink-driven) behavior

@MainActor
final class StreamDriverTests: XCTestCase {

    func testEmitsAllTokensInOrderThenCallsOnEnd() {
        let driver = StreamDriver()
        var received: [String] = []
        var ended = false
        driver.start(tokens: ["a", "b", "c"], tokensPerSecond: 1_000, onToken: { received.append($0) }) {
            ended = true
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(received, ["a", "b", "c"])
        XCTAssertTrue(ended, "onEnd must fire once every token has been emitted")
        driver.stop()
    }

    func testEmptyTokensCallsOnEndSynchronouslyWithoutEmittingAnyToken() {
        let driver = StreamDriver()
        var received: [String] = []
        var ended = false
        driver.start(tokens: [], tokensPerSecond: 20, onToken: { received.append($0) }) {
            ended = true
        }
        XCTAssertTrue(ended, "onEnd must fire synchronously for an empty token list")
        XCTAssertTrue(received.isEmpty)
        driver.stop()
    }

    func testStopBeforeCompletionSuppressesFurtherTokensAndOnEnd() {
        let driver = StreamDriver()
        var received: [String] = []
        var ended = false
        // Slow rate — nothing should be due before we call stop().
        driver.start(tokens: ["a", "b", "c"], tokensPerSecond: 1, onToken: { received.append($0) }) {
            ended = true
        }
        driver.stop()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(ended)
    }
}

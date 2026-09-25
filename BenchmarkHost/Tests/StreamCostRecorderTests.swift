// StreamCostRecorderTests.swift

import XCTest
@testable import BenchmarkHost

final class StreamCostRecorderTests: XCTestCase {

    func testPercentileUsesNearestRank() {
        let values = (1...100).map(Double.init)
        XCTAssertEqual(streamCostPercentile(values, 0.5), 50)
        XCTAssertEqual(streamCostPercentile(values, 0.99), 99)
        XCTAssertEqual(streamCostPercentile([], 0.99), 0)
    }

    @MainActor
    func testWarmupDeliveriesAreNotMeasured() {
        let recorder = StreamCostRecorder(warmupTokens: 2)
        for _ in 0..<5 { recorder.recordDelivery {} }
        XCTAssertEqual(recorder.summary().maxBacklog, 3, "only the 3 post-warmup deliveries wait for paint")
    }

    @MainActor
    func testPaintResolvesOnTheNextDisplayLinkTick() async {
        let recorder = StreamCostRecorder()
        recorder.start()
        recorder.recordDelivery {}
        try? await Task.sleep(for: .milliseconds(200))
        recorder.stop()
        let s = recorder.summary()
        XCTAssertEqual(s.samples, 1)
        XCTAssertGreaterThan(s.tokenToPaintMsMedian, 0)
        XCTAssertLessThan(s.tokenToPaintMsMedian, 200)
    }
}

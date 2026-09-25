// StreamLibraryCountersTests.swift

import XCTest
import VelocityUI
@testable import BenchmarkHost

final class StreamLibraryCountersTests: XCTestCase {

    func testFoldsPhasesPixelsAndMeasureCalls() {
        let counters = StreamLibraryCounters()
        let key = BlockKey(itemID: 1, index: 2)
        counters.record(.hotRenderPhase(.submitted, key: key, kind: .table, generation: 1))
        counters.record(.hotRenderPhase(.started, key: key, kind: .table, generation: 1))
        counters.record(.hotRenderPhase(.delivered, key: key, kind: .table, generation: 1))
        counters.record(.rasterWork(key: key, kind: .text, pixelWidth: 10, pixelHeight: 10, copiedPixelArea: 40))
        counters.record(.measureCalls(key: key, kind: .table, count: 7))
        let t = counters.totals()
        XCTAssertEqual([t.submitted, t.started, t.delivered], [1, 1, 1])
        XCTAssertEqual(t.renderedPixelArea, 60)
        XCTAssertEqual(t.copiedPixelArea, 40)
        XCTAssertEqual(t.measureCalls, 7)
    }
}

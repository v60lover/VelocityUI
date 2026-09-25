// StreamCostScenarioTests.swift

import XCTest
@testable import BenchmarkHost

final class StreamCostScenarioTests: XCTestCase {

    func testKnownFixturesResolveAndUnknownReturnsNil() {
        XCTAssertNotNil(StreamCostScenario.turns(fixture: "table-501-stable"))
        XCTAssertEqual(StreamCostScenario.turns(fixture: "many-messages")?.count, 40)
        XCTAssertNil(StreamCostScenario.turns(fixture: "typo"))
    }

    func testScriptsScaleWithTokenCount() {
        let script = StreamCostScenario.script(named: "offscreen", tokenCount: 400)
        XCTAssertEqual(script?.actions(before: 100), [.scrollAwayFromTail])
        XCTAssertEqual(script?.actions(before: 300), [.scrollToTail])
        XCTAssertNil(StreamCostScenario.script(named: "typo", tokenCount: 400))
        XCTAssertNotNil(StreamCostScenario.script(named: "in-view", tokenCount: 400))
    }
}

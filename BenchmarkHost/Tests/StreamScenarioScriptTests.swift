// StreamScenarioScriptTests.swift

import XCTest
@testable import BenchmarkHost

final class StreamScenarioScriptTests: XCTestCase {

    func testActionsFireOnlyAtTheirTokenIndex() {
        let script = StreamScenarioScript.offscreen(from: 10, to: 40)
        XCTAssertEqual(script.actions(before: 10), [.scrollAwayFromTail])
        XCTAssertEqual(script.actions(before: 40), [.scrollToTail])
        XCTAssertTrue(script.actions(before: 11).isEmpty)
    }

    func testWidthChangeRestoresAfterFiftyTokens() {
        let script = StreamScenarioScript.widthChange(at: 100, narrowPadding: 40, restorePadding: 8)
        XCTAssertEqual(script.actions(before: 100), [.setHorizontalPadding(40)])
        XCTAssertEqual(script.actions(before: 150), [.setHorizontalPadding(8)])
    }

    func testNoneHasNoActions() {
        XCTAssertTrue(StreamScenarioScript.none.steps.isEmpty)
    }
}

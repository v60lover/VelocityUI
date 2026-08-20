// TextNodeBlockIDFlattenRegressionTests.swift

import XCTest
@testable import VelocityUI

@MainActor
final class TextNodeBlockIDFlattenRegressionTests: XCTestCase {

    func testFlattenPreservesIntrinsicTextNodeBlockID() {
        let expectedID = BlockID("streaming-paragraph")
        let table = flatten(
            VStackNode {
                TextNode("Hello", blockID: expectedID, blockLifecycle: .hot)
            },
            itemID: 7
        )

        XCTAssertEqual(table.blockID(at: 1), expectedID,
            "the parser-owned TextNode identity must survive the DSL-to-NodeTable boundary")
        XCTAssertEqual(table.blockLifecycle(at: 1), .hot)
    }
}

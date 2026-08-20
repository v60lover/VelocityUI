import XCTest
@testable import VelocityUI

final class BlockViewportRangeTests: XCTestCase {
    private let frames = [
        CGRect(x: 0, y: 0, width: 320, height: 100),
        CGRect(x: 0, y: 100, width: 320, height: 100),
        CGRect(x: 0, y: 200, width: 320, height: 100),
        CGRect(x: 0, y: 300, width: 320, height: 100),
    ]

    func testReturnsOnlyBlocksIntersectingWindow() {
        XCTAssertEqual(
            BlockViewportRange.activeRange(in: frames, window: CGRect(x: 0, y: 150, width: 320, height: 100)),
            1..<3
        )
    }

    func testUsesExclusiveUpperBoundAtAdjacentBlockEdge() {
        XCTAssertEqual(
            BlockViewportRange.activeRange(in: frames, window: CGRect(x: 0, y: 100, width: 320, height: 100)),
            1..<2
        )
    }

    func testEmptyWindowHasNoActiveBlocks() {
        XCTAssertEqual(BlockViewportRange.activeRange(in: frames, window: .zero), 0..<0)
    }
}

// WorkingRangeTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class WorkingRangeTests: XCTestCase {

    // MARK: - Helpers

    private func makeFragments(height: CGFloat) -> [Fragment] {
        [Fragment(id: 0, content: .geometry, frame: CGRect(x: 0, y: 0, width: 100, height: height))]
    }

    // MARK: - Double-commit idempotency (AC6)

    /// AC(6): two commits with identical (layout, fragments, index) — e.g. this bead's
    /// scroll-path inline materialization racing a later pipeline `notifyPipelineIfNeeded`
    /// commit sourced from the same LayoutCache entry — must be idempotent. Exercises
    /// `WorkingRange.commit(_:_:at:)` directly (it is a pure array-index write per its
    /// docstring), independent of FeedScrollView's mount-skip guard which would otherwise
    /// prevent a second commit from ever being observed at the FeedScrollView level.
    func testDoubleCommitWithIdenticalDataIsIdempotent() {
        let wr = WorkingRange()
        let layout = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 100, height: 200))
        let fragments = makeFragments(height: 200)

        wr.commit(layout, fragments, at: 5)
        let firstEntry = wr.entry(at: 5)
        XCTAssertEqual(firstEntry?.layout.totalFrame, layout.totalFrame)
        XCTAssertEqual(firstEntry?.fragments.count, 1)

        // Second commit: identical layout, fragments, and index.
        wr.commit(layout, fragments, at: 5)
        let secondEntry = wr.entry(at: 5)

        XCTAssertEqual(secondEntry?.layout.totalFrame, layout.totalFrame,
            "Re-committing identical data must leave the layout unchanged")
        XCTAssertEqual(secondEntry?.fragments.count, 1,
            "Re-committing identical data must not accumulate or duplicate fragments")
        XCTAssertEqual(secondEntry?.fragments.first?.frame, fragments[0].frame)
    }

    /// Verifies the double-commit at one index does not disturb neighboring slots
    /// in the ring buffer — a pure array-index write should touch only its own offset.
    func testDoubleCommitDoesNotDisturbOtherIndices() {
        let wr = WorkingRange()
        let layoutA = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 100, height: 50))
        let layoutB = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 100, height: 75))

        wr.commit(layoutA, [], at: 3)
        wr.commit(layoutB, [], at: 4)

        // Double-commit index 4 with the same data.
        wr.commit(layoutB, [], at: 4)

        XCTAssertEqual(wr.entry(at: 3)?.layout.totalFrame.height, 50,
            "Double-commit at index 4 must not disturb index 3's entry")
        XCTAssertEqual(wr.entry(at: 4)?.layout.totalFrame.height, 75)
    }
}
#endif

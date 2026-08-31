// HorizontalCodePanRecognizerTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class HorizontalCodePanRecognizerTests: XCTestCase {

    // MARK: - Direction math

    // `UIPanGestureRecognizer.setTranslation(_:in:)` is a no-op without a live touch-tracking
    // session behind it (confirmed empirically: `translation(in:)` reads back `(0, 0)` even
    // right after `setTranslation` is called), and UIKit gives no public way to construct a
    // `UITouch`. So these tests exercise `HorizontalCodePanDirectionDelegate.isHorizontallyDominant`
    // directly -- the pure function `gestureRecognizerShouldBegin` delegates to -- rather than
    // driving a real `UIPanGestureRecognizer` end to end.

    func testIsHorizontallyDominant_clearHorizontalDrag_wins() {
        XCTAssertTrue(HorizontalCodePanDirectionDelegate.isHorizontallyDominant(CGPoint(x: 20, y: 2)))
    }

    func testIsHorizontallyDominant_clearVerticalDrag_concedes() {
        XCTAssertFalse(HorizontalCodePanDirectionDelegate.isHorizontallyDominant(CGPoint(x: 2, y: 20)))
    }

    func testIsHorizontallyDominant_diagonalTie_concedesToVertical() {
        XCTAssertFalse(HorizontalCodePanDirectionDelegate.isHorizontallyDominant(CGPoint(x: 10, y: 10)))
    }

    /// Regression for the exact case flagged in review: a perfectly horizontal drag whose first
    /// delivered sample hasn't yet crossed any hand-rolled noise threshold. The old
    /// `touchesMoved`-based check computed `abs(t.x) <= abs(t.y) + horizontalDominance`, which
    /// for `(5, 0)` evaluated `5 <= 0 + 6` -- `true` -- and failed a purely horizontal drag on
    /// its first sample. `isHorizontallyDominant` has no such margin: any clear x > y wins.
    func testIsHorizontallyDominant_earlySmallHorizontalSample_stillWins() {
        XCTAssertTrue(HorizontalCodePanDirectionDelegate.isHorizontallyDominant(CGPoint(x: 5, y: 0)))
    }

    func testIsHorizontallyDominant_pureVertical_concedes() {
        XCTAssertFalse(HorizontalCodePanDirectionDelegate.isHorizontallyDominant(CGPoint(x: 0, y: 5)))
    }

    // MARK: - Delegate wiring

    func testDirectionDelegate_nonPanRecognizer_defaultsToTrue() {
        let tap = UITapGestureRecognizer()
        let delegate = HorizontalCodePanDirectionDelegate()
        XCTAssertTrue(delegate.gestureRecognizerShouldBegin(tap))
    }

    func testDirectionDelegate_panWithoutView_defaultsToTrue() {
        let pan = UIPanGestureRecognizer()
        let delegate = HorizontalCodePanDirectionDelegate()
        XCTAssertTrue(delegate.gestureRecognizerShouldBegin(pan))
    }

    // Note: the full possible->began arbitration against a real `panGestureRecognizer` --
    // touch down outside/inside a code body, then a real drag either winning or losing to
    // vertical scroll -- needs live `UITouch` delivery. That end-to-end path is covered by
    // device UI testing, not this file.
}
#endif

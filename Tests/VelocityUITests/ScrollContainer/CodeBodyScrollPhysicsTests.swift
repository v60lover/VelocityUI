// CodeBodyScrollPhysicsTests.swift

import XCTest
@testable import VelocityUI

final class CodeBodyScrollPhysicsTests: XCTestCase {

    private let params = CodeBodyScrollPhysics.Parameters.default

    // MARK: - Deceleration: monotonic, sign-preserving

    func testDecelerationStepMovesOffsetInVelocityDirectionAndVelocityShrinksMonotonically() {
        var offset: CGFloat = 0
        var velocity: CGFloat = 800
        var previousVelocity = velocity
        for _ in 0..<30 {
            let stepped = CodeBodyScrollPhysics.decelerationStep(offset: offset, velocity: velocity, dt: 1.0 / 60.0, parameters: params)
            XCTAssertGreaterThanOrEqual(stepped.offset, offset, "positive velocity must never move offset backward")
            XCTAssertLessThan(abs(stepped.velocity), abs(previousVelocity), "velocity magnitude must shrink every step")
            XCTAssertGreaterThanOrEqual(stepped.velocity, 0, "velocity must not cross zero under pure exponential decay")
            previousVelocity = stepped.velocity
            offset = stepped.offset
            velocity = stepped.velocity
        }
    }

    func testDecelerationStepRespectsNegativeVelocitySign() {
        let stepped = CodeBodyScrollPhysics.decelerationStep(offset: 100, velocity: -600, dt: 1.0 / 60.0, parameters: params)
        XCTAssertLessThan(stepped.offset, 100, "negative velocity must move offset backward")
        XCTAssertLessThan(stepped.velocity, 0, "velocity sign must be preserved by decay")
    }

    // MARK: - Overdrag bound

    func testResistedOffsetNeverExceedsMaxOverdragRegardlessOfRawExcess() {
        let range: ClosedRange<CGFloat> = 0...200
        for rawExcess: CGFloat in [1, 10, 100, 1000, 1_000_000] {
            let below = CodeBodyScrollPhysics.resistedOffset(rawOffset: range.lowerBound - rawExcess, range: range, maxOverdrag: params.maxOverdrag)
            let above = CodeBodyScrollPhysics.resistedOffset(rawOffset: range.upperBound + rawExcess, range: range, maxOverdrag: params.maxOverdrag)
            XCTAssertGreaterThan(below, range.lowerBound - params.maxOverdrag - 0.01)
            XCTAssertLessThan(below, range.lowerBound)
            XCTAssertLessThan(above, range.upperBound + params.maxOverdrag + 0.01)
            XCTAssertGreaterThan(above, range.upperBound)
        }
    }

    func testResistedOffsetIsIdentityInsideLegalRange() {
        let range: ClosedRange<CGFloat> = 0...200
        XCTAssertEqual(CodeBodyScrollPhysics.resistedOffset(rawOffset: 0, range: range, maxOverdrag: 44), 0)
        XCTAssertEqual(CodeBodyScrollPhysics.resistedOffset(rawOffset: 100, range: range, maxOverdrag: 44), 100)
        XCTAssertEqual(CodeBodyScrollPhysics.resistedOffset(rawOffset: 200, range: range, maxOverdrag: 44), 200)
    }

    func testRawExcessInvertsResistedExcess() {
        let range: ClosedRange<CGFloat> = 0...200
        for rawExcess: CGFloat in [1, 10, 50, 200] {
            let presented = CodeBodyScrollPhysics.resistedOffset(rawOffset: range.upperBound + rawExcess, range: range, maxOverdrag: 44)
            let recoveredExcess = CodeBodyScrollPhysics.rawExcess(fromPresentedExcess: presented - range.upperBound, limit: 44)
            XCTAssertEqual(recoveredExcess, rawExcess, accuracy: 0.01)
        }
    }

    // MARK: - Spring settlement

    func testSpringStepConvergesToTargetWithZeroVelocity() {
        var offset: CGFloat = 44
        var velocity: CGFloat = -300
        let target: CGFloat = 0
        var settled = false
        for _ in 0..<300 {
            let stepped = CodeBodyScrollPhysics.springStep(offset: offset, velocity: velocity, target: target, dt: 1.0 / 60.0, parameters: params)
            offset = stepped.offset
            velocity = stepped.velocity
            if CodeBodyScrollPhysics.isSpringSettled(distance: offset - target, velocity: velocity, parameters: params) {
                settled = true
                break
            }
        }
        XCTAssertTrue(settled, "spring must settle within a bounded number of 60Hz ticks")
        XCTAssertEqual(offset, target, accuracy: params.settleDistanceEpsilon)
    }

    // MARK: - dt clamping

    func testDecelerationStepClampsAnomalouslyLargeDt() {
        let normal = CodeBodyScrollPhysics.decelerationStep(offset: 0, velocity: 800, dt: params.maxStepDuration, parameters: params)
        let stalled = CodeBodyScrollPhysics.decelerationStep(offset: 0, velocity: 800, dt: 10.0, parameters: params)
        XCTAssertEqual(normal.offset, stalled.offset, accuracy: 0.001, "a stalled dt beyond maxStepDuration must not jump further than the clamp")
        XCTAssertEqual(normal.velocity, stalled.velocity, accuracy: 0.001)
    }

    func testSpringStepClampsAnomalouslyLargeDt() {
        let normal = CodeBodyScrollPhysics.springStep(offset: 44, velocity: -300, target: 0, dt: params.maxStepDuration, parameters: params)
        let stalled = CodeBodyScrollPhysics.springStep(offset: 44, velocity: -300, target: 0, dt: 10.0, parameters: params)
        XCTAssertEqual(normal.offset, stalled.offset, accuracy: 0.001)
        XCTAssertEqual(normal.velocity, stalled.velocity, accuracy: 0.001)
    }

    // MARK: - Refresh-rate independence

    func testDecelerationConvergesToSameResultAt60HzAnd120HzOverEqualElapsedTime() {
        var offset60: CGFloat = 0, velocity60: CGFloat = 900
        for _ in 0..<12 {
            let stepped = CodeBodyScrollPhysics.decelerationStep(offset: offset60, velocity: velocity60, dt: 1.0 / 60.0, parameters: params)
            offset60 = stepped.offset
            velocity60 = stepped.velocity
        }

        var offset120: CGFloat = 0, velocity120: CGFloat = 900
        for _ in 0..<24 {
            let stepped = CodeBodyScrollPhysics.decelerationStep(offset: offset120, velocity: velocity120, dt: 1.0 / 120.0, parameters: params)
            offset120 = stepped.offset
            velocity120 = stepped.velocity
        }

        // Same 0.2s of elapsed wall-clock time at two refresh rates must land on the same
        // physical state — the whole point of the closed-form (non-Euler) integration.
        XCTAssertEqual(offset60, offset120, accuracy: 0.01)
        XCTAssertEqual(velocity60, velocity120, accuracy: 0.01)
    }

    func testSpringConvergesToSameResultAt60HzAnd120HzOverEqualElapsedTime() {
        var offset60: CGFloat = 44, velocity60: CGFloat = -200
        for _ in 0..<12 {
            let stepped = CodeBodyScrollPhysics.springStep(offset: offset60, velocity: velocity60, target: 0, dt: 1.0 / 60.0, parameters: params)
            offset60 = stepped.offset
            velocity60 = stepped.velocity
        }

        var offset120: CGFloat = 44, velocity120: CGFloat = -200
        for _ in 0..<24 {
            let stepped = CodeBodyScrollPhysics.springStep(offset: offset120, velocity: velocity120, target: 0, dt: 1.0 / 120.0, parameters: params)
            offset120 = stepped.offset
            velocity120 = stepped.velocity
        }

        XCTAssertEqual(offset60, offset120, accuracy: 0.01)
        XCTAssertEqual(velocity60, velocity120, accuracy: 0.01)
    }

    // MARK: - legalRange

    func testLegalRangeIsZeroWhenContentAlreadyFitsViewport() {
        XCTAssertEqual(CodeBodyScrollPhysics.legalRange(contentWidth: 100, viewportWidth: 300), 0...0)
    }

    func testLegalRangeUpperBoundIsOverflowWidth() {
        XCTAssertEqual(CodeBodyScrollPhysics.legalRange(contentWidth: 500, viewportWidth: 300), 0...200)
    }
}

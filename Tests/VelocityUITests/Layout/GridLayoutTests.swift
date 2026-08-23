// GridLayoutTests.swift

import XCTest
@testable import VelocityUI

final class GridLayoutTests: XCTestCase {

    // MARK: - .grid(columns:spacing:) builds the right provider

    func testGridCase_buildsGridLayoutProvider_withMatchingColumnsAndSpacing() {
        let provider = GridLayout.grid(columns: 3, spacing: 8).provider
        guard let grid = provider as? GridLayoutProvider else {
            return XCTFail("GridLayout.grid(...) must produce a GridLayoutProvider, got \(type(of: provider))")
        }
        XCTAssertEqual(grid.columns, 3)
        XCTAssertEqual(grid.spacing, 8)
    }

    func testGridCase_defaultSpacing_is8() {
        let provider = GridLayout.grid(columns: 4).provider
        guard let grid = provider as? GridLayoutProvider else {
            return XCTFail("expected GridLayoutProvider")
        }
        XCTAssertEqual(grid.spacing, 8)
    }

    // MARK: - Measure width threads from the DSL case to the provider

    /// The whole point of `.grid` over hand-building `.custom(GridLayoutProvider(...))`: the
    /// resulting provider's `measureWidth(availableWidth:)` must be the narrower column width,
    /// not the raw container width — text measured at this width wraps differently than at full
    /// width (see `GRID_LAYOUT_DESIGN.md` §D5, `SECTIONED_GRID_DESIGN.md` §D6).
    func testGridCase_measureWidth_isColumnWidthNotContainerWidth() {
        let provider = GridLayout.grid(columns: 3, spacing: 8).provider
        let measureWidth = provider.measureWidth(availableWidth: 320)
        let expectedColWidth: CGFloat = (320 - 8 * 2) / 3
        XCTAssertEqual(measureWidth, expectedColWidth, accuracy: 0.001)
        XCTAssertLessThan(measureWidth, 320)
    }

    // MARK: - .vertical stays the identity measure width (unchanged behavior)

    func testVerticalCase_measureWidth_equalsAvailableWidth() {
        let provider = GridLayout.vertical(spacing: 8).provider
        XCTAssertEqual(provider.measureWidth(availableWidth: 320), 320)
    }

    func testVerticalCase_buildsVerticalLayoutProvider() {
        let provider = GridLayout.vertical(spacing: 12).provider
        guard let vertical = provider as? VerticalLayoutProvider else {
            return XCTFail("GridLayout.vertical(...) must produce a VerticalLayoutProvider, got \(type(of: provider))")
        }
        XCTAssertEqual(vertical.spacing, 12)
    }

    // MARK: - .custom passes the provider through verbatim

    func testCustomCase_passesProviderThroughVerbatim() {
        let custom = GridLayoutProvider(columns: 2, spacing: 4)
        let provider = GridLayout.custom(custom).provider
        guard let grid = provider as? GridLayoutProvider else {
            return XCTFail("expected the exact GridLayoutProvider instance to pass through")
        }
        XCTAssertEqual(grid.columns, 2)
        XCTAssertEqual(grid.spacing, 4)
    }

    // MARK: - Default LayoutProvider.measureWidth extension (no override)

    /// Confirms the protocol default — a hypothetical minimal conformer that implements only the
    /// three original requirements gets `measureWidth == availableWidth` for free.
    func testDefaultMeasureWidth_returnsAvailableWidthVerbatim() {
        struct MinimalProvider: LayoutProvider {
            func frames(for layouts: [ResolvedLayout], availableWidth: CGFloat) -> [CGRect] { [] }
            func visibleIndexRange(in frames: [CGRect], viewportTop: CGFloat, viewportBottom: CGFloat) -> Range<Int> { 0..<0 }
            func contentHeight(for frames: [CGRect]) -> CGFloat { 0 }
        }
        let provider = MinimalProvider()
        XCTAssertEqual(provider.measureWidth(availableWidth: 250), 250)
    }
}

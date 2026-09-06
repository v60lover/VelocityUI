// TextAlignmentMaxWidthFractionLayoutTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Regression guard for text alignment and maxWidthFraction measurement (`VelocityUI-8otc.2`):
/// a `TextDescriptor` with custom `alignment` (`.leading`, `.center`, `.trailing`) and
/// `maxWidthFraction` (a fraction 0...1 of the proposed width) must measure narrower at the
/// fraction width and position its frame within the full proposed width according to alignment —
/// not at the fractional width's own edges. Exercises the real `measureNode` + `TextMeasurementPool`
/// pipeline to verify the x origin and width adjustments land correctly.
final class TextAlignmentMaxWidthFractionLayoutTests: XCTestCase {

    private func textDesc(
        _ content: String,
        alignment: VHorizontalAlignment = .leading,
        maxWidthFraction: Double = 1.0,
        hash: Int = 1
    ) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            alignment: alignment,
            maxWidthFraction: maxWidthFraction,
            layoutHash: hash,
            appearanceHash: hash
        )
    }

    /// Long enough to wrap across several lines at a ~256pt width (80% of 320), and across
    /// fewer but still >1 lines at full 320pt — so both measurements are real multi-line
    /// TextKit layouts, not a single-line degenerate case. Re-wrapped text at the narrow
    /// fraction will be noticeably taller than at full width.
    private let paragraph = """
    VelocityUI renders feeds with a CALayer-backed engine. Every cell in a grid column is \
    measured at the column's own width, not the full container width, because text wraps \
    narrower there — height is not a linear function of column count. User messages wrap \
    even narrower still, occupying only a fraction of the row width.
    """

    func testAssistantStyle_fullWidthLeading_isUnchanged() async throws {
        let width: CGFloat = 320

        let table = NodeTable(
            itemID: "assistant-full-width",
            nodes: [.text(textDesc(paragraph))],
            parentIndices: [-1],
            layoutHash: 1,
            appearanceHash: 1
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: width, textPool: pool)

        // Default alignment is .leading, default maxWidthFraction is 1.0. The frame must
        // start at x=0 (flush left) and occupy at most the full proposed width.
        XCTAssertEqual(layout.totalFrame.origin.x, 0, "leading-aligned text must start at x=0")
        XCTAssertGreaterThan(layout.totalFrame.width, 0, "text must have non-zero width")
        XCTAssertLessThanOrEqual(
            layout.totalFrame.width, width,
            "text measured at full width must not exceed the proposed width"
        )
    }

    func testUserStyle_narrowTrailing_isNarrowAndFlushRight() async throws {
        let width: CGFloat = 320
        let fraction: Double = 0.8
        let narrowWidth = width * CGFloat(fraction)

        // User messages wrap narrower and are flush-right within the row. The text must measure
        // at only 80% of the row width, wrapping taller than it would at full width, then be
        // positioned so its right edge aligns with the row's right edge.
        let table = NodeTable(
            itemID: "user-narrow-trailing",
            nodes: [.text(textDesc(paragraph, alignment: .trailing, maxWidthFraction: fraction))],
            parentIndices: [-1],
            layoutHash: 1,
            appearanceHash: 1
        )

        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: width, textPool: pool)

        // Text must be constrained to the fractional width when it wraps.
        XCTAssertLessThanOrEqual(
            layout.totalFrame.width, narrowWidth + 0.5,
            "text measured at 80% of width must not exceed narrowWidth (within FP epsilon)"
        )

        // Trailing alignment: the frame's right edge must be flush with the column's right edge.
        XCTAssertEqual(
            layout.totalFrame.maxX, width,
            accuracy: 0.5,
            "trailing-aligned text must be flush right at x + width = proposed width"
        )

        // x must be positive (not flush left) — proves alignment actually moved the frame,
        // distinguishing from a silent regression that ignores the alignment parameter.
        XCTAssertGreaterThan(
            layout.totalFrame.origin.x, 0,
            "trailing-aligned text must have x > 0 (moved right from the leading position)"
        )
    }
}
#endif

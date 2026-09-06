// TextRoundedBackgroundFragmentTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

final class TextRoundedBackgroundFragmentTests: XCTestCase {

    // MARK: - Test 1: TextNode with .roundedBackground produces exactly one .codeBlockBackground fragment before .text, with matching cornerRadius and color

    @MainActor
    func testTextNodeRoundedBackground_SynthesizesBackgroundFragmentWithCorrectChrome() async throws {
        // User-bubble: trailing alignment, 80% width constraint, rounded background.
        let bubbleColor = VColorDescriptor(red: 0.9, green: 0.9, blue: 1.0, alpha: 1)
        let root = TextNode("Hello there", alignment: .trailing, maxWidthFraction: 0.8)
            .roundedBackground(cornerRadius: 18, color: bubbleColor)

        let table = flatten(root, itemID: "user-bubble")
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 2, "TextNode with .roundedBackground must produce exactly one background fragment plus one text fragment")

        guard case .codeBlockBackground(let bgDescriptor) = fragments[0].content else {
            return XCTFail("fragments[0] must be .codeBlockBackground, got \(fragments[0].content)")
        }
        guard case .text = fragments[1].content else {
            return XCTFail("fragments[1] must be .text")
        }

        XCTAssertEqual(bgDescriptor.cornerRadius, 18, "background cornerRadius must match .roundedBackground argument exactly")
        XCTAssertEqual(bgDescriptor.color, bubbleColor, "background color must match .roundedBackground argument exactly")
    }

    // MARK: - Test 2: Background fragment frame matches text fragment frame exactly, respects maxWidthFraction constraint, and does not expand to full column width

    @MainActor
    func testTextNodeRoundedBackground_BackgroundFrameMatchesTextFrameAtConstrainedWidth() async throws {
        // Same setup: trailing alignment at 80% of 320 width → max 256 width.
        let bubbleColor = VColorDescriptor(red: 0.8, green: 0.8, blue: 0.9, alpha: 1)
        let root = TextNode("Hello", alignment: .trailing, maxWidthFraction: 0.8)
            .roundedBackground(cornerRadius: 12, color: bubbleColor)

        let table = flatten(root, itemID: "bubble-frame-test")
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 2)
        let bgFragment = fragments[0]
        let textFragment = fragments[1]

        // Background frame must exactly match text frame (same origin, same size).
        XCTAssertEqual(bgFragment.frame, textFragment.frame,
            "background and text fragments must have identical frames (byte-for-byte positioning and sizing)")

        // Width must be constrained by maxWidthFraction (0.8 * 320 = 256 max).
        XCTAssertLessThan(bgFragment.frame.width, 320,
            "background frame width must be narrower than the full proposed column width (constrained by maxWidthFraction)")
        XCTAssertLessThanOrEqual(bgFragment.frame.maxX, 320 + 0.5,
            "background frame must be flush-right within the column bounds (with small floating-point tolerance)")
    }

    // MARK: - Test 3: Plain TextNode without .roundedBackground produces no background fragment at all

    @MainActor
    func testPlainTextNode_NoRoundedBackgroundModifier_ProducesOnlyTextFragment() async throws {
        // Assistant-style: leading alignment (default), full width, no background modifier.
        let root = TextNode("Hello there")  // defaults: alignment .leading, maxWidthFraction 1.0, no .roundedBackground

        let table = flatten(root, itemID: "plain-text")
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 1, "plain TextNode must produce exactly one fragment (no background)")

        guard case .text = fragments[0].content else {
            return XCTFail("the single fragment must be .text")
        }

        // Verify there is no .codeBlockBackground anywhere in the array.
        let hasBackground = fragments.contains { frag in
            if case .codeBlockBackground = frag.content {
                return true
            }
            return false
        }
        XCTAssertFalse(hasBackground, "plain TextNode must never produce a .codeBlockBackground fragment")
    }
}
#endif

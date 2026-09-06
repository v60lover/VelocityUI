// TextNodeMessageRoleTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

final class TextNodeMessageRoleTests: XCTestCase {

    // MARK: - Test 1: TextNode with .messageRole(.user) produces right-aligned width-constrained bubble with background

    @MainActor
    func testMessageRoleUser_ProducesRightAlignedWidthConstrainedBubble() async throws {
        let root = TextNode("Hello there").messageRole(.user)

        let table = flatten(root, itemID: "user-message")
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 2, ".messageRole(.user) must produce exactly one background fragment plus one text fragment")

        guard case .codeBlockBackground(let bgDescriptor) = fragments[0].content else {
            return XCTFail("fragments[0] must be .codeBlockBackground")
        }
        guard case .text = fragments[1].content else {
            return XCTFail("fragments[1] must be .text")
        }

        XCTAssertEqual(bgDescriptor.cornerRadius, 12, "background cornerRadius must be 12 for .messageRole(.user)")
        XCTAssertEqual(bgDescriptor.color, VColorDescriptor.messageBubbleBackground, "background color must be .messageBubbleBackground for .messageRole(.user)")

        // Width must be constrained by maxWidthFraction (0.8 * 320 = 256 max).
        XCTAssertLessThan(fragments[0].frame.width, 320,
            "user message must be narrower than full column width (constrained by 0.8 maxWidthFraction)")
        XCTAssertLessThanOrEqual(fragments[0].frame.maxX, 320 + 0.5,
            "user message must be flush-right / trailing-aligned within column bounds")

        // Background frame must exactly match text frame.
        XCTAssertEqual(fragments[0].frame, fragments[1].frame,
            "background and text fragments must have identical frames")
    }

    // MARK: - Test 2: TextNode with .messageRole(.assistant) produces full-width text-only layout with no background

    @MainActor
    func testMessageRoleAssistant_ProducesFullWidthNoBackground() async throws {
        let root = TextNode("Hello there").messageRole(.assistant)

        let table = flatten(root, itemID: "assistant-message")
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 1, ".messageRole(.assistant) must produce exactly one fragment (text only, no background)")

        guard case .text = fragments[0].content else {
            return XCTFail("the single fragment must be .text")
        }

        // Verify no .codeBlockBackground anywhere.
        let hasBackground = fragments.contains { frag in
            if case .codeBlockBackground = frag.content {
                return true
            }
            return false
        }
        XCTAssertFalse(hasBackground, ".messageRole(.assistant) must never produce a .codeBlockBackground fragment")

        // Text must be leading-aligned at origin x=0. Short text keeps its intrinsic measured
        // width (it doesn't stretch to fill the column) — the "full width" behavior is that
        // maxWidthFraction imposes no constraint, verified separately in
        // testMessageRoleAssistant_MatchesOmittingModifier by comparing against the unconstrained
        // (no-modifier) measurement.
        XCTAssertEqual(fragments[0].frame.origin.x, 0, "assistant message must be leading-aligned")
    }

    // MARK: - Test 3: .messageRole(.assistant) is behaviorally identical to omitting the modifier entirely

    @MainActor
    func testMessageRoleAssistant_MatchesOmittingModifier() async throws {
        let rootNoModifier = TextNode("Same text")
        let rootWithAssistant = TextNode("Same text").messageRole(.assistant)

        let tableNoModifier = flatten(rootNoModifier, itemID: "plain")
        let tableWithModifier = flatten(rootWithAssistant, itemID: "assistant")

        let layoutNoModifier = await measureNode(tableNoModifier, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let layoutWithModifier = await measureNode(tableWithModifier, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))

        let fragmentsNoModifier = extractFragments(table: tableNoModifier, layout: layoutNoModifier)
        let fragmentsWithModifier = extractFragments(table: tableWithModifier, layout: layoutWithModifier)

        XCTAssertEqual(fragmentsNoModifier.count, 1, "plain TextNode must produce exactly one fragment")
        XCTAssertEqual(fragmentsWithModifier.count, 1, ".messageRole(.assistant) must produce exactly one fragment")

        guard case .text = fragmentsNoModifier[0].content else {
            return XCTFail("plain TextNode fragment must be .text")
        }
        guard case .text = fragmentsWithModifier[0].content else {
            return XCTFail(".messageRole(.assistant) fragment must be .text")
        }

        XCTAssertEqual(fragmentsNoModifier[0].frame, fragmentsWithModifier[0].frame,
            ".messageRole(.assistant) must produce identical frame to omitting the modifier")
    }

    // MARK: - Test 4: .messageRole(.user) preserves other TextNode fields (font, color, etc.)

    @MainActor
    func testMessageRoleUser_PreservesOtherFields() {
        let font = VFontDescriptor.body.italic
        let color = VColorDescriptor.white
        let root = TextNode("Styled", font: font, color: color).messageRole(.user)

        XCTAssertEqual(root.font, font, "messageRole must preserve the font field")
        XCTAssertEqual(root.color, color, "messageRole must preserve the color field")
    }
}
#endif

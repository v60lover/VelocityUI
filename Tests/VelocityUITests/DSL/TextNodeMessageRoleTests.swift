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

        // Background is the outer bubble box; text sits inset within it by the default
        // .messageBubblePadding (horizontal: 14, vertical: 10) -- VelocityUI-0ukc fixed the
        // earlier bug where these two frames were forced identical, letting corner glyphs
        // clip through the rounded corners.
        let padding = VEdgeInsets.messageBubblePadding
        XCTAssertEqual(fragments[1].frame.width, fragments[0].frame.width - padding.leading - padding.trailing,
            accuracy: 0.01, "text must be narrower than the bubble by exactly the horizontal insets")
        XCTAssertEqual(fragments[1].frame.height, fragments[0].frame.height - padding.top - padding.bottom,
            accuracy: 0.01, "text must be shorter than the bubble by exactly the vertical insets")
        XCTAssertEqual(fragments[1].frame.minX, fragments[0].frame.minX + padding.leading,
            accuracy: 0.01, "text must be inset from the bubble's left edge by padding.leading")
        XCTAssertEqual(fragments[1].frame.minY, fragments[0].frame.minY + padding.top,
            accuracy: 0.01, "text must be inset from the bubble's top edge by padding.top")
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

    // MARK: - Test 5: messageRole(.user) bubble total size == text size + default insets

    @MainActor
    func testMessageRoleUser_BubbleSizeEqualsTextSizePlusDefaultInsets() async throws {
        let bare = TextNode("Hi", alignment: .trailing, maxWidthFraction: 0.8)
        let bubble = TextNode("Hi").messageRole(.user)

        let bareTable = flatten(bare, itemID: "bare")
        let bubbleTable = flatten(bubble, itemID: "bubble")
        let bareLayout = await measureNode(bareTable, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let bubbleLayout = await measureNode(bubbleTable, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))

        let padding = VEdgeInsets.messageBubblePadding
        XCTAssertEqual(bubbleLayout.totalFrame.width, bareLayout.totalFrame.width + padding.leading + padding.trailing,
            accuracy: 0.01, "bubble outer width must equal the unpadded text width plus the default horizontal insets")
        XCTAssertEqual(bubbleLayout.totalFrame.height, bareLayout.totalFrame.height + padding.top + padding.bottom,
            accuracy: 0.01, "bubble outer height must equal the unpadded text height plus the default vertical insets")
    }

    // MARK: - Test 6: messageRole(.user, padding:) overrides the default and roundtrips through Flattener

    @MainActor
    func testMessageRoleUser_CustomPadding_OverridesDefaultAndRoundtrips() async throws {
        let customPadding = VEdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20)
        let root = TextNode("Hi").messageRole(.user, padding: customPadding)

        let table = flatten(root, itemID: "custom-padding")
        guard case .text(let descriptor) = table.nodes[0] else {
            return XCTFail("node 0 must be .text")
        }
        XCTAssertEqual(descriptor.backgroundChrome?.padding, customPadding,
            "custom padding must roundtrip unchanged from TextNode through Flattener into TextDescriptor.backgroundChrome")

        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 1))
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments[1].frame.minX, fragments[0].frame.minX + customPadding.leading, accuracy: 0.01,
            "custom padding.leading must be reflected in the measured text inset, not the default")
    }

    // MARK: - Test 7: backgroundChrome.padding folds into layoutHash; cornerRadius/color stay appearanceHash-only

    @MainActor
    func testMessageRoleUser_PaddingAffectsLayoutHash_CornerRadiusColorAffectOnlyAppearanceHash() {
        let base = TextNode("Hi").messageRole(.user)
        let differentPadding = TextNode("Hi").messageRole(.user, padding: VEdgeInsets(all: 30))
        let differentColor = TextNode("Hi", color: .white).messageRole(.user)

        XCTAssertNotEqual(base.layoutHash, differentPadding.layoutHash,
            "a padding change must alter layoutHash — it affects measured geometry")
        XCTAssertEqual(base.layoutHash, differentColor.layoutHash,
            "a color-only change must not alter layoutHash — color is paint-only")
        XCTAssertNotEqual(base.appearanceHash, differentColor.appearanceHash,
            "a color change must alter appearanceHash")
    }
}
#endif

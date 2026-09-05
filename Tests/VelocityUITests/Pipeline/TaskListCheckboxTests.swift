// TaskListCheckboxTests.swift

import XCTest
@testable import VelocityUI

/// Covers VelocityUI-i1xx.3: task-list checkbox parsing and rendering. Verifies that GFM task
/// items (`[ ]` unchecked, `[x]`/`[X]` checked) parse to the correct `checked` value, render
/// checkbox glyphs instead of literal markers, strip the marker from content, and preserve
/// inline emphasis in the remaining text. Plain list items (no brackets) are unaffected.
final class TaskListCheckboxTests: XCTestCase {

    // MARK: - Parsing: checked value classification

    func testUnorderedTaskItem_Unchecked_ParsesCheckedFalse() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [ ] buy milk\n\n")
        guard case .listItem(_, _, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(checked, false, "an unchecked task item `[ ]` must parse to checked == false")
    }

    func testUnorderedTaskItem_CheckedLowercase_ParsesCheckedTrue() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [x] done\n\n")
        guard case .listItem(_, _, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(checked, true, "a checked task item `[x]` must parse to checked == true")
    }

    func testUnorderedTaskItem_CheckedUppercase_ParsesCheckedTrue() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [X] done\n\n")
        guard case .listItem(_, _, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(checked, true, "a checked task item `[X]` (uppercase) must parse to checked == true")
    }

    func testOrderedTaskItem_Unchecked_ParsesCheckedFalse() {
        var parser = IncrementalMarkdownParser()
        parser.append("1. [ ] first task\n\n")
        guard case .listItem(_, _, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(checked, false, "an ordered unchecked task item must parse to checked == false")
    }

    func testOrderedTaskItem_CheckedLowercase_ParsesCheckedTrue() {
        var parser = IncrementalMarkdownParser()
        parser.append("2. [x] task done\n\n")
        guard case .listItem(_, _, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(checked, true, "an ordered checked task item must parse to checked == true")
    }

    // MARK: - Rendering: glyph substitution, no literal marker

    func testUnorderedTaskItem_Unchecked_RendersCheckboxGlyph() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [ ] buy milk\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("☐"), "unchecked task item must render the empty checkbox glyph U+2610")
        XCTAssertFalse(descriptor.content.contains("[ ]"), "unchecked task item must NOT render the literal marker [ ]")
    }

    func testUnorderedTaskItem_Checked_RendersCheckboxGlyph() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [x] done\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("☑"), "checked task item must render the checked checkbox glyph U+2611")
        XCTAssertFalse(descriptor.content.contains("[x]"), "checked task item must NOT render the literal marker [x]")
        XCTAssertFalse(descriptor.content.contains("[X]"), "checked task item must NOT render the literal marker [X]")
    }

    func testOrderedTaskItem_Unchecked_RendersCheckboxGlyph() {
        var parser = IncrementalMarkdownParser()
        parser.append("3. [ ] numbered task\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("☐"), "ordered unchecked task item must render the empty checkbox glyph")
        XCTAssertFalse(descriptor.content.contains("[ ]"), "ordered unchecked task item must NOT render the literal marker")
    }

    func testOrderedTaskItem_Checked_RendersCheckboxGlyph() {
        var parser = IncrementalMarkdownParser()
        parser.append("2. [x] done\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("☑"), "ordered checked task item must render the checked checkbox glyph")
        XCTAssertFalse(descriptor.content.contains("[x]"), "ordered checked task item must NOT render the literal marker [x]")
    }

    // MARK: - Inline emphasis in task item text

    func testUnorderedTaskItem_WithBold_PreservesEmphasis() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [ ] **bold** and plain\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("bold"), "task item text must render")
        XCTAssertTrue(descriptor.content.contains("and plain"), "task item text must render")
        guard let boldRun = descriptor.runs.first(where: { $0.font.weight == VFontDescriptor.boldWeight }) else {
            return XCTFail("must contain a bold run")
        }
        XCTAssertEqual(boldRun.length, "bold".utf16.count, "the bold span must be styled as bold")
    }

    func testUnorderedTaskItem_WithItalic_PreservesEmphasis() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [x] *italic* text\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("italic"), "task item text must render")
        guard let italicRun = descriptor.runs.first(where: { $0.font.traits.contains(.italic) }) else {
            return XCTFail("must contain an italic run")
        }
        XCTAssertEqual(italicRun.length, "italic".utf16.count, "the italic span must be styled as italic")
    }

    func testUnorderedTaskItem_WithCode_PreservesEmphasis() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [ ] call `func()` now\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("func()"), "task item code text must render")
        guard let codeRun = descriptor.runs.first(where: { $0.font.family == "Menlo" }) else {
            return XCTFail("must contain a code run with Menlo family")
        }
        XCTAssertNotNil(codeRun.backgroundColor, "the code span must carry its background pill")
    }

    func testOrderedTaskItem_WithBold_PreservesEmphasis() {
        var parser = IncrementalMarkdownParser()
        parser.append("1. [x] **complete** this\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("complete"), "task item text must render")
        guard let boldRun = descriptor.runs.first(where: { $0.font.weight == VFontDescriptor.boldWeight }) else {
            return XCTFail("must contain a bold run")
        }
        XCTAssertEqual(boldRun.length, "complete".utf16.count, "the bold span must be styled as bold")
    }

    // MARK: - Plain list items are unaffected

    func testPlainUnorderedItem_NoBrackets_RendersBullet() {
        var parser = IncrementalMarkdownParser()
        parser.append("- regular item\n\n")
        guard case .listItem(_, _, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertNil(checked, "a plain unordered item must have checked == nil")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.hasPrefix("• "), "plain unordered item must render a bullet prefix")
        XCTAssertTrue(descriptor.content.contains("regular item"), "item text must render normally")
    }

    func testPlainOrderedItem_NoBrackets_RendersNumber() {
        var parser = IncrementalMarkdownParser()
        parser.append("1. regular item\n\n")
        guard case .listItem(let ordered, let number, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertTrue(ordered, "must be ordered")
        XCTAssertEqual(number, 1)
        XCTAssertNil(checked, "a plain ordered item must have checked == nil")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.hasPrefix("1. "), "plain ordered item must render the correct number prefix")
        XCTAssertTrue(descriptor.content.contains("regular item"), "item text must render normally")
    }

    func testPlainOrderedItem_NonSequentialNumber_IsPreserved() {
        var parser = IncrementalMarkdownParser()
        parser.append("5. fifth item\n\n")
        guard case .listItem(_, let number, _, let checked) = parser.hotBlocksState[0].kind else {
            return XCTFail("must be a list item")
        }
        XCTAssertEqual(number, 5)
        XCTAssertNil(checked)
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.hasPrefix("5. "), "the original number must be preserved")
    }

    // MARK: - Nested task items

    func testNestedUnorderedTaskItem_Unchecked_RendersWithIndent() {
        var parser = IncrementalMarkdownParser()
        parser.append("- top\n  - [ ] nested task\n\n")
        guard parser.hotBlocksState.count >= 2 else {
            return XCTFail("must have at least 2 blocks")
        }
        guard case .listItem(_, _, let topDepth, _) = parser.hotBlocksState[0].kind else {
            return XCTFail("block 0 must be a list item")
        }
        guard case .listItem(_, _, let nestedDepth, let checked) = parser.hotBlocksState[1].kind else {
            return XCTFail("block 1 must be a list item")
        }
        XCTAssertEqual(topDepth, 0)
        XCTAssertGreaterThan(nestedDepth, topDepth, "nested item must have greater depth")
        XCTAssertEqual(checked, false, "nested task item must parse correctly")

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard blocks.count >= 2 else {
            return XCTFail("must have at least 2 rendered blocks")
        }
        guard case .text(let nestedDescriptor) = blocks[1].fragment.content else {
            return XCTFail("nested block must render as .text")
        }
        XCTAssertTrue(nestedDescriptor.content.contains("☐"), "nested unchecked task must render the checkbox glyph")
        XCTAssertTrue(nestedDescriptor.content.contains("nested task"), "nested item text must render")
    }

    func testNestedOrderedTaskItem_Checked_RendersWithIndent() {
        var parser = IncrementalMarkdownParser()
        parser.append("1. top\n  1. [x] nested task\n\n")
        guard parser.hotBlocksState.count >= 2 else {
            return XCTFail("must have at least 2 blocks")
        }
        guard case .listItem(_, _, let nestedDepth, let checked) = parser.hotBlocksState[1].kind else {
            return XCTFail("block 1 must be a list item")
        }
        XCTAssertGreaterThan(nestedDepth, 0, "nested item must have greater depth")
        XCTAssertEqual(checked, true, "nested ordered task item must parse correctly")

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard blocks.count >= 2 else {
            return XCTFail("must have at least 2 rendered blocks")
        }
        guard case .text(let nestedDescriptor) = blocks[1].fragment.content else {
            return XCTFail("nested block must render as .text")
        }
        XCTAssertTrue(nestedDescriptor.content.contains("☑"), "nested checked task must render the checkbox glyph")
        XCTAssertTrue(nestedDescriptor.content.contains("nested task"), "nested item text must render")
    }

    // MARK: - Mixed task and plain items

    func testMixedTaskAndPlainItems_EachRendersCorrectly() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [ ] task item\n- plain item\n- [x] done\n\n")
        guard parser.hotBlocksState.count >= 3 else {
            return XCTFail("must have at least 3 blocks")
        }

        // Block 0: task item unchecked
        guard case .listItem(_, _, _, let checked0) = parser.hotBlocksState[0].kind else {
            return XCTFail("block 0 must be a list item")
        }
        XCTAssertEqual(checked0, false)

        // Block 1: plain item
        guard case .listItem(_, _, _, let checked1) = parser.hotBlocksState[1].kind else {
            return XCTFail("block 1 must be a list item")
        }
        XCTAssertNil(checked1)

        // Block 2: task item checked
        guard case .listItem(_, _, _, let checked2) = parser.hotBlocksState[2].kind else {
            return XCTFail("block 2 must be a list item")
        }
        XCTAssertEqual(checked2, true)

        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard blocks.count >= 3 else {
            return XCTFail("must have at least 3 rendered blocks")
        }

        guard case .text(let d0) = blocks[0].fragment.content else {
            return XCTFail("block 0 must render as .text")
        }
        XCTAssertTrue(d0.content.contains("☐"), "first block (unchecked task) must have checkbox")

        guard case .text(let d1) = blocks[1].fragment.content else {
            return XCTFail("block 1 must render as .text")
        }
        XCTAssertTrue(d1.content.contains("• "), "second block (plain) must have bullet")
        XCTAssertFalse(d1.content.contains("☐") || d1.content.contains("☑"), "plain item must not have checkbox glyphs")

        guard case .text(let d2) = blocks[2].fragment.content else {
            return XCTFail("block 2 must render as .text")
        }
        XCTAssertTrue(d2.content.contains("☑"), "third block (checked task) must have checkbox")
    }

    // MARK: - Edge cases

    func testTaskMarker_FollowedByBoldText_MarkerStripAndEmphasisPreserved() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [ ] **important**\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        // Verify checkbox is rendered, marker is not
        XCTAssertTrue(descriptor.content.contains("☐"), "checkbox glyph must render")
        XCTAssertFalse(descriptor.content.contains("[ ]"), "marker must not render literally")
        // Verify bold text is preserved
        XCTAssertTrue(descriptor.content.contains("important"), "emphasized text must render")
        guard let boldRun = descriptor.runs.first(where: { $0.font.weight == VFontDescriptor.boldWeight }) else {
            return XCTFail("must contain a bold run")
        }
        XCTAssertEqual(boldRun.length, "important".utf16.count, "text must be styled as bold")
    }

    func testTaskItem_WithMultipleInlineStyles_AllPreserved() {
        var parser = IncrementalMarkdownParser()
        parser.append("- [x] **bold** *italic* `code`\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 300)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertTrue(descriptor.content.contains("☑"), "checkbox must render")
        XCTAssertTrue(descriptor.content.contains("bold"), "bold text must render")
        XCTAssertTrue(descriptor.content.contains("italic"), "italic text must render")
        XCTAssertTrue(descriptor.content.contains("code"), "code text must render")

        let boldCount = descriptor.runs.filter { $0.font.weight == VFontDescriptor.boldWeight }.count
        let italicCount = descriptor.runs.filter { $0.font.traits.contains(.italic) }.count
        let codeCount = descriptor.runs.filter { $0.font.family == "Menlo" }.count

        XCTAssertGreaterThanOrEqual(boldCount, 1, "must have at least one bold run")
        XCTAssertGreaterThanOrEqual(italicCount, 1, "must have at least one italic run")
        XCTAssertGreaterThanOrEqual(codeCount, 1, "must have at least one code run")
    }
}

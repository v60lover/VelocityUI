// MarkdownScanCountersTests.swift

import XCTest
@testable import VelocityUI

/// `MarkdownScanCounters` must distinguish genuinely new scan work (`linesScannedNew`) from
/// necessary reconsideration of the still-open trailing line (`partialLineReconsiderations`),
/// and must record when that reconsideration actually advanced a seal (`partialLineSeals`)
/// versus when it didn't.
final class MarkdownScanCountersTests: XCTestCase {

    func testLinesScannedNew_CountsOnlyCompleteLines() {
        var parser = IncrementalMarkdownParser()
        parser.append("line one\nline two\n")
        XCTAssertEqual(parser.scanCounters.linesScannedNew, 2)
    }

    func testLinesScannedNew_DoesNotDoubleCountAcrossAppends() {
        var parser = IncrementalMarkdownParser()
        parser.append("line one\n")
        parser.append("line two\n")
        XCTAssertEqual(
            parser.scanCounters.linesScannedNew, 2,
            "each complete line must be scanned exactly once total across separate append() calls"
        )
    }

    func testPartialLineReconsiderations_CountsEachAppendToAnOpenTrailingLine() {
        var parser = IncrementalMarkdownParser()
        parser.append("ab")
        parser.append("cd")
        parser.append("ef")
        XCTAssertEqual(
            parser.scanCounters.partialLineReconsiderations, 3,
            "each append that extends the still-open trailing line reprocesses it once"
        )
        XCTAssertEqual(parser.scanCounters.linesScannedNew, 0, "no newline has arrived yet")
    }

    func testPartialLineSeals_ZeroWhenTrailingLineNeverResolvesASeal() {
        var parser = IncrementalMarkdownParser()
        parser.append("just some words")
        XCTAssertEqual(parser.scanCounters.partialLineSeals, 0)
    }

    func testPartialLineSeals_CountsWhenTrailingLineTurnsOutBlank() {
        var parser = IncrementalMarkdownParser()
        parser.append("Foo\n")
        XCTAssertEqual(parser.scanCounters.partialLineSeals, 0)
        // A still-open (not yet newline-terminated) trailing line that is all-whitespace WOULD
        // resolve a seal point if it ended here. This is diagnostic only — the parser does not
        // commit it until a real newline arrives, since more characters could still turn this
        // line non-blank (see the comment in `append(_:)`).
        parser.append(" ")
        XCTAssertGreaterThanOrEqual(
            parser.scanCounters.partialLineSeals, 1,
            "an all-whitespace trailing partial line must be flagged as a would-be seal point"
        )
    }

    func testBoundedReach_LargeOpenFenceDoesNotRescanEarlierLinesOnEachAppend() {
        // Regression guard for the exact defect this bead fixes: appending one more line to a
        // large open fence must cost O(1) new-line scans per append, not O(current fence size).
        var parser = IncrementalMarkdownParser()
        parser.append("```swift\n")
        for i in 0..<200 {
            parser.append("let line\(i) = \(i)\n")
        }
        let before = parser.scanCounters.linesScannedNew
        parser.append("let oneMore = 999\n")
        let after = parser.scanCounters.linesScannedNew
        XCTAssertEqual(
            after - before, 1,
            "appending one line inside a large open fence must scan exactly one new line, not re-scan the whole open region"
        )
    }

    // MARK: - Character-by-character streaming (round-2 read-time defect)

    /// Round-2 defect: `hotBlocksState` used to be a computed property that replayed a REAL
    /// (non-dry-run) `step()` on a scratch copy of `hotScan` on every READ, not just every
    /// `append(_:)` -- and `blockList` read it twice per call. Inside an open fence, that meant
    /// every keystroke's materialization forced a full Copy-on-Write copy of the whole fence's
    /// text (to append the pending trailing characters), THEN retokenized it, up to 2x per
    /// render frame -- cost proportional to the OPEN BLOCK'S SIZE, not to the one character
    /// typed. `hotFastPathAppends` incrementing by exactly 1 per keystroke, with
    /// `hotFullMaterializations` staying flat (0 new ones), proves the fence path now costs
    /// O(delta) regardless of how large the fence already is -- verified directly below by
    /// running the same one-character append against both a 10-line and a 2000-line fence and
    /// asserting the SAME `hotFullMaterializations` delta (0) in both cases.
    func testCharacterStreaming_LargeOpenFence_UsesO1FastPath_NotFullMaterialization() {
        var parser = IncrementalMarkdownParser()
        parser.append("```swift\n")
        for i in 0..<300 {
            parser.append("let line\(i) = \(i)\n")
        }

        let materializationsBefore = parser.scanCounters.hotFullMaterializations
        var previousFastPathAppends = parser.scanCounters.hotFastPathAppends
        for character in "let finalLine = 42" {
            parser.append(String(character))
            let current = parser.scanCounters.hotFastPathAppends
            XCTAssertEqual(
                current - previousFastPathAppends, 1,
                "each appended character inside an open fence must take the O(delta) fast path exactly once"
            )
            previousFastPathAppends = current

            // Reading the materialized view repeatedly (as blockList/renderableBlocks both do)
            // must not itself trigger any additional work -- it's a stored field now.
            _ = parser.hotBlocksState
            _ = parser.hotBlocksState
            XCTAssertEqual(
                parser.scanCounters.hotFastPathAppends, current,
                "reading hotBlocksState must not change the counters"
            )
        }
        XCTAssertEqual(
            parser.scanCounters.hotFullMaterializations, materializationsBefore,
            "streaming characters inside an already-open fence must never trigger a full O(open-block-size) materialization"
        )
    }

    /// Same one-character append, compared at two open-fence sizes (10 lines vs 2000 lines).
    /// `hotFullMaterializations`' delta must be identical (0) at both sizes -- this is the
    /// bead's literal ask: a deterministic per-append bound independent of open-block size.
    func testBoundedWork_OneCharAppend_SameRegardlessOfOpenFenceSize() {
        func materializationDeltaForOneCharAppend(fenceLineCount: Int) -> Int {
            var parser = IncrementalMarkdownParser()
            parser.append("```swift\n")
            for i in 0..<fenceLineCount {
                parser.append("let line\(i) = \(i)\n")
            }
            let before = parser.scanCounters.hotFullMaterializations
            parser.append("x")
            return parser.scanCounters.hotFullMaterializations - before
        }

        let deltaSmall = materializationDeltaForOneCharAppend(fenceLineCount: 10)
        let deltaLarge = materializationDeltaForOneCharAppend(fenceLineCount: 2000)
        XCTAssertEqual(deltaSmall, 0)
        XCTAssertEqual(
            deltaLarge, deltaSmall,
            "one appended character's materialization cost must not grow with open-fence size"
        )
    }

    /// Open `.paragraph`/`.blockquote`/etc. blocks stay genuinely ambiguous until `\n` arrives
    /// (the pending line could still turn into a heading/fence-open/table row/etc that excludes
    /// it -- see `step`'s doc comment), so this path is NOT the O(1) fast path above: it still
    /// pays O(committed-paragraph-size) per keystroke. What round 2 actually fixed here is the
    /// multiplier -- that cost used to be paid once per READ (so 2x+ per append, once for each
    /// of `blockList`'s two old reads, plus once more for `renderableBlocks`); now it is paid at
    /// most once per `append(_:)`, however many times the result is read afterward. This test
    /// documents that remaining, non-hidden O(n) cost while proving the multiplier is gone.
    func testCharacterStreaming_LargeOpenParagraph_OneMaterializationPerAppendRegardlessOfReads() {
        var parser = IncrementalMarkdownParser()
        for i in 0..<300 {
            parser.append("paragraph line \(i) with some words in it\n")
        }

        var previousMaterializations = parser.scanCounters.hotFullMaterializations
        for character in "one final trailing line still being typed" {
            parser.append(String(character))
            let afterAppend = parser.scanCounters.hotFullMaterializations
            XCTAssertEqual(
                afterAppend - previousMaterializations, 1,
                "each appended character inside a large open paragraph must materialize exactly once per append"
            )

            // Reading it three more times (mirrors blockList's old double-read plus
            // renderableBlocks) must not add any further materializations -- this is the
            // round-2 defect's direct regression test.
            _ = parser.blockList(itemID: "item", width: 300)
            _ = parser.blockList(itemID: "item", width: 300)
            _ = parser.hotBlocksState
            XCTAssertEqual(
                parser.scanCounters.hotFullMaterializations, afterAppend,
                "reading hotBlocksState/blockList repeatedly must not trigger additional materializations"
            )
            previousMaterializations = afterAppend
        }
    }

    // MARK: - Pending-line fast path (root cause #1: non-fence open blocks)

    /// Streams `prefix` (which must make the line settle into `expectedKind` almost
    /// immediately) followed by 20k one-character appends, and asserts the SECOND HALF of the
    /// stream never copies more than `maxBytesPerAppend` bytes on a single append -- the direct
    /// counter-based proof that `PendingLineFastPath` costs O(new bytes), not O(line-so-far).
    private func assertBoundedPendingLineFastPath(
        prefix: String, maxBytesPerAppend: Int = 4, file: StaticString = #filePath, line: UInt = #line
    ) {
        var parser = IncrementalMarkdownParser()
        parser.append(prefix)
        let totalChars = 20_000
        var maxDeltaInSecondHalf = 0
        for i in 0..<totalChars {
            let before = parser.scanCounters.pendingLineFastPathBytesCopiedTotal
            parser.append("x")
            let delta = parser.scanCounters.pendingLineFastPathBytesCopiedTotal - before
            if i >= totalChars / 2 {
                maxDeltaInSecondHalf = max(maxDeltaInSecondHalf, delta)
            }
        }
        XCTAssertGreaterThan(
            parser.scanCounters.pendingLineFastPathAppends, 0,
            "expected the pending-line fast path to engage at all for prefix \(prefix.debugDescription)",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            maxDeltaInSecondHalf, maxBytesPerAppend,
            "a single-character append late in a long single-line block must copy a bounded number " +
            "of bytes, not O(line length so far), for prefix \(prefix.debugDescription)",
            file: file, line: line
        )
    }

    func testBoundedPendingLineFastPath_SingleLineParagraph() {
        assertBoundedPendingLineFastPath(prefix: "some growing paragraph text ")
    }

    func testBoundedPendingLineFastPath_SingleLineBlockquote() {
        assertBoundedPendingLineFastPath(prefix: "> some growing quoted text ")
    }

    func testBoundedPendingLineFastPath_SingleLineListItem() {
        assertBoundedPendingLineFastPath(prefix: "- some growing list item text ")
    }

    /// Multi-line paragraph: the *already-committed* lines go through the existing amortized
    /// `extendOpenBlockCache` append (not `PendingLineFastPath`, which only covers the still-
    /// uncommitted trailing line) -- this documents that `pendingLineFastPathBytesCopiedTotal`
    /// only ever tracks the pending-line mechanism, so it stays bounded per keystroke here too.
    func testBoundedPendingLineFastPath_MultilineParagraph_PendingLineStillBounded() {
        var parser = IncrementalMarkdownParser()
        for i in 0..<300 {
            parser.append("paragraph line \(i) with some words in it\n")
        }
        var maxDelta = 0
        for _ in 0..<5_000 {
            let before = parser.scanCounters.pendingLineFastPathBytesCopiedTotal
            parser.append("x")
            maxDelta = max(maxDelta, parser.scanCounters.pendingLineFastPathBytesCopiedTotal - before)
        }
        XCTAssertLessThanOrEqual(maxDelta, 4)
    }
}

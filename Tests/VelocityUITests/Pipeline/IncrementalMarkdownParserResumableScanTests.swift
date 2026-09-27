// IncrementalMarkdownParserResumableScanTests.swift

import XCTest
@testable import VelocityUI

/// Differential tests: the resumable `HotScanState`/`step(_:into:)` scan (used by `append(_:)`)
/// must produce byte-for-byte the same `[ParsedMDBlock]` output as `referenceParseTail(_:)` —
/// the full-rescan oracle kept around only for this comparison — no matter how the same source
/// text is chunked. If a chunking strategy ever disagrees, the resumable scanner has drifted
/// from the reference semantics.
final class IncrementalMarkdownParserResumableScanTests: XCTestCase {

    // MARK: - Chunking strategies

    private func chunksWholeString(_ source: String) -> [String] { [source] }

    private func chunksByLine(_ source: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in source {
            current.append(ch)
            if ch == "\n" {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func chunksByWord(_ source: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in source {
            current.append(ch)
            if ch == " " || ch == "\n" {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func chunksByCharacter(_ source: String) -> [String] {
        source.map(String.init)
    }

    /// Runs `source` through every chunking strategy and asserts the resulting hot+sealed block
    /// list matches `IncrementalMarkdownParser.referenceParseTail(source).sealed +
    /// referenceParseTail(source).hot` exactly, for each strategy independently.
    private func assertChunkingInvariant(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let oracle = IncrementalMarkdownParser.referenceParseTail(source)
        let expected = oracle.sealed + oracle.hot

        let strategies: [(String, (String) -> [String])] = [
            ("whole-string", chunksWholeString),
            ("line-by-line", chunksByLine),
            ("word-by-word", chunksByWord),
            ("character-by-character", chunksByCharacter),
        ]

        for (name, chunker) in strategies {
            var parser = IncrementalMarkdownParser()
            for chunk in chunker(source) {
                parser.append(chunk)
            }
            let actual = parser.sealedBlocks + parser.hotBlocksState
            XCTAssertEqual(
                actual, expected,
                "chunking strategy '\(name)' disagreed with the full-rescan oracle for source: \(source.debugDescription)",
                file: file, line: line
            )
            XCTAssertEqual(
                parser.sealedBlockIDs.count, oracle.sealed.count,
                "chunking strategy '\(name)' sealed a different block count than the oracle for source: \(source.debugDescription)",
                file: file, line: line
            )
        }
    }

    /// Streams `source` one character at a time and asserts BlockID stability alongside content
    /// equality: a sealed block's ID must never change once sealed, and a still-growing hot
    /// block's ID must stay the same across every append that only extends it (not a fresh
    /// finalize/reopen). This is what lets a consumer key SwiftUI-style diffing off `BlockID`
    /// without every keystroke looking like a delete+insert.
    private func assertBlockIDStabilityUnderCharacterChunking(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var parser = IncrementalMarkdownParser()
        var previousSealedIDs: [BlockID] = []
        var previousHotIDs: [BlockID] = []

        for character in source {
            parser.append(String(character))

            let sealedIDs = parser.sealedBlockIDs
            XCTAssertTrue(
                sealedIDs.starts(with: previousSealedIDs),
                "a sealed block's ID must never change once sealed for source: \(source.debugDescription)",
                file: file, line: line
            )
            previousSealedIDs = sealedIDs

            // The hot region's leading IDs (the blocks it shares with the previous step, i.e.
            // everything except a just-opened trailing block) must be untouched — growing an
            // already-open block must not reassign its ID.
            // Only checked when the hot region didn't just shrink (a seal moved blocks out of
            // it, which legitimately drops their IDs from the front — that case is already
            // covered by the `sealedIDs` check above).
            let hotIDs = parser.hotBlockIDs
            if hotIDs.count >= previousHotIDs.count {
                let stablePrefixCount = previousHotIDs.count
                XCTAssertEqual(
                    Array(hotIDs.prefix(stablePrefixCount)), previousHotIDs,
                    "hot block IDs for still-open blocks must stay constant across appends for source: \(source.debugDescription)",
                    file: file, line: line
                )
            }
            previousHotIDs = hotIDs
        }
    }

    // MARK: - Fences

    func testChunking_CodeFence_SimpleClosed() {
        assertChunkingInvariant("```swift\nlet x = 1\nlet y = 2\n```\n\n")
    }

    func testChunking_CodeFence_UnclosedAtEOF() {
        assertChunkingInvariant("```swift\nlet x = 1\nlet y = ")
    }

    func testChunking_CodeFence_BlankLineInsideNeverSeals() {
        assertChunkingInvariant("```\nline one\n\nline two\n```\n\n")
    }

    // MARK: - Tables

    func testChunking_Table_ParagraphPromotedToHeaderThenRows() {
        assertChunkingInvariant("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\n")
    }

    func testChunking_Table_MixedAlignment() {
        assertChunkingInvariant("| L | C | R |\n|:---|:---:|---:|\n| x | y | z |\n\n")
    }

    func testChunking_Table_PipeLineNeverFollowedByDelimiter_StaysParagraph() {
        assertChunkingInvariant("| a | b |\nnot a delimiter row\n\n")
    }

    // MARK: - Paragraphs and headings

    func testChunking_Paragraph_GrowsAcrossManyLines() {
        assertChunkingInvariant("line one\nline two\nline three\nline four\n\n")
    }

    func testChunking_SetextHeading_DashUnderline() {
        assertChunkingInvariant("A Title\n---\n\n")
    }

    func testChunking_ATXHeading() {
        assertChunkingInvariant("### Heading text\n\n")
    }

    func testChunking_ThematicBreak() {
        assertChunkingInvariant("above\n\n---\n\nbelow\n\n")
    }

    func testChunking_Image() {
        assertChunkingInvariant("![alt](https://example.com/a.png)\n\n")
    }

    // MARK: - Blockquotes and lists

    func testChunking_Blockquote_MultipleLines() {
        assertChunkingInvariant("> line one\n> line two\n> line three\n\n")
    }

    func testChunking_List_UnorderedWithBlankLineContinuation() {
        assertChunkingInvariant("- item one\n- item two\n\n- item three (still same list)\n\nafter\n\n")
    }

    func testChunking_List_OrderedWithTaskMarkers() {
        assertChunkingInvariant("1. [ ] todo\n2. [x] done\n\n")
    }

    // MARK: - Math blocks

    func testChunking_MathBlock_DollarFence() {
        assertChunkingInvariant("$$\nE = mc^2\n$$\n\n")
    }

    func testChunking_MathBlock_SameLineClose() {
        assertChunkingInvariant("$$ E = mc^2 $$\n\n")
    }

    // MARK: - Pending-line fast path (PendingLineFastPath) disambiguation

    /// "- " alone is genuinely ambiguous with a thematic break until real content arrives
    /// (see `settleListLikeFastPath`) -- must still resolve correctly at every prefix.
    func testChunking_PendingLine_DashListItem_NotConfusedWithThematicBreak() {
        assertChunkingInvariant("- some growing text\n\n")
    }

    /// Three dashes alone is a thematic break, not a list item -- the fast path must never
    /// settle it as `.listItem` early.
    func testChunking_PendingLine_TripleDash_IsThematicBreakNotListItem() {
        assertChunkingInvariant("---\n\n")
    }

    /// Pathological case that stays ambiguous (marker-or-space only) until the very end --
    /// exercises the fast path's "never settle" fallback, not just its happy path.
    func testChunking_PendingLine_DashSpaceDash_StaysAmbiguousUntilResolved() {
        assertChunkingInvariant("- - -\n\n")
        assertChunkingInvariant("- - not a break\n\n")
    }

    func testChunking_PendingLine_OrderedListStart() {
        assertChunkingInvariant("1. first ordered item\n2. second\n\n")
    }

    func testChunking_PendingLine_PlusMarker_SettlesImmediately() {
        assertChunkingInvariant("+ plus-marker item\n\n")
    }

    func testChunking_PendingLine_TableHeaderThenDelimiterRow() {
        assertChunkingInvariant("| a | b |\n|---|---|\n| 1 | 2 |\n\n")
    }

    func testChunking_PendingLine_Blockquote_SettlesFromFirstChar() {
        assertChunkingInvariant("> quoted text growing longer and longer\n\n")
    }

    func testChunking_PendingLine_Heading_StaysOnSlowPath() {
        assertChunkingInvariant("# Heading growing longer and longer\n\n")
    }

    /// Headings aren't fast-pathed (see `PendingLineFastPath`'s doc comment), but the slow
    /// `atxHeading` trailing-hash-strip rule is subtle enough to deserve explicit prefix
    /// coverage: trailing "###" is stripped only when preceded by whitespace-or-nothing.
    func testChunking_Heading_TrailingHashStrip_OnlyWhenPrecededByWhitespace() {
        assertChunkingInvariant("# Hello ###\n\n")   // stripped -- space precedes the hash run
        assertChunkingInvariant("# Hello###\n\n")    // NOT stripped -- 'o' precedes the hash run
        assertChunkingInvariant("# Hello #\n\n")     // stripped -- single trailing hash
        assertChunkingInvariant("#######\n\n")       // level 7 -- not a heading at all, paragraph
    }

    /// A line that starts out looking like plain paragraph text but is actually the opener of
    /// a fence -- the fast path's trigger-char gate must not have already (wrongly) committed
    /// to `.paragraph` before the backtick run is even seen.
    func testChunking_PendingLine_PlainTextThenFenceOpener() {
        assertChunkingInvariant("```swift\nlet x = 1\n```\n\n")
    }

    // MARK: - Mixed document

    func testChunking_MixedDocument_AllBlockKindsInOneStream() {
        assertChunkingInvariant("""
        # Title

        Some intro paragraph with **bold** text.

        | a | b |
        |---|---|
        | 1 | 2 |

        - list item one
        - list item two

        > a quote

        ```swift
        let x = 1
        ```

        ![alt](https://example.com/img.png)

        ---

        $$
        x^2
        $$

        """)
    }

    // MARK: - BlockID stability under character-by-character chunking

    func testBlockIDStability_CodeFence_GrowsWithoutReassigningID() {
        assertBlockIDStabilityUnderCharacterChunking("```swift\nlet x = 1\nlet y = 2\n```\n\n")
    }

    func testBlockIDStability_MixedDocument() {
        assertBlockIDStabilityUnderCharacterChunking("""
        # Title

        Some intro paragraph with **bold** text.

        - list item one
        - list item two

        """)
    }
}

// IncrementalMarkdownParser+TestHooks.swift

import Foundation
import CoreGraphics

extension IncrementalMarkdownParser {

    /// Full-rescan result: everything sealed, everything still hot, and the source index the
    /// scan cut sealed from hot at.
    struct TailParseResult {
        var sealed: [ParsedMDBlock]
        var hot: [ParsedMDBlock]
        var cutIndex: String.Index
    }

    /// Line-by-line scan of an ENTIRE source string from scratch: everything before the last
    /// unprotected blank line (not inside an open fence or container) is sealed. A just-closed
    /// fence is an additional, unconditional seal point — CommonMark never reopens a closed
    /// block. Not used by `append(_:)` (see `HotScanState`/`step(_:into:)` in
    /// `IncrementalMarkdownParser+HotScan.swift`, which resumes instead of rescanning) — this
    /// is the full-rescan reference oracle the differential chunking-invariance tests compare
    /// the resumable scanner's output against.
    static func referenceParseTail(_ source: String) -> TailParseResult {
        var blocks: [ParsedMDBlock] = []
        var pendingSealBlockCount = 0
        var pendingSealCut = source.startIndex

        // Lines, each paired with the source index just past its line terminator (or
        // `source.endIndex` for a final, still-being-typed unterminated line).
        var lines: [(text: Substring, lineEnd: String.Index)] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if let newline = source[cursor...].firstIndex(of: "\n") {
                let lineEnd = source.index(after: newline)
                lines.append((source[cursor..<newline], lineEnd))
                cursor = lineEnd
            } else {
                lines.append((source[cursor...], source.endIndex))
                cursor = source.endIndex
            }
        }

        var openKind: MarkdownBlockKind?
        var openLines: [Substring] = []
        var inFence = false
        var fenceMarker: Substring = ""
        var inMathBlock = false
        var mathBlockCloseMarker = ""
        var inContainer = false
        var containerBlankSeen = false
        var containerBlankCut: (index: String.Index, count: Int)?

        func finalizeOpenBlock() {
            guard let kind = openKind, !openLines.isEmpty else { return }
            blocks.append(Self.makeParsedBlock(kind: kind, lines: openLines))
            openKind = nil
            openLines = []
        }

        for (line, lineEnd) in lines {
            if inFence {
                openLines.append(line)
                if isFenceCloseShapedLine(line, opening: fenceMarker) {
                    inFence = false
                    finalizeOpenBlock()
                    // A closed fence is an unconditional seal point — see doc comment.
                    pendingSealCut = lineEnd
                    pendingSealBlockCount = blocks.count
                }
                continue
            }

            if inMathBlock {
                openLines.append(line)
                if line.trimmingCharacters(in: .whitespaces) == mathBlockCloseMarker {
                    inMathBlock = false
                    finalizeOpenBlock()
                    // A closed math block is an unconditional seal point, same as a closed fence.
                    pendingSealCut = lineEnd
                    pendingSealBlockCount = blocks.count
                }
                continue
            }

            if isBlankLine(line) {
                if inContainer {
                    containerBlankSeen = true
                    containerBlankCut = (lineEnd, blocks.count)
                    continue
                }
                finalizeOpenBlock()
                pendingSealCut = lineEnd
                pendingSealBlockCount = blocks.count
                continue
            }

            if let (marker, language) = fenceOpenMarker(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                inFence = true
                fenceMarker = marker
                openKind = .codeFence(language: language)
                openLines = [line]
                continue
            }

            if let (closeMarker, rest) = mathBlockOpenMarker(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                if rest.range(of: closeMarker) != nil {
                    // Same-line close ("$$ E=mc^2 $$") — a one-line block, finalized right away
                    // like a heading/thematic-break; `style()` strips both markers at render.
                    openKind = .mathBlock
                    openLines = [line]
                    finalizeOpenBlock()
                    continue
                }
                inMathBlock = true
                mathBlockCloseMarker = closeMarker
                openKind = .mathBlock
                openLines = [line]
                continue
            }

            if let (level, headingText) = atxHeading(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                openKind = .heading(level: level)
                openLines = [Substring(headingText)]
                finalizeOpenBlock()
                continue
            }

            if case .paragraph = openKind, openLines.count == 1, let level = setextUnderlineLevel(line) {
                openKind = .heading(level: level)
                continue
            }

            if isThematicBreakLine(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                openKind = .thematicBreak
                openLines = [line]
                finalizeOpenBlock()
                continue
            }

            if let url = imageLineURL(line) {
                finalizeOpenBlock()
                inContainer = false
                containerBlankSeen = false
                openKind = .image(url: url)
                openLines = [line]
                finalizeOpenBlock()
                continue
            }

            if case .paragraph = openKind, openLines.count == 1, openLines[0].contains("|"),
               let alignments = tableDelimiterRowAlignments(line) {
                openKind = .table(alignments: alignments)
                openLines.append(line)
                continue
            }
            if case .table = openKind, line.contains("|") {
                openLines.append(line)
                continue
            }

            // A fresh column-0, non-marker line after a blank was seen inside an open container
            // definitively closes it — retroactively promotes the withheld blank-line seal.
            if inContainer, containerBlankSeen, !isListMarkerLine(line), !isBlockquoteMarkerLine(line), leadingSpaceCount(line) == 0 {
                inContainer = false
                containerBlankSeen = false
                if let cut = containerBlankCut {
                    pendingSealCut = cut.index
                    pendingSealBlockCount = cut.count
                }
                containerBlankCut = nil
            }

            if let info = listMarkerInfo(line) {
                finalizeOpenBlock()
                inContainer = true
                containerBlankSeen = false
                openKind = .listItem(ordered: info.ordered, number: info.number, depth: info.depth, checked: info.checked)
                openLines = [line]
                finalizeOpenBlock()  // each list marker line is its own block
                continue
            }
            if isBlockquoteMarkerLine(line) {
                if case .blockquote = openKind {
                    openLines.append(line)
                } else {
                    finalizeOpenBlock()
                    openKind = .blockquote
                    openLines = [line]
                }
                inContainer = true
                containerBlankSeen = false
                continue
            }

            if openKind == nil {
                openKind = .paragraph
                openLines = [line]
            } else if case .paragraph = openKind {
                openLines.append(line)
            } else {
                finalizeOpenBlock()
                openKind = .paragraph
                openLines = [line]
            }
        }

        // Whatever remains open stays hot — not finalized here, so it never looks sealed.
        let sealedCount = min(pendingSealBlockCount, blocks.count)
        let sealed = Array(blocks[0..<sealedCount])
        var hot = Array(blocks[sealedCount...])
        if let kind = openKind, !openLines.isEmpty {
            hot.append(Self.makeParsedBlock(kind: kind, lines: openLines))
        }
        return TailParseResult(sealed: sealed, hot: hot, cutIndex: pendingSealCut)
    }
}

#if canImport(XCTest)
extension IncrementalMarkdownParser {
    /// Debug check: does `previous`'s sealed prefix still match `sealedBlocks` at the same
    /// positions? Used by tests to confirm a resumable scan never rewrites a block it already
    /// sealed.
    func debugSealedPrefixMatches<ID: Hashable & Sendable>(_ previous: [Block], itemID: ID, width: CGFloat) -> Bool {
        let current = blockList(itemID: itemID, width: width)
        let count = min(previous.count, sealedBlocks.count)
        for i in 0..<count {
            guard previous[i].key == current[i].key, previous[i].contentHash == current[i].contentHash else { return false }
        }
        return true
    }
}
#endif

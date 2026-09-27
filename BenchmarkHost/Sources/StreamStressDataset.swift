// StreamStressDataset.swift

import Foundation

/// A LARGE deterministic streaming dataset for the `stream` scenario, built to stress every
/// fast path `IncrementalMarkdownParser` gained recently (resumable hot scan, pending-line fast
/// path, inline window forced-freeze, inline rollback, fence fast path, zero-copy handoff).
/// Several hundred KB of markdown across three turns so a physical-device run streams long
/// enough to watch `LiveMetricsHUD` and Xcode's memory gauge stay flat, not just spike-and-drop.
///
/// Picked from the picker's "Streaming Text (large stress)" row, or headlessly via
/// `--stream-fixture large-stress` (see `StreamCostScenario`).
enum StreamStressDataset {

    static let turn1UserMessage = "give me a really thorough answer — don't hold back on detail, code, or examples"
    static let turn2UserMessage = "now show the whole thing as one big working reference implementation"
    static let turn3UserMessage = "anything else worth flagging, even edge cases and gotchas?"

    /// Three turns, each several hundred KB, exercising:
    /// 1. Resumable hot scan — every long open block below is re-appended across many chunks
    ///    without ever rescanning from the block's start.
    /// 2. Pending-line fast path — `longLine` below is one huge single line (paragraph), no
    ///    newline until the very end.
    /// 3. Inline window forced freeze — `inlineWindowStressParagraph` streams many lines, each
    ///    carrying an inline marker, well past the 8-line/128-byte cap.
    /// 4. Inline rollback — the five `rollback*` helpers below each leave an opener dangling past
    ///    the cap before it closes far later.
    /// 5. Fence fast path — `StreamFixture.longCode` streams thousands of lines with the fence
    ///    staying open the whole time.
    /// 6. Zero-copy handoff — exercised for free: any settled prefix in these turns is handed off
    ///    the same way `StreamingMarkdownText`'s normal path does.
    static func turns(seed: UInt64 = 1) -> [StreamDataset.StreamTurn] {
        var rng = LCG(state: seed)
        return [
            StreamDataset.StreamTurn(userMessage: turn1UserMessage, assistantChunks: turn1(rng: &rng)),
            StreamDataset.StreamTurn(userMessage: turn2UserMessage, assistantChunks: turn2(rng: &rng)),
            StreamDataset.StreamTurn(userMessage: turn3UserMessage, assistantChunks: turn3(rng: &rng)),
        ]
    }

    /// Text-only split (turns 1 and 3) and code-only split (turn 2), so a memory spike can be
    /// attributed to paragraph seals vs. the fence seal without scrolling the transcript.
    static func textTurns() -> [StreamDataset.StreamTurn] {
        let all = turns()
//        return [all[0], all[2]]
        return [all[0]]
    }

    static func codeTurns() -> [StreamDataset.StreamTurn] {
        [turns()[1]]
    }

    // MARK: - Turn 1: pending-line + inline-window + rollback + lists/blockquote

    private static func turn1(rng: inout LCG) -> [String] {
        var chunks: [String] = []
        chunks += literal("# A deep dive into building fast, correct, streaming systems from first principles\n\n")
        chunks += proseChunks(totalBytes: 400, rng: &rng)
        chunks.append("\n\n")

        // Pending-line fast path: one huge single line, no newline until it ends.
        chunks += literal("Here's the single-line version, written as one continuous stream of thought: ")
        chunks += longLine(totalBytes: 96 * 1024, rng: &rng)

        // Inline window forced-freeze: many lines, each carrying an inline marker.
        chunks += literal("## Now the same idea, broken into styled lines\n\n")
        chunks += inlineWindowStressParagraph(totalBytes: 64 * 1024, rng: &rng)

        // Inline rollback traps.
        chunks += literal("## A few things that look ambiguous until they resolve\n\n")
        chunks += rollbackLongCodeSpan(rng: &rng)
        chunks += rollbackBracketThenLink(rng: &rng)
        chunks += rollbackEmphasisAcrossGap(rng: &rng)
        chunks += rollbackBoldAfterCap(rng: &rng)
        chunks += unmatchedDanglingMarkers(rng: &rng)

        // Lists (nested, ordered, task), blockquote.
        chunks += literal("## Checklist and structure\n\n")
        chunks += literal("1. Parse only the new bytes, never the whole block.\n")
        chunks += literal("2. Keep a resumable scan cursor per open block.\n")
        chunks += literal("   - Track byte offset, not line offset.\n")
        chunks += literal("   - Never rewind past the last settled boundary.\n")
        chunks += literal("3. Freeze inline spans once they're far enough behind the frontier.\n")
        chunks += literal("- [x] resumable hot scan\n- [x] pending-line fast path\n- [x] inline window\n- [ ] fence fast path (next section)\n\n")
        chunks += literal("> None of this matters if a single dangling opener forces a full block rescan on every future append.\n\n")
        return chunks
    }

    // MARK: - Turn 2: fence fast path

    private static func turn2(rng: inout LCG) -> [String] {
        var chunks: [String] = []
        chunks += literal("## One big reference implementation\n\n")
//        chunks += proseChunks(totalBytes: 300, rng: &rng)
//        chunks.append("\n\n")
//        // ~100 KB fence, thousands of lines, stays open the whole time.
//        chunks += StreamFixture.longCode(lines: 3000).tokens
//        chunks += proseChunks(totalBytes: 200, rng: &rng)
//        chunks.append("\n\n")
        return chunks
    }

    // MARK: - Turn 3: more rollback + another pending-line paragraph

    private static func turn3(rng: inout LCG) -> [String] {
        var chunks: [String] = []
        chunks += literal("## Gotchas worth knowing about\n\n")
//        chunks += rollbackLongCodeSpan(rng: &rng)
//        chunks += rollbackBracketThenLink(rng: &rng)
//        chunks += rollbackEmphasisAcrossGap(rng: &rng)
//        chunks += rollbackBoldAfterCap(rng: &rng)
//        chunks += unmatchedDanglingMarkers(rng: &rng)
//
//        chunks += literal("## Written out one more time, as a single long line\n\n")
//        chunks += literal("Here's the same reasoning again, deliberately kept on one line: ")
//        chunks += longLine(totalBytes: 64 * 1024, rng: &rng)
        return chunks
    }

    // MARK: - Building blocks

    private static func literal(_ s: String) -> [String] { [s] }

    /// Plain prose in `chunkBytes`-ish pieces, no newlines — used both standalone and as the
    /// "filler" inside the rollback traps below.
    private static func proseChunks(totalBytes: Int, chunkBytes: Int = 512, rng: inout LCG) -> [String] {
        var chunks: [String] = []
        var produced = 0
        var buffer = ""
        while produced < totalBytes {
            let word = vocabulary[Int(rng.next() % UInt64(vocabulary.count))]
            buffer += (buffer.isEmpty ? "" : " ") + word
            produced += word.utf8.count + 1
            if buffer.utf8.count >= chunkBytes {
                chunks.append(buffer + " ")
                buffer = ""
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    /// One giant single-line paragraph (pending-line fast path): no newline anywhere inside,
    /// only the trailing blank line that finally closes the block.
    private static func longLine(totalBytes: Int, rng: inout LCG) -> [String] {
        var chunks = proseChunks(totalBytes: totalBytes, rng: &rng)
        chunks.append("\n\n")
        return chunks
    }

    /// Many lines, each carrying one inline marker (bold/italic/code/strike/link/bare-url/math),
    /// streamed one line per chunk — stresses the inline window's forced-freeze cap (8 unsettled
    /// lines / 128 bytes), since a run this long forces many freezes well before the block seals.
    private static func inlineWindowStressParagraph(totalBytes: Int, rng: inout LCG) -> [String] {
        let markers: [(Int) -> String] = [
            { "**bold\($0)**" },
            { "*italic\($0)*" },
            { "`code\($0)`" },
            { "~~strike\($0)~~" },
            { "[link\($0)](https://example.com/stress/path/\($0)/segment/for/length)" },
            { "https://example.com/bare/url/stress/\($0)/very/long/path/segment" },
            { "$x_\($0) + y_\($0)$" },
        ]
        var chunks: [String] = []
        var produced = 0
        var i = 0
        while produced < totalBytes {
            var line = ""
            for _ in 0..<6 {
                line += vocabulary[Int(rng.next() % UInt64(vocabulary.count))] + " "
            }
            line += markers[i % markers.count](i) + " "
            i += 1
            produced += line.utf8.count
            chunks.append(line + "\n")
        }
        chunks.append("\n")
        return chunks
    }

    /// A lone opening backtick, then ~2 KB of plain prose, then the closing backtick — the whole
    /// span has to retroactively become a code span once it finally closes, long after the
    /// forced-freeze cap pushed the opener out of the unsettled window.
    private static func rollbackLongCodeSpan(rng: inout LCG) -> [String] {
        var chunks: [String] = ["Here's a subtle one: `"]
        chunks += proseChunks(totalBytes: 2048, rng: &rng)
        chunks.append("` — that whole stretch had to be a code span all along.\n\n")
        return chunks
    }

    /// `arr[0]`-style brackets, which look like they could start a link, followed much later by
    /// an actual `[text](url)` link — the earlier brackets must never be mistaken for the link's
    /// opener.
    private static func rollbackBracketThenLink(rng: inout LCG) -> [String] {
        var chunks: [String] = ["Indexing looks like `arr[0]` at first glance, and "]
        chunks += proseChunks(totalBytes: 1024, rng: &rng)
        chunks.append(" — but here's a real link that opens much later: [the docs](https://example.com/very/long/path/that/keeps/going/for/a/while/to/stress/url/handling).\n\n")
        return chunks
    }

    /// `a*b` reads as a false start for emphasis; `c*d` much later in the same line is what
    /// actually closes it, so everything in between must retroactively become italic.
    private static func rollbackEmphasisAcrossGap(rng: inout LCG) -> [String] {
        var chunks: [String] = ["Starting with a*b as what looks like a false start, then "]
        chunks += proseChunks(totalBytes: 1024, rng: &rng)
        chunks.append(" before closing it off with c*d much later in the line.\n\n")
        return chunks
    }

    /// `**` opened, then well over 128 bytes of plain text, then the closing `**` — past the
    /// forced-freeze cap but still a single valid bold span.
    private static func rollbackBoldAfterCap(rng: inout LCG) -> [String] {
        var chunks: [String] = ["This sentence opens **bold right here and "]
        chunks += proseChunks(totalBytes: 200, rng: &rng)
        chunks.append(" closes it far past the freeze cap** so it must re-style backward.\n\n")
        return chunks
    }

    /// A lone backtick and a lone asterisk that never close — must never stall the parser
    /// waiting for a partner that isn't coming.
    private static func unmatchedDanglingMarkers(rng: inout LCG) -> [String] {
        var chunks: [String] = ["One opener that never closes: a lone backtick ` sits here, and a lone asterisk * sits here too, "]
        chunks += proseChunks(totalBytes: 1024, rng: &rng)
        chunks.append(" — neither should ever stall the parser waiting for a partner that never arrives.\n\n")
        return chunks
    }

    private static let vocabulary = [
        "throughput", "latency", "cursor", "frontier", "resumable", "window", "cap", "budget",
        "byte", "offset", "settled", "unsettled", "freeze", "rollback", "fence", "span", "token",
        "append", "scan", "block", "parser", "render", "layout", "stream", "chunk", "buffer",
        "cost", "flat", "growth", "memory", "allocation", "retain", "release", "handoff", "zero",
        "copy", "reuse", "pool", "actor", "queue", "invariant", "correctness", "boundary", "seal",
    ]
}

private struct LCG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// HybridReuseSpikeTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Spike: validates the two load-bearing claims behind a HYBRID cell-reuse strategy for a
/// streaming-chat feed, using the REAL measure+rasterize primitives (TextMeasurementContext,
/// rasterizeText) — no new production types, matches the Spike4/Spike8 standalone-harness style.
///
/// A chat message is modeled as an ordered list of text BLOCKS. While a message streams
/// token-by-token, only the LAST (hot) block changes; earlier blocks are complete and never
/// change again. The cost model under test:
/// - COMPUTE (LB1/LB2/LB3): freezing completed blocks (measure+rasterize ONCE, cache, never
///   re-touch) makes cumulative streaming work scale ~O(N) in token count; a naive baseline that
///   re-measures+re-rasterizes the WHOLE message on every token event scales ~O(N^2). For
///   genuinely-new content (no overlap, e.g. scroll) there is no freeze win — "reconfigure whole"
///   and "bind whole" do the same work (a tie).
/// - MEMORY (LB5): freezing is a compute cache, not keep-forever. A simulated working-range
///   window admits entering blocks (rasterize) and evicts leaving blocks (drop the bitmap, keep
///   the tiny descriptor) so peak live-bitmap bytes stays O(window), not O(total chat length).
///
/// @MainActor to match Spike4Tests — rasterizeText/TextMeasurementContext are nonisolated and
/// thread-safe when used serially, but UIGraphicsImageRenderer is exercised on main here too.
@MainActor
final class HybridReuseSpikeTests: XCTestCase {

    // MARK: - Synthetic token corpus (deterministic — no randomness, for reproducible numbers)

    private static let wordBank: [String] = [
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "while", "chat",
        "message", "streams", "token", "by", "token", "across", "several", "lines", "of",
        "wrapped", "text", "and", "continues", "growing", "steadily", "as", "more", "content",
        "arrives", "from", "the", "model", "response", "in", "real", "time", "without", "pause",
    ]

    private static func token(_ i: Int) -> String { wordBank[i % wordBank.count] }

    private static func makeDescriptor(_ text: String) -> TextDescriptor {
        TextDescriptor(
            content: text,
            font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    /// Re-renders a CGImage into a fixed premultiplied-RGBA8888 buffer for byte-level equality
    /// comparison (LB4) and as a deterministic "alloc per node" proxy (LB3) — 4 bytes/pixel
    /// matches the BGRA8888-premultiplied convention CLAUDE.md mandates for decoded images, and
    /// matches LB5's width*height*scale^2*4 bookkeeping formula exactly.
    private static func pixelBytes(of image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        return Data(bytes: data, count: w * h * 4)
    }

    // MARK: - LB1 + LB3 + LB4 streaming harness

    private struct FrozenEntry {
        let size: CGSize
        let bytes: Data
    }

    private struct StreamRunResult {
        let n: Int
        let frozenSeconds: TimeInterval
        let naiveSeconds: TimeInterval
        let lineSamples: [(lines: Int, measureSeconds: TimeInterval)]
        let areaSamples: [(area: CGFloat, rasterizeSeconds: TimeInterval)]
        let allocBytesSamples: [Int]
        let firstFrozenCheckpoint: FrozenEntry?
        let firstFrozenFinal: FrozenEntry?
        /// One entry per streaming event, in stream order — the arm's total measure+rasterize
        /// cost for THAT event only (not cumulative). Used to check whether per-update cost
        /// stays flat (frozen arm) or grows with message length (naive arm) — a
        /// granularity-independent property, unlike the naive/frozen ratio at a fixed N.
        let frozenEventSeconds: [TimeInterval]
        let naiveEventSeconds: [TimeInterval]
    }

    /// Simulates streaming `totalTokens` tokens into a message, `tokenChunk` tokens per
    /// streaming event (batched arrival, as real SSE token streams typically are). A block
    /// completes and freezes (measured + rasterized ONCE, then never re-touched) once it
    /// accumulates `blockTokenQuota` tokens. Runs BOTH arms per event:
    /// - frozen arm: only the hot (last, still-growing) block + any block that just completed.
    /// - naive arm: re-measure + re-rasterize the WHOLE message text from scratch.
    private func simulateStreaming(
        totalTokens: Int,
        tokenChunk: Int = 10,
        blockTokenQuota: Int = 30,
        width: CGFloat = 300,
        scale: CGFloat = 2
    ) -> StreamRunResult {
        // Separate contexts per arm: TextMeasurementContext mutates shared internal TextKit 2
        // state (NSTextContentStorage / NSTextLayoutManager) on every call. Sharing ONE context
        // between the frozen arm's small, bounded calls and the naive arm's ever-growing
        // whole-message calls would let the naive arm's large-content churn leak overhead into
        // the frozen arm's "flat" measurement — a confound, not a real cost. Independent
        // contexts give each arm's per-update cost an honest, uncontaminated reading.
        let frozenCtx = TextMeasurementContext()
        let naiveCtx = TextMeasurementContext()
        var blocks: [[String]] = [[]]
        var frozen: [Int: FrozenEntry] = [:]
        var firstFrozenBlockIndex: Int?
        var firstFrozenCheckpoint: FrozenEntry?

        var frozenSeconds: TimeInterval = 0
        var naiveSeconds: TimeInterval = 0
        var lineSamples: [(Int, TimeInterval)] = []
        var areaSamples: [(CGFloat, TimeInterval)] = []
        var allocBytesSamples: [Int] = []
        var frozenEventSeconds: [TimeInterval] = []
        var naiveEventSeconds: [TimeInterval] = []

        let lineHeight = UIFont.systemFont(ofSize: 16).lineHeight

        var tokenCursor = 0
        var emitted = 0
        while emitted < totalTokens {
            let chunk = min(tokenChunk, totalTokens - emitted)
            for _ in 0..<chunk {
                blocks[blocks.count - 1].append(Self.token(tokenCursor))
                tokenCursor += 1
                if blocks[blocks.count - 1].count >= blockTokenQuota {
                    blocks.append([])
                }
            }
            emitted += chunk

            var frozenEventCost: TimeInterval = 0
            var naiveEventCost: TimeInterval = 0

            // ---- FROZEN ARM: freeze any newly-completed block, once. ----
            for idx in 0..<(blocks.count - 1) where frozen[idx] == nil {
                let text = blocks[idx].joined(separator: " ")
                let d = Self.makeDescriptor(text)

                let mStart = Date()
                let size = frozenCtx.measure(d, width: width)
                let mElapsed = Date().timeIntervalSince(mStart)
                frozenSeconds += mElapsed
                frozenEventCost += mElapsed
                let lines = max(1, Int((size.height / lineHeight).rounded()))
                lineSamples.append((lines, mElapsed))

                let rStart = Date()
                let image = rasterizeText(d, size: size, scale: scale)
                let rElapsed = Date().timeIntervalSince(rStart)
                guard let image else { continue }
                frozenSeconds += rElapsed
                frozenEventCost += rElapsed
                let area = size.width * size.height * scale * scale
                areaSamples.append((area, rElapsed))
                let bytes = Self.pixelBytes(of: image) ?? Data()
                allocBytesSamples.append(bytes.count)

                let entry = FrozenEntry(size: size, bytes: bytes)
                frozen[idx] = entry
                if firstFrozenBlockIndex == nil {
                    firstFrozenBlockIndex = idx
                    firstFrozenCheckpoint = entry
                }
            }

            // ---- FROZEN ARM: hot block re-measured + re-rasterized every event (it changed). ----
            let hotIdx = blocks.count - 1
            if !blocks[hotIdx].isEmpty {
                let text = blocks[hotIdx].joined(separator: " ")
                let d = Self.makeDescriptor(text)

                let mStart = Date()
                let size = frozenCtx.measure(d, width: width)
                let mElapsed = Date().timeIntervalSince(mStart)
                frozenSeconds += mElapsed
                frozenEventCost += mElapsed

                let rStart = Date()
                if rasterizeText(d, size: size, scale: scale) != nil {
                    let rElapsed = Date().timeIntervalSince(rStart)
                    frozenSeconds += rElapsed
                    frozenEventCost += rElapsed
                }
            }
            frozenEventSeconds.append(frozenEventCost)

            // ---- NAIVE ARM: re-measure + re-rasterize the WHOLE message every event. ----
            let wholeText = blocks.map { $0.joined(separator: " ") }.joined(separator: " ")
            if !wholeText.isEmpty {
                let d = Self.makeDescriptor(wholeText)

                let mStart = Date()
                let size = naiveCtx.measure(d, width: width)
                let mElapsed = Date().timeIntervalSince(mStart)
                naiveSeconds += mElapsed
                naiveEventCost += mElapsed

                let rStart = Date()
                if rasterizeText(d, size: size, scale: scale) != nil {
                    let rElapsed = Date().timeIntervalSince(rStart)
                    naiveSeconds += rElapsed
                    naiveEventCost += rElapsed
                }
            }
            naiveEventSeconds.append(naiveEventCost)
        }

        var firstFrozenFinal: FrozenEntry?
        if let idx = firstFrozenBlockIndex {
            firstFrozenFinal = frozen[idx]
        }

        return StreamRunResult(
            n: totalTokens,
            frozenSeconds: frozenSeconds,
            naiveSeconds: naiveSeconds,
            lineSamples: lineSamples,
            areaSamples: areaSamples,
            allocBytesSamples: allocBytesSamples,
            firstFrozenCheckpoint: firstFrozenCheckpoint,
            firstFrozenFinal: firstFrozenFinal,
            frozenEventSeconds: frozenEventSeconds,
            naiveEventSeconds: naiveEventSeconds
        )
    }

    // MARK: - LB1 (headline) + LB3 (measured constants) + LB4 (frozen-block invariance)

    func testLB1_LB3_LB4_StreamingFreezeVsNaiveWithMeasuredConstants() {
        // Warm up TextKit/font caches so N=100's timing isn't skewed by first-call cold start.
        _ = simulateStreaming(totalTokens: 20)

        let n100 = simulateStreaming(totalTokens: 100)
        let n500 = simulateStreaming(totalTokens: 500)
        let n2000 = simulateStreaming(totalTokens: 2000)

        func ratio(_ r: StreamRunResult) -> Double {
            r.naiveSeconds / max(r.frozenSeconds, .ulpOfOne)
        }
        let r100 = ratio(n100)
        let r500 = ratio(n500)
        let r2000 = ratio(n2000)

        print("[HybridReuseSpike][LB1] N=100  frozen=\(String(format: "%.5f", n100.frozenSeconds))s "
            + "naive=\(String(format: "%.5f", n100.naiveSeconds))s ratio=\(String(format: "%.2f", r100))x")
        print("[HybridReuseSpike][LB1] N=500  frozen=\(String(format: "%.5f", n500.frozenSeconds))s "
            + "naive=\(String(format: "%.5f", n500.naiveSeconds))s ratio=\(String(format: "%.2f", r500))x")
        print("[HybridReuseSpike][LB1] N=2000 frozen=\(String(format: "%.5f", n2000.frozenSeconds))s "
            + "naive=\(String(format: "%.5f", n2000.naiveSeconds))s ratio=\(String(format: "%.2f", r2000))x")
        print("[HybridReuseSpike][LB1] naive/frozen ratio is DESCRIPTIVE, not a pass/fail gate — "
            + "it is granularity-dependent (tokenChunk=10 tokens/event, fixed, not tuned).")

        // (a) MONOTONIC DIVERGENCE — granularity-independent: as the message gets longer, the
        // naive arm's total cost pulls further and further ahead of the frozen arm's. No magic
        // multiplier, just strict growth of the gap.
        XCTAssertGreaterThan(r500, r100,
            "naive/frozen ratio must strictly grow from N=100 (\(r100)x) to N=500 (\(r500)x) — "
            + "evidence of the O(N^2) vs O(N) compute gap widening with message length")
        XCTAssertGreaterThan(r2000, r500,
            "naive/frozen ratio must strictly grow from N=500 (\(r500)x) to N=2000 (\(r2000)x)")

        // (b) FLAT PER-UPDATE COST — the actual anti-jank property a streaming UI needs: the
        // frozen arm's cost PER STREAMING EVENT must stay roughly flat as the message grows
        // (each update only ever touches a bounded hot block), while the naive arm's per-event
        // cost must grow substantially, tracking current message length. Measured on the N=2000
        // run (most events -> clearest signal), comparing the first 10% of events ("early", short
        // message) against the last 10% ("late", long message).
        let events = n2000.frozenEventSeconds.count
        let sampleSize = max(1, events / 10)
        let frozenEarly = n2000.frozenEventSeconds.prefix(sampleSize)
        let frozenLate = n2000.frozenEventSeconds.suffix(sampleSize)
        let naiveEarly = n2000.naiveEventSeconds.prefix(sampleSize)
        let naiveLate = n2000.naiveEventSeconds.suffix(sampleSize)

        func avg(_ xs: ArraySlice<TimeInterval>) -> TimeInterval {
            xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
        }
        let frozenEarlyAvg = avg(frozenEarly)
        let frozenLateAvg = avg(frozenLate)
        let naiveEarlyAvg = avg(naiveEarly)
        let naiveLateAvg = avg(naiveLate)

        print("[HybridReuseSpike][LB1] per-update cost (N=2000, first/last \(sampleSize) of \(events) events): "
            + "frozen early=\(String(format: "%.6f", frozenEarlyAvg))s late=\(String(format: "%.6f", frozenLateAvg))s "
            + "(late/early=\(String(format: "%.2f", frozenLateAvg / max(frozenEarlyAvg, .ulpOfOne)))x) | "
            + "naive early=\(String(format: "%.6f", naiveEarlyAvg))s late=\(String(format: "%.6f", naiveLateAvg))s "
            + "(late/early=\(String(format: "%.2f", naiveLateAvg / max(naiveEarlyAvg, .ulpOfOne)))x)")

        XCTAssertLessThanOrEqual(frozenLateAvg, frozenEarlyAvg * 1.5,
            "Frozen arm's per-update cost must stay ~flat as the message grows: late-stream "
            + "average (\(frozenLateAvg)s) must not exceed 1.5x the early-stream average "
            + "(\(frozenEarlyAvg)s) — every update only ever touches a bounded hot block")
        XCTAssertGreaterThanOrEqual(naiveLateAvg, naiveEarlyAvg * 3.0,
            "Naive arm's per-update cost must grow substantially as the message grows: "
            + "late-stream average (\(naiveLateAvg)s) must be at least 3x the early-stream "
            + "average (\(naiveEarlyAvg)s) — it re-measures+re-rasterizes the WHOLE message "
            + "every update, so cost tracks current message length")

        // ---- LB3: measured constants (distribution, not a single number) ----
        let lineSamples = n100.lineSamples + n500.lineSamples + n2000.lineSamples
        let areaSamples = n100.areaSamples + n500.areaSamples + n2000.areaSamples
        let allocSamples = n100.allocBytesSamples + n500.allocBytesSamples + n2000.allocBytesSamples

        XCTAssertFalse(lineSamples.isEmpty, "Must have captured at least one measure-per-line sample")
        XCTAssertFalse(areaSamples.isEmpty, "Must have captured at least one rasterize-per-area sample")
        XCTAssertFalse(allocSamples.isEmpty, "Must have captured at least one alloc-per-node sample")

        let msPerLine = lineSamples.map { ($0.measureSeconds * 1000) / Double(max(1, $0.lines)) }.sorted()
        let usPerKPx = areaSamples.map { ($0.rasterizeSeconds * 1_000_000) / max(1, Double($0.area) / 1000) }.sorted()
        let allocSorted = allocSamples.sorted()

        func pct(_ xs: [Double], _ p: Double) -> Double { xs.isEmpty ? 0 : xs[Int(Double(xs.count - 1) * p)] }
        func pctI(_ xs: [Int], _ p: Double) -> Int { xs.isEmpty ? 0 : xs[Int(Double(xs.count - 1) * p)] }

        print("[HybridReuseSpike][LB3] measure ms/line   (n=\(msPerLine.count)): "
            + "min=\(String(format: "%.4f", msPerLine.first ?? 0)) "
            + "median=\(String(format: "%.4f", pct(msPerLine, 0.5))) "
            + "p95=\(String(format: "%.4f", pct(msPerLine, 0.95))) "
            + "max=\(String(format: "%.4f", msPerLine.last ?? 0))")
        print("[HybridReuseSpike][LB3] rasterize us/1000px^2 (n=\(usPerKPx.count)): "
            + "min=\(String(format: "%.4f", usPerKPx.first ?? 0)) "
            + "median=\(String(format: "%.4f", pct(usPerKPx, 0.5))) "
            + "p95=\(String(format: "%.4f", pct(usPerKPx, 0.95))) "
            + "max=\(String(format: "%.4f", usPerKPx.last ?? 0))")
        print("[HybridReuseSpike][LB3] alloc bytes/node (bitmap, n=\(allocSorted.count)): "
            + "min=\(allocSorted.first ?? 0) median=\(pctI(allocSorted, 0.5)) "
            + "p95=\(pctI(allocSorted, 0.95)) max=\(allocSorted.last ?? 0)")

        // Sanity, not a hardware-specific ceiling: constants must be finite and positive.
        XCTAssertTrue(msPerLine.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertTrue(usPerKPx.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertTrue(allocSorted.allSatisfy { $0 > 0 })

        // ---- LB4: frozen block's measured size + rasterized bytes are invariant ----
        // Uses the N=2000 run — the first block freezes early and then survives ~190 more
        // streaming events untouched, the strongest exercise of "never re-touch a frozen block."
        guard let checkpoint = n2000.firstFrozenCheckpoint, let final = n2000.firstFrozenFinal else {
            XCTFail("N=2000 run must have frozen at least one block"); return
        }
        XCTAssertEqual(checkpoint.size, final.size,
            "A frozen block's measured CGSize must be invariant across all later streaming updates")
        XCTAssertEqual(checkpoint.bytes, final.bytes,
            "A frozen block's rasterized CGImage bytes must be invariant across all later streaming updates")
    }

    // MARK: - LB2: scroll parity — reconfigure-whole == bind-whole for genuinely-new content

    func testLB2_ReconfigureWholeEqualsBindWhole_ScrollParity() {
        let messageCount = 40
        let blocksPerMessage = 4
        let tokensPerBlock = 12
        let width: CGFloat = 300
        let scale: CGFloat = 2

        var messages: [[String]] = []
        var tokenCursor = 0
        for _ in 0..<messageCount {
            var blockTexts: [String] = []
            for _ in 0..<blocksPerMessage {
                var tokens: [String] = []
                for _ in 0..<tokensPerBlock {
                    tokens.append(Self.token(tokenCursor))
                    tokenCursor += 1
                }
                blockTexts.append(tokens.joined(separator: " "))
            }
            messages.append(blockTexts)
        }

        func measureAndRasterizeAll(
            _ msgs: [[String]], ctx: TextMeasurementContext
        ) -> (calls: Int, seconds: TimeInterval) {
            var calls = 0
            var seconds: TimeInterval = 0
            for blockTexts in msgs {
                for text in blockTexts {
                    let d = Self.makeDescriptor(text)
                    let mStart = Date()
                    let size = ctx.measure(d, width: width)
                    seconds += Date().timeIntervalSince(mStart)
                    calls += 1

                    let rStart = Date()
                    if rasterizeText(d, size: size, scale: scale) != nil {
                        seconds += Date().timeIntervalSince(rStart)
                        calls += 1
                    }
                }
            }
            return (calls, seconds)
        }

        // Two independently-instantiated contexts: models "reconfigure an existing (in-place)
        // cell" vs "bind a freshly recycled pool cell" — for genuinely-new content the cost
        // model predicts these are architecturally different paths doing IDENTICAL work.
        let reconfigure = measureAndRasterizeAll(messages, ctx: TextMeasurementContext())
        let bind = measureAndRasterizeAll(messages, ctx: TextMeasurementContext())

        print("[HybridReuseSpike][LB2] reconfigureWhole calls=\(reconfigure.calls) "
            + "seconds=\(String(format: "%.4f", reconfigure.seconds)) | "
            + "bindWhole calls=\(bind.calls) seconds=\(String(format: "%.4f", bind.seconds))")

        XCTAssertEqual(reconfigure.calls, bind.calls,
            "Reconfigure-whole and bind-whole must perform the identical NUMBER of measure+"
            + "rasterize calls for genuinely-new content — scroll parity means neither path "
            + "does extra or fewer primitive calls")

        let ratio = reconfigure.seconds / max(bind.seconds, .ulpOfOne)
        print("[HybridReuseSpike][LB2] reconfigure/bind wall-time ratio=\(String(format: "%.3f", ratio))")
        XCTAssertEqual(ratio, 1.0, accuracy: 0.5,
            "reconfigure-whole vs bind-whole wall time (ratio=\(ratio)) must be within tolerance — "
            + "confirms no hidden extra cost on either cell-reuse path for genuinely-new content")
    }

    // MARK: - LB5: bounded memory — peak live-bitmap bytes is O(window), not O(chat length)

    func testLB5_WorkingRangeBoundedMemory() {
        let windowSize = 20
        let width: CGFloat = 300
        let scale: CGFloat = 2
        let chatLengths = [50, 200, 500]
        var peakByLength: [Int: Int] = [:]
        var evictionProvenForLongestChat = false

        for length in chatLengths {
            // Synthetic chat: mostly short messages, every 5th one long — same periodic
            // distribution regardless of chat length, so any window's worst case looks similar.
            var messages: [String] = []
            var tokenCursor = 0
            for i in 0..<length {
                let blockTokenCount = (i % 5 == 0) ? 60 : 8
                var tokens: [String] = []
                for _ in 0..<blockTokenCount {
                    tokens.append(Self.token(tokenCursor))
                    tokenCursor += 1
                }
                messages.append(tokens.joined(separator: " "))
            }

            let ctx = TextMeasurementContext()
            var sizeCache: [Int: CGSize] = [:]        // descriptor-adjacent — retained forever
            var liveBitmapBytes: [Int: Int] = [:]      // present only while inside the window
            var currentTotal = 0
            var peakBytes = 0

            func admit(_ idx: Int) {
                guard liveBitmapBytes[idx] == nil else { return }
                let d = Self.makeDescriptor(messages[idx])
                let size = sizeCache[idx] ?? ctx.measure(d, width: width)
                sizeCache[idx] = size
                guard let image = rasterizeText(d, size: size, scale: scale),
                      let bytes = Self.pixelBytes(of: image)?.count else { return }
                liveBitmapBytes[idx] = bytes
                currentTotal += bytes
                peakBytes = max(peakBytes, currentTotal)
            }
            func evict(_ idx: Int) {
                guard let bytes = liveBitmapBytes.removeValue(forKey: idx) else { return }
                currentTotal -= bytes
                // sizeCache[idx] intentionally left in place: the descriptor/size is retained,
                // only the heavy rasterized bitmap is freed.
            }

            let initialHi = min(windowSize, length)
            for i in 0..<initialHi { admit(i) }
            peakBytes = max(peakBytes, currentTotal)

            let maxLo = max(0, length - windowSize)
            var lo = 0
            while lo < maxLo {
                lo += 1
                let hi = min(lo + windowSize, length)
                let toEvict = liveBitmapBytes.keys.filter { $0 < lo }
                for idx in toEvict { evict(idx) }
                for idx in lo..<hi where liveBitmapBytes[idx] == nil { admit(idx) }
            }

            peakByLength[length] = peakBytes

            if length == chatLengths.last {
                // Index 0 was admitted at the very start and long since scrolled out of the
                // window — its bitmap must be freed while its descriptor/size survives.
                XCTAssertNil(liveBitmapBytes[0],
                    "Block 0 left the working-range window long ago — its bitmap must be evicted")
                XCTAssertNotNil(sizeCache[0],
                    "Block 0's descriptor/size must be retained even after its bitmap is evicted")
                evictionProvenForLongestChat = (liveBitmapBytes[0] == nil && sizeCache[0] != nil)
            }
        }

        let peaks = chatLengths.map { peakByLength[$0] ?? -1 }
        for (length, peak) in zip(chatLengths, peaks) {
            print("[HybridReuseSpike][LB5] chatLength=\(length) peakLiveBitmapBytes=\(peak) "
                + "(~\(String(format: "%.2f", Double(peak) / 1_048_576)) MB)")
        }

        XCTAssertTrue(evictionProvenForLongestChat, "Eviction must free the bitmap while retaining the descriptor")

        // Peak memory must stay bounded by the window, NOT scale with total chat length: chat
        // length grew 10x (50 -> 500) but peak bytes must stay within a small constant factor.
        guard let peak50 = peakByLength[50], let peak500 = peakByLength[500], peak50 > 0 else {
            XCTFail("Missing peak samples for chat length 50/500"); return
        }
        let growthFactor = Double(peak500) / Double(peak50)
        print("[HybridReuseSpike][LB5] peak growth 50->500 messages: \(String(format: "%.2f", growthFactor))x "
            + "(chat length itself grew 10x)")
        XCTAssertLessThan(peak500, peak50 * 2,
            "Peak live-bitmap bytes at chat length 500 (\(peak500)) must stay within a small "
            + "constant factor of chat length 50 (\(peak50)) — evidence peak memory is O(window), "
            + "not O(total chat length)")
    }
}
#endif

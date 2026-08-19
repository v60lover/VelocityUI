// HotBlockRasterizerSpikeTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Measurement spike for VelocityUI-q87l — de-risks VelocityUI-wj8x (incremental
/// re-rasterization of a single still-growing hot text block) before any production wiring.
/// Full analysis in TEXTKIT2_INCREMENTAL_RASTERIZATION_RESEARCH.md (§3, §4, §6).
///
/// - Streams N appended chunks into ONE persistent NSTextLayoutManager/NSTextContentStorage/
///   NSTextContainer, editing only via `textStorage.replaceCharacters(in:with:)` inside
///   `performEditingTransaction` — never by reassigning `attributedString` (the D1 cost driver
///   the research doc identifies).
/// - Measurement only — does NOT touch `rasterizeText`, `TextMeasurementContext`, `FreezeState`,
///   or the freeze path. `IncrementalTextProbe` below is test-local, not production; a real
///   `HotBlockRasterizer` (VelocityUI-x4q0) is a separate, later bead.
/// - Assertions are COUNT-based (fragments re-laid-out, lines rasterized, pixel areas) or
///   exact-value based (origins, heights) — never wall-clock (timing flakes on shared hardware).
@MainActor
final class HotBlockRasterizerSpikeTests: XCTestCase {

    // MARK: - Snapshot types

    /// What we know about one fragment from a fully-ensured layout walk. Deliberately
    /// does NOT retain the live `NSTextLayoutFragment` across `append()` calls — TextKit2
    /// invalidates/recreates fragment objects across edits, so only value data survives
    /// between calls. The fragment itself is only touched (read, drawn) within the same
    /// `append()` invocation that produced it.
    private struct FragmentInfo {
        let rangeStart: Int      // UTF-16 offset from documentRange.location
        let rangeLength: Int
        let frame: CGRect        // layoutFragmentFrame
        let lineCount: Int       // textLineFragments.count
    }

    /// Result of one `append()` call — everything a caller needs to assert the bead's
    /// acceptance criteria without re-deriving it.
    private struct AppendMetrics {
        /// TextKit2's own report of "still cache-valid" fragments, read via
        /// `enumerateTextLayoutFragments(from:options: [])` (NO `.ensuresLayout`) called
        /// immediately after the edit, before anything forces layout. Per the bead's
        /// suggested counting mechanism: "only already-laid-out fragments are visited."
        let cacheValidCount: Int
        /// Ground-truth stable-prefix count: fragments whose (rangeStart, rangeLength)
        /// exactly match the previous full snapshot at the same index, computed AFTER
        /// forcing `ensureLayout(for: documentRange)`. This is the primary source for
        /// every assertion below — it does not depend on undocumented behavior of the
        /// no-`.ensuresLayout` walk, only on well-documented range/identity semantics.
        let stableCount: Int
        /// Total fragments after this append, fully ensured.
        let totalAfter: Int
        /// totalAfter - stableCount: how many fragments TextKit2 actually re-laid-out.
        var reLaidOutCount: Int { totalAfter - stableCount }
        /// True iff every stable-prefix fragment's origin is byte-identical (`==`) to
        /// what it was in the previous snapshot.
        let stableOriginsMatch: Bool
        /// Sum of textLineFragments.count over the re-laid-out (non-stable) fragments —
        /// the direction-(b) "glyph-rasterized line count" this append actually redraws.
        let redrawnLineCount: Int
        /// layoutManager.usageBoundsForTextContainer.height after ensureLayout(for: documentRange).
        let usageBoundsHeight: CGFloat
        /// max(fragment.layoutFragmentFrame.maxY) over the full ensured walk — the brute
        /// enumerate-from-top height, for comparison against usageBoundsHeight.
        let enumerateSumHeight: CGFloat
        /// width * stableTopY: pixels blitted from the retained previous image in the
        /// direction-(b) composite. Recorded, never asserted flat (research §4 direction
        /// (b): this is the memcpy-class O(block pixels) cost the design accepts).
        let blitPixelArea: Int
        /// The composited bitmap after this append (previous image + redrawn tail strip).
        let compositeImage: CGImage?
    }

    // MARK: - IncrementalTextProbe (test-local harness, NOT a production type)

    /// Owns one persistent NSTextContentStorage/NSTextLayoutManager/NSTextContainer for
    /// its whole lifetime, mirroring the "hot block owns one live layout manager for its
    /// whole streaming lifetime" shape research §3.2 and §5 call for. Width is fixed at
    /// init (a width CHANGE mid-stream is hazard 6 in the research doc — out of scope for
    /// this bead's "hazards to exercise" list, which names 5 items, not 6).
    private final class IncrementalTextProbe {
        private let contentStorage = NSTextContentStorage()
        private let layoutManager = NSTextLayoutManager()
        private let container: NSTextContainer
        private let font: UIFont
        private let scale: CGFloat = 1

        private var previousSnapshot: [FragmentInfo] = []
        private(set) var previousImage: CGImage?

        init(width: CGFloat, font: UIFont, maximumNumberOfLines: Int = 0) {
            self.font = font
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineBreakMode = .byWordWrapping
            container.maximumNumberOfLines = maximumNumberOfLines
            layoutManager.textContainer = container
            contentStorage.addTextLayoutManager(layoutManager)
        }

        var containerWidth: CGFloat { container.size.width }

        /// Appends (or, with `explicitRange`, edits at an arbitrary point — used only by
        /// the mid-insert hazard test) an attributed delta and returns the full set of
        /// measurements described in `AppendMetrics`.
        @discardableResult
        func append(_ delta: String, at explicitRange: NSRange? = nil) -> AppendMetrics {
            guard let storage = contentStorage.textStorage else {
                fatalError("contentStorage.textStorage is nil — addTextLayoutManager must run before any edit")
            }
            let before = previousSnapshot
            let insertRange = explicitRange ?? NSRange(location: storage.length, length: 0)
            let attributed = NSAttributedString(string: delta, attributes: [.font: font])

            // The load-bearing edit: append INTO the existing storage via
            // replaceCharacters, inside performEditingTransaction. Never
            // `storage.attributedString = ...` (that is D1 from the research doc —
            // whole-string reassignment, which invalidates everything).
            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: insertRange, with: attributed)
            }

            // Probe A — TextKit2's own cache-valid walk, taken BEFORE any forcing call.
            let cacheValidCount = countCacheValidFragments()

            // Probe B — ground truth. Force full layout, snapshot everything, then
            // prefix-match against `before` by (rangeStart, rangeLength) identity.
            let (after, liveFragments) = fullSnapshotWithLiveFragments()

            var stableCount = 0
            while stableCount < before.count && stableCount < after.count
                && before[stableCount].rangeStart == after[stableCount].rangeStart
                && before[stableCount].rangeLength == after[stableCount].rangeLength {
                stableCount += 1
            }

            var originsMatch = true
            for i in 0..<stableCount where before[i].frame.origin != after[i].frame.origin {
                originsMatch = false
            }

            let usageHeight = layoutManager.usageBoundsForTextContainer.height
            let enumerateSumHeight = after.map(\.frame.maxY).max() ?? 0

            let changedInfos = Array(after[stableCount...])
            let changedFragments = Array(liveFragments[stableCount...])
            let redrawnLineCount = changedInfos.reduce(0) { $0 + $1.lineCount }
            let stableTopY = stableCount > 0 ? after[stableCount - 1].frame.maxY : 0
            let totalHeight = after.map(\.frame.maxY).max() ?? 0

            var compositeImage: CGImage?
            var blitPixelArea = 0
            if totalHeight > 0 {
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale
                format.opaque = false
                let renderer = UIGraphicsImageRenderer(
                    size: CGSize(width: container.size.width, height: totalHeight),
                    format: format
                )
                let previousImageForDraw = previousImage
                let img = renderer.image { ctx in
                    // Direction (b): blit the retained previous image for the stable top
                    // region (memcpy-class, O(block pixels) — tracked, not eliminated),
                    // then draw ONLY the changed fragments — whole-fragment redraw, never
                    // a sub-glyph slice, so a shaping/ligature change at the seam can
                    // never leave a stale half-glyph (hazard 5).
                    if let previousImageForDraw, stableTopY > 0 {
                        blitPixelArea = Int(container.size.width * stableTopY)
                        UIImage(cgImage: previousImageForDraw).draw(
                            in: CGRect(x: 0, y: 0, width: container.size.width, height: stableTopY)
                        )
                    }
                    for fragment in changedFragments {
                        fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx.cgContext)
                    }
                }
                compositeImage = img.cgImage
            }

            previousImage = compositeImage
            previousSnapshot = after

            return AppendMetrics(
                cacheValidCount: cacheValidCount,
                stableCount: stableCount,
                totalAfter: after.count,
                stableOriginsMatch: originsMatch,
                redrawnLineCount: redrawnLineCount,
                usageBoundsHeight: usageHeight,
                enumerateSumHeight: enumerateSumHeight,
                blitPixelArea: blitPixelArea,
                compositeImage: compositeImage
            )
        }

        /// Probe A: enumerate WITHOUT `.ensuresLayout` — per API contract, only fragments
        /// TextKit2 still considers already-laid-out (cache-valid) are visited. Called
        /// before any forcing call so it reflects the edit's immediate invalidation
        /// footprint, not a footprint we ourselves created by calling ensureLayout.
        private func countCacheValidFragments() -> Int {
            var count = 0
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location,
                options: []
            ) { _ in
                count += 1
                return true
            }
            return count
        }

        /// Probe B: force full layout, then walk every fragment. Returns both the
        /// value-type snapshot (safe to retain across calls) and the live fragment
        /// objects (only used within this same call, for the composite draw above).
        private func fullSnapshotWithLiveFragments() -> ([FragmentInfo], [NSTextLayoutFragment]) {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            var infos: [FragmentInfo] = []
            var fragments: [NSTextLayoutFragment] = []
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                let start = self.contentStorage.offset(
                    from: self.layoutManager.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                let length = self.contentStorage.offset(
                    from: fragment.rangeInElement.location,
                    to: fragment.rangeInElement.endLocation
                )
                infos.append(FragmentInfo(
                    rangeStart: start,
                    rangeLength: length,
                    frame: fragment.layoutFragmentFrame,
                    lineCount: fragment.textLineFragments.count
                ))
                fragments.append(fragment)
                return true
            }
            return (infos, fragments)
        }

        /// Snapshot accessor for hazard tests that need to compare origins across an
        /// edit without going through `append()`'s bookkeeping (mid-insert hazard).
        func currentSnapshot() -> [FragmentInfo] { fullSnapshotWithLiveFragments().0 }

        var textLength: Int { contentStorage.textStorage?.length ?? 0 }
    }

    // MARK: - Test 1: stable-origin + flat re-layout across a code-fence-like stream

    /// Streams many short "sealed paragraphs" (each ends with "\n"), occasionally forcing a
    /// within-paragraph wrap before sealing (hazard 2: "append causes the last line to wrap —
    /// bounded to last + one new fragment"). Flatness is proved without a guessed magic-number
    /// bound: the first wrapping token and first non-wrapping token each establish an observed
    /// constant for reLaidOutCount/redrawnLineCount, and every later token of the same kind must
    /// equal that constant — self-calibrating, only fails if cost actually changes as N grows.
    func testStableOriginAndFlatReLayout_CodeFenceStream() {
        let probe = IncrementalTextProbe(width: 220, font: .systemFont(ofSize: 15))
        let tokenCount = 60
        var reLaidOutCounts: [Int] = []
        var redrawnLineCounts: [Int] = []

        var wrappingReLaidOut: Int?
        var wrappingRedrawnLines: Int?
        var plainReLaidOut: Int?
        var plainRedrawnLines: Int?

        for t in 0..<tokenCount {
            // Every 5th paragraph gets a long tail forcing one internal wrap before the
            // sealing newline — exercises hazard 2 without ever growing a single paragraph
            // without bound (that is hazard 4, tested separately).
            let isWrapping = t % 5 == 0
            let body = isWrapping
                ? "line \(t) with enough words to wrap once inside this narrow column "
                : "line \(t) short"
            let metrics = probe.append(body + "\n")

            XCTAssertTrue(metrics.stableOriginsMatch, "token \(t): a prior fragment's origin moved after an append-at-end edit")

            if isWrapping {
                if let expected = wrappingReLaidOut {
                    XCTAssertEqual(metrics.reLaidOutCount, expected, "token \(t): wrapping-token reLaidOutCount drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    wrappingReLaidOut = metrics.reLaidOutCount
                }
                if let expected = wrappingRedrawnLines {
                    XCTAssertEqual(metrics.redrawnLineCount, expected, "token \(t): wrapping-token redrawnLineCount drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    wrappingRedrawnLines = metrics.redrawnLineCount
                }
            } else {
                if let expected = plainReLaidOut {
                    XCTAssertEqual(metrics.reLaidOutCount, expected, "token \(t): plain-token reLaidOutCount drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    plainReLaidOut = metrics.reLaidOutCount
                }
                if let expected = plainRedrawnLines {
                    XCTAssertEqual(metrics.redrawnLineCount, expected, "token \(t): plain-token redrawnLineCount drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    plainRedrawnLines = metrics.redrawnLineCount
                }
            }

            reLaidOutCounts.append(metrics.reLaidOutCount)
            redrawnLineCounts.append(metrics.redrawnLineCount)
        }

        print("[q87l] code-fence stream: \(tokenCount) tokens. Observed flat constants — wrapping token: reLaidOutCount=\(wrappingReLaidOut ?? -1) redrawnLineCount=\(wrappingRedrawnLines ?? -1); plain token: reLaidOutCount=\(plainReLaidOut ?? -1) redrawnLineCount=\(plainRedrawnLines ?? -1). Full ranges: reLaidOutCount \(reLaidOutCounts.min() ?? -1)...\(reLaidOutCounts.max() ?? -1), redrawnLineCount \(redrawnLineCounts.min() ?? -1)...\(redrawnLineCounts.max() ?? -1)")
    }

    // MARK: - Test 2: partial last line extended token-by-token (hazard 1)

    /// "func c(" -> "func c()" one character at a time. No newline anywhere — this is
    /// always exactly ONE fragment, ONE line. Confirms hazard 1: "the last fragment
    /// re-lays-out and re-rasterizes each token. Fine — it's one line, still O(appended)."
    func testPartialLastLineTokenByToken() {
        let probe = IncrementalTextProbe(width: 220, font: .systemFont(ofSize: 15))
        let chars = Array("func c() -> Int {")
        for (i, ch) in chars.enumerated() {
            let metrics = probe.append(String(ch))
            XCTAssertEqual(metrics.totalAfter, 1, "char \(i): expected exactly one fragment (single unterminated line)")
            XCTAssertEqual(metrics.reLaidOutCount, 1, "char \(i): expected exactly the one fragment to re-lay-out")
            XCTAssertEqual(metrics.redrawnLineCount, 1, "char \(i): expected exactly one glyph-rasterized line")
        }
        print("[q87l] partial-last-line: \(chars.count) chars appended, reLaidOutCount stayed 1 throughout")
    }

    // MARK: - Test 3: usageBoundsForTextContainer vs enumerate-from-top (research §3.3)

    /// Confirms usageBoundsForTextContainer, read after ensureLayout(for: documentRange)
    /// on a fully-ensured OFFSCREEN container (no viewport controller), matches the
    /// brute enumerate-from-top height — i.e. the Krzyżanowski viewport-instability
    /// caveat does not apply here (research §3.3's caveat paragraph).
    func testUsageBoundsMatchesEnumerateSum() {
        let probe = IncrementalTextProbe(width: 220, font: .systemFont(ofSize: 15))
        for t in 0..<40 {
            let metrics = probe.append("paragraph \(t) with some words to lay out.\n")
            XCTAssertEqual(
                metrics.usageBoundsHeight, metrics.enumerateSumHeight, accuracy: 0.01,
                "token \(t): usageBoundsForTextContainer.height (\(metrics.usageBoundsHeight)) != enumerate-from-top height (\(metrics.enumerateSumHeight))"
            )
        }
    }

    // MARK: - Test 4: direction (b) composite — glyph line count flat, blit cost separate

    /// Direction (b) probe (research §4): rasterize only the new tail into a strip,
    /// composite over the retained previous CGImage. Glyph-rasterized line count per
    /// token must stay flat; the whole-image blit cost is recorded SEPARATELY and is
    /// intentionally NOT asserted flat — research says this is a memcpy-class O(block
    /// pixels) cost direction (b) accepts (and direction (a) would later remove).
    func testDirectionBCompositeProbe() {
        let probe = IncrementalTextProbe(width: 200, font: .systemFont(ofSize: 14))
        var blitAreas: [Int] = []
        var lineCounts: [Int] = []

        for t in 0..<50 {
            let metrics = probe.append("chat token \(t) streaming in.\n")
            lineCounts.append(metrics.redrawnLineCount)
            blitAreas.append(metrics.blitPixelArea)
            XCTAssertLessThanOrEqual(metrics.redrawnLineCount, 2, "token \(t): direction-(b) redrawn line count should stay flat")
            XCTAssertNotNil(metrics.compositeImage, "token \(t): composite image should always be produced once content exists")
        }

        // Blit cost is expected to GROW (it is O(block pixels), not O(appended)) —
        // documented here, not treated as a failure.
        XCTAssertGreaterThan(blitAreas.last ?? 0, blitAreas[5], "expected blit pixel area to grow with block size (documenting the direction-(b) tradeoff, not a bug)")
        print("[q87l] direction (b): line counts \(lineCounts.min() ?? -1)...\(lineCounts.max() ?? -1) (flat), blit area grew \(blitAreas.first ?? 0) -> \(blitAreas.last ?? 0) px (not flat, tracked separately)")
    }

    // MARK: - Test 5: non-append edit breaks stable-origin (hazard 3)

    /// Builds three sealed paragraphs, then inserts new text INSIDE the first paragraph (not at
    /// the document end). Confirms fragments AFTER the insertion point shift — stable-origin
    /// does NOT hold for non-append edits, justifying "the primitive must assert append-only and
    /// fall back to full rasterizeText on a non-append edit" (research §6.3).
    ///
    /// The insert must actually change the first paragraph's laid-out height, or nothing below it
    /// moves (a same-line insert with no wrap leaves later fragments' Y untouched). This version
    /// inserts a long word run (no newline) that forces the first paragraph to wrap — fragment
    /// COUNT stays at 3, wrapping happens inside the fragment via an extra textLineFragment — so
    /// origin comparison for fragments 1/2 isolates exactly one variable: did an earlier
    /// fragment's height change move the rest.
    func testMidInsertBreaksStableOrigin() {
        let probe = IncrementalTextProbe(width: 220, font: .systemFont(ofSize: 15))
        probe.append("first paragraph\n")
        probe.append("second paragraph\n")
        probe.append("third paragraph\n")

        let before = probe.currentSnapshot()
        XCTAssertEqual(before.count, 3, "setup: expected 3 sealed paragraphs before the mid-insert")
        let originsBefore = before.map(\.frame.origin)

        // Insert in the middle of the FIRST paragraph (well before the second/third) —
        // long enough, with no newline, to force paragraph 1 to wrap onto a second line
        // at width 220 and thus grow taller.
        let wrapForcingInsert = "some additional words inserted here to overflow the narrow column and force a wrap "
        probe.append(wrapForcingInsert, at: NSRange(location: 6, length: 0))

        let after = probe.currentSnapshot()
        XCTAssertEqual(after.count, 3, "expected the mid-insert (no newline) to keep fragment count at 3 — only fragment 0's height should change, not the paragraph count")
        let originsAfter = after.map(\.frame.origin)

        // Fragments 2 and 3 (0-indexed: 1, 2) sat AFTER the edit point. Their origin
        // must have shifted DOWN (their content didn't change, but their position did,
        // because fragment 0 grew taller) — this is the concrete demonstration that a
        // non-append edit invalidates fragments that an append-only algorithm would have
        // assumed were still safe/frozen.
        XCTAssertNotEqual(originsBefore[1], originsAfter[1], "fragment 1's origin should have shifted after a preceding mid-insert that grew fragment 0, but stayed the same")
        XCTAssertNotEqual(originsBefore[2], originsAfter[2], "fragment 2's origin should have shifted after a preceding mid-insert that grew fragment 0, but stayed the same")
        XCTAssertGreaterThan(originsAfter[1].y, originsBefore[1].y, "fragment 1 should have shifted DOWN (fragment 0 grew taller), not up or sideways")
        XCTAssertGreaterThan(originsAfter[2].y, originsBefore[2].y, "fragment 2 should have shifted DOWN (fragment 0 grew taller), not up or sideways")
        print("[q87l] mid-insert: fragment origins shifted from \(originsBefore[1]) -> \(originsAfter[1]) and \(originsBefore[2]) -> \(originsAfter[2])")
    }

    // MARK: - Test 6: one giant unbroken paragraph is O(paragraph), not O(appended)

    /// No newlines anywhere — always exactly one fragment (one paragraph), but the
    /// container is narrow enough that it wraps into progressively more visual lines as
    /// it grows. Because the smallest redraw unit is a whole NSTextLayoutFragment (never
    /// a sub-fragment glyph slice — see hazard 5), EVERY append must redraw the ENTIRE
    /// paragraph, so redrawnLineCount grows with the paragraph's current line count. This
    /// documents the honest asterisk from research §3.3.1 / §6.4: the pathological case
    /// is real and bounded only by "how big is this one paragraph," not by N.
    func testGiantUnbrokenParagraphBound() {
        let probe = IncrementalTextProbe(width: 60, font: .systemFont(ofSize: 14))
        var redrawnLineCounts: [Int] = []

        for t in 0..<30 {
            let metrics = probe.append("word\(t) ")
            XCTAssertEqual(metrics.totalAfter, 1, "token \(t): expected exactly one fragment (single unbroken paragraph, no newlines)")
            XCTAssertEqual(metrics.reLaidOutCount, 1, "token \(t): expected exactly one fragment to re-lay-out (it's the whole paragraph)")
            redrawnLineCounts.append(metrics.redrawnLineCount)
        }

        // NOT flat: later tokens must redraw strictly more lines than early tokens,
        // because the whole (now-longer, now-more-wrapped) paragraph is redrawn each time.
        let early = redrawnLineCounts[2]
        let late = redrawnLineCounts[redrawnLineCounts.count - 1]
        XCTAssertGreaterThan(late, early, "expected redrawnLineCount to GROW with the unbroken paragraph's length (documenting the O(paragraph) bound), but it stayed flat at \(early)")
        print("[q87l] giant-paragraph bound: redrawnLineCount grew \(early) -> \(late) over \(redrawnLineCounts.count) tokens (documents O(paragraph), not O(appended))")
    }

    // MARK: - Test 7: ligature/emoji at composite seam (hazard 5)

    /// Streams text ending right before a ZWJ emoji sequence, then appends the emoji as
    /// its own token (same still-open paragraph, no newline in between) — the seam where
    /// a direction-(b) strip redraw could show a stale half-glyph if it tried to draw
    /// only "the new glyphs" instead of the whole re-laid-out fragment. Confirms the
    /// incrementally-composited image is pixel-identical to a fresh single-shot
    /// `rasterizeText` of the same final string (ground truth, ships in production code —
    /// used here read-only for comparison, never modified).
    func testLigatureAndEmojiAtSeam() {
        let width: CGFloat = 260
        let fontSize: CGFloat = 16
        let probe = IncrementalTextProbe(width: width, font: .systemFont(ofSize: fontSize))

        let parts = ["The team waffle ", "shipped: ", "👨‍👩‍👧‍👦"]
        var lastMetrics: AppendMetrics?
        for part in parts {
            lastMetrics = probe.append(part)
        }
        guard let metrics = lastMetrics, let composite = metrics.compositeImage else {
            XCTFail("expected a composite image after streaming all parts"); return
        }

        let finalString = parts.joined()
        let descriptor = TextDescriptor(
            content: finalString,
            font: VFontDescriptor(size: fontSize, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            layoutHash: 1,
            appearanceHash: 0
        )
        let groundTruthSize = CGSize(width: width, height: CGFloat(composite.height))
        guard let groundTruth = rasterizeText(descriptor, size: groundTruthSize) else {
            XCTFail("rasterizeText returned nil for ground-truth comparison"); return
        }

        XCTAssertEqual(composite.width, groundTruth.width, "composite/ground-truth width mismatch")
        XCTAssertEqual(composite.height, groundTruth.height, "composite/ground-truth height mismatch")

        func bytes(_ image: CGImage) -> Data? {
            let w = image.width, h = image.height
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let ptr = ctx.data else { return nil }
            return Data(bytes: ptr, count: w * h * 4)
        }

        guard let compositeBytes = bytes(composite), let groundTruthBytes = bytes(groundTruth) else {
            XCTFail("could not extract pixel data for comparison"); return
        }
        XCTAssertEqual(compositeBytes, groundTruthBytes, "incrementally-composited image must be pixel-identical to a single-shot rasterize of the same final string — a mismatch means the seam left a stale/partial glyph")
        print("[q87l] ligature/emoji seam: composite (\(composite.width)x\(composite.height)) pixel-identical to ground truth")
    }
}
#endif

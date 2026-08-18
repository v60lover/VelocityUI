// HotBlockMeasurerTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Acceptance tests for VelocityUI-c1uc's `HotBlockMeasurer` — the production
/// incremental-measure type for a single still-growing hot text block. Exercises the
/// same shape the VelocityUI-q87l spike (HotBlockRasterizerSpikeTests.swift) validated,
/// but against the real production type instead of the spike's test-local probe.
///
/// Every assertion here is count-based or exact-value based, never wall-clock, matching
/// the bead's hard requirement (timing assertions flake on shared/loaded hardware).
///
/// | Invariant (bead acceptance criteria)                                    | Assertion |
/// |---------------------------------------------------------------------------|-----------|
/// | Per-token measure of a growing block re-lays-out only the hot paragraph   | `testFlatReLaidOutCount_CodeFenceStream`: self-calibrating equal-to-first-observed reLaidOutCount |
/// | Incremental height matches a from-scratch full measure within 1pt         | `testHeightParityWithinOnePoint`: `abs(height - TextMeasurementContext().measure(...).height) <= 1.0` (plus a self-consistency check vs `_debugEnumerateSumHeight()`) |
/// | Incremental path taken (persistent objects, not a fresh-per-call rebuild)  | `testFlatReLaidOutCount_CodeFenceStream`: `XCTAssertTrue(result.appended)` proves the delta branch ran; the flat range-stability count is a supporting smoke check, not proof of geometry reuse |
/// | Non-append edit falls back to a full measure                              | `testNonAppendEditFallsBackToFullMeasure`: `appended == false`, height matches ground truth |
/// | Container width change falls back to a full measure                      | `testWidthChangeFallsBackToFullMeasure`: `appended == false`, height matches ground truth |
/// | Dynamic Type change falls back to a full measure                          | `testDynamicTypeChangeFallsBackToFullMeasure`: `appended == false`, height matches ground truth |
@MainActor
final class HotBlockMeasurerTests: XCTestCase {

    private func makeDescriptor(
        content: String,
        fontSize: CGFloat = 15,
        lineLimit: Int? = nil,
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
        contentSizeCategory: VContentSizeCategory = .unspecified
    ) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: VFontDescriptor(size: fontSize, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: lineLimit,
            lineBreakMode: lineBreakMode.rawValue,
            contentSizeCategory: contentSizeCategory,
            // layoutHash/appearanceHash are irrelevant to HotBlockMeasurer — it compares
            // individual TextDescriptor fields (AttributeFingerprint), never these hashes
            // (layoutHash folds in `content`, which would make append detection impossible
            // — see HotBlockMeasurer.swift's doc). Placeholder values are fine.
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    // MARK: - Acceptance 1 + 3: flat re-laid-out fragment count, persistent-object reuse

    /// Streams 60 "sealed paragraph" tokens (occasionally forcing an internal wrap before
    /// sealing) into ONE `HotBlockMeasurer`, computing re-laid-out count the same way the
    /// q87l spike does: full fragment-range snapshot before/after each call, prefix-matched
    /// by (rangeStart, rangeLength) identity. Flatness is self-calibrating — the first
    /// wrapping token and the first plain token each establish an observed constant, and
    /// every LATER token of the same kind must equal it exactly (spike NOTES: a guessed
    /// ceiling produced a false failure before; equality-to-first-observed only fails on
    /// real drift).
    ///
    /// What proves acceptance criterion 3 (incremental path, no fresh-per-call rebuild) is
    /// the `XCTAssertTrue(result.appended)` below: `appended` is returned only when
    /// `measure` took the `replaceCharacters` delta branch, never the whole-string fallback.
    /// The flat reLaidOutCount is a SUPPORTING smoke check, not independent proof of geometry
    /// reuse — it compares fragment RANGES (start, length), and a from-scratch rebuild of the
    /// same text would produce identical ranges and the same stable prefix, so a flat count
    /// alone can't distinguish reuse from rebuild-to-identical-ranges. It still earns its
    /// place: a genuine per-token cost regression (each append re-wrapping more of the block
    /// than the tail) would show up as reLaidOutCount drifting off its first-observed
    /// constant.
    func testFlatReLaidOutCount_CodeFenceStream() {
        let measurer = HotBlockMeasurer()
        let width: CGFloat = 220
        var fullContent = ""
        var previousRanges: [(start: Int, length: Int)] = []

        var wrappingReLaidOut: Int?
        var plainReLaidOut: Int?

        for t in 0..<60 {
            let isWrapping = t % 5 == 0
            let body = isWrapping
                ? "line \(t) with enough words to wrap once inside this narrow column "
                : "line \(t) short"
            fullContent += body + "\n"
            let descriptor = makeDescriptor(content: fullContent, fontSize: 15)

            let result = measurer.measure(descriptor, width: width)
            if t > 0 {
                XCTAssertTrue(result.appended, "token \(t): expected an append-only token to take the incremental path")
            }

            let after = measurer._debugFragmentRanges()
            var stableCount = 0
            while stableCount < previousRanges.count && stableCount < after.count
                && previousRanges[stableCount].start == after[stableCount].start
                && previousRanges[stableCount].length == after[stableCount].length {
                stableCount += 1
            }
            let reLaidOutCount = after.count - stableCount

            if isWrapping {
                if let expected = wrappingReLaidOut {
                    XCTAssertEqual(reLaidOutCount, expected, "token \(t): wrapping-token reLaidOutCount drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    wrappingReLaidOut = reLaidOutCount
                }
            } else {
                if let expected = plainReLaidOut {
                    XCTAssertEqual(reLaidOutCount, expected, "token \(t): plain-token reLaidOutCount drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    plainReLaidOut = reLaidOutCount
                }
            }

            previousRanges = after
        }

        print("[c1uc] code-fence stream: 60 tokens. Observed flat constants — wrapping: \(wrappingReLaidOut ?? -1), plain: \(plainReLaidOut ?? -1)")
    }

    // MARK: - Acceptance 2: usageBounds vs enumerate-from-top height parity

    /// Confirms `usageBoundsForTextContainer` (what `measure(_:width:)` returns) matches
    /// the brute enumerate-from-top height within the Spike 4 measure==render parity
    /// bound (1pt), across 40 appends of a growing block.
    ///
    /// Both `result.height` and `_debugEnumerateSumHeight()` are derived from the SAME
    /// incremental layout on the SAME measurer, so their agreement only proves internal
    /// self-consistency — a stale-fragment bug (an append that fails to re-flow a paragraph
    /// that should have re-wrapped) would corrupt both identically and still pass. So each
    /// token ALSO checks the incremental height against an independent from-scratch
    /// `TextMeasurementContext` measure of the same final content — the unchanged pure path
    /// that lays every fragment out fresh. That is the assertion that actually pins the core
    /// bead guarantee: the O(appended) path yields the same height a full measure would.
    func testHeightParityWithinOnePoint() {
        let measurer = HotBlockMeasurer()
        let width: CGFloat = 220
        var fullContent = ""

        for t in 0..<40 {
            fullContent += "paragraph \(t) with some words to lay out.\n"
            let descriptor = makeDescriptor(content: fullContent)
            let result = measurer.measure(descriptor, width: width)
            let enumerateSumHeight = measurer._debugEnumerateSumHeight()
            XCTAssertEqual(
                result.height, enumerateSumHeight, accuracy: 1.0,
                "token \(t): usageBoundsForTextContainer height (\(result.height)) != enumerate-from-top height (\(enumerateSumHeight)) beyond the 1pt parity bound"
            )

            let groundTruth = TextMeasurementContext().measure(descriptor, width: width)
            XCTAssertEqual(
                result.height, groundTruth.height, accuracy: 1.0,
                "token \(t): incremental append-path height (\(result.height)) != from-scratch TextMeasurementContext height (\(groundTruth.height)) — the incremental layout diverged from a full measure of the same content"
            )
        }
    }

    // MARK: - Acceptance 4a: non-append edit falls back to a full measure

    /// Builds a growing block, then feeds a NON-append edit (new content does not start
    /// with what was last measured — a word inserted in the middle). Confirms the
    /// measurer detects this and falls back, and that the fallback's height matches a
    /// ground-truth single-shot measure of the same final content via the unchanged
    /// `TextMeasurementContext` pure path.
    func testNonAppendEditFallsBackToFullMeasure() {
        let measurer = HotBlockMeasurer()
        let width: CGFloat = 220

        measurer.measure(makeDescriptor(content: "first paragraph\n"), width: width)
        measurer.measure(makeDescriptor(content: "first paragraph\nsecond paragraph\n"), width: width)

        let editedContent = "first EDITED paragraph\nsecond paragraph\n"
        let descriptor = makeDescriptor(content: editedContent)
        XCTAssertFalse(measurer.isAppendOnly(descriptor, width: width), "a mid-string insert must not be classified as append-only")

        let result = measurer.measure(descriptor, width: width)
        XCTAssertFalse(result.appended, "a mid-string insert must trigger the full-measure fallback")

        let groundTruth = TextMeasurementContext().measure(descriptor, width: width)
        XCTAssertEqual(result.height, groundTruth.height, accuracy: 1.0, "fallback height must match a ground-truth full measure of the same final content")
    }

    // MARK: - Acceptance 4b: container width change falls back to a full measure

    func testWidthChangeFallsBackToFullMeasure() {
        let measurer = HotBlockMeasurer()
        let content = "first paragraph\nsecond paragraph with several more words in it\n"

        measurer.measure(makeDescriptor(content: "first paragraph\n"), width: 220)
        let descriptor = makeDescriptor(content: content)
        XCTAssertFalse(measurer.isAppendOnly(descriptor, width: 140), "a container width change must not be classified as append-only")

        let result = measurer.measure(descriptor, width: 140)
        XCTAssertFalse(result.appended, "a container width change must trigger the full-measure fallback")

        let groundTruth = TextMeasurementContext().measure(descriptor, width: 140)
        XCTAssertEqual(result.height, groundTruth.height, accuracy: 1.0, "fallback height must match a ground-truth full measure at the new width")
    }

    // MARK: - Acceptance 4c: Dynamic Type change falls back to a full measure

    /// `contentSizeCategory` is the field `TextDescriptor`/`resolvedFont` uses to apply
    /// `UIFontMetrics` scaling (TextRasteriser.swift) — a Dynamic Type category change.
    func testDynamicTypeChangeFallsBackToFullMeasure() {
        let measurer = HotBlockMeasurer()
        let width: CGFloat = 220
        let content = "first paragraph\nsecond paragraph with several more words in it\n"

        measurer.measure(makeDescriptor(content: "first paragraph\n", contentSizeCategory: .unspecified), width: width)
        let descriptor = makeDescriptor(content: content, contentSizeCategory: .accessibilityExtraLarge)
        XCTAssertFalse(measurer.isAppendOnly(descriptor, width: width), "a Dynamic Type category change must not be classified as append-only")

        let result = measurer.measure(descriptor, width: width)
        XCTAssertFalse(result.appended, "a Dynamic Type category change must trigger the full-measure fallback")

        let groundTruth = TextMeasurementContext().measure(descriptor, width: width)
        XCTAssertEqual(result.height, groundTruth.height, accuracy: 1.0, "fallback height must match a ground-truth full measure at the new content-size category")
    }
}
#endif

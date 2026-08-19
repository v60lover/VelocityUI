// HotBlockMeasurerTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Acceptance tests for VelocityUI-c1uc's `HotBlockMeasurer` (production incremental-measure
/// type for one still-growing hot text block), exercising the same shape the VelocityUI-q87l
/// spike validated but against the real type. All assertions are count/exact-value based, never
/// wall-clock (timing assertions flake on shared/loaded hardware).
///
/// | Acceptance criterion | Assertion |
/// |---|---|
/// | Re-lays-out only the hot paragraph per token | `testFlatReLaidOutCount_CodeFenceStream`: reLaidOutCount == first-observed constant |
/// | Height matches full measure within 1pt | `testHeightParityWithinOnePoint`: vs `TextMeasurementContext` + `_debugEnumerateSumHeight()` |
/// | Incremental path taken, not rebuilt | `testFlatReLaidOutCount_CodeFenceStream`: `result.appended == true` |
/// | Non-append edit falls back to full measure | `testNonAppendEditFallsBackToFullMeasure` |
/// | Width change falls back to full measure | `testWidthChangeFallsBackToFullMeasure` |
/// | Dynamic Type change falls back to full measure | `testDynamicTypeChangeFallsBackToFullMeasure` |
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

    /// Streams 60 "sealed paragraph" tokens (occasionally forcing an internal wrap before sealing)
    /// into ONE `HotBlockMeasurer`, computing re-laid-out count the same way the q87l spike does:
    /// fragment-range snapshot before/after each call, prefix-matched by (start, length). Flatness
    /// is self-calibrating — the first wrapping and first plain token each set an observed
    /// constant; every later token of the same kind must match it exactly (a guessed ceiling
    /// produced a false failure before; equality-to-first-observed only fails on real drift).
    ///
    /// Acceptance criterion 3 (incremental path, no rebuild) is proven by
    /// `XCTAssertTrue(result.appended)` below — `appended` is true only on the `replaceCharacters`
    /// delta branch, never the whole-string fallback. The flat reLaidOutCount is a SUPPORTING
    /// smoke check, not independent proof of reuse: it compares fragment ranges, and a
    /// from-scratch rebuild of the same text produces identical ranges, so a flat count alone
    /// can't distinguish reuse from rebuild-to-identical-ranges. It still catches a genuine
    /// per-token cost regression, which would show up as reLaidOutCount drifting off its
    /// first-observed constant.
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

    /// Confirms `usageBoundsForTextContainer` (`measure(_:width:)`'s return) matches the brute
    /// enumerate-from-top height within the Spike 4 measure==render parity bound (1pt), across
    /// 40 appends of a growing block.
    ///
    /// `result.height` and `_debugEnumerateSumHeight()` come from the SAME incremental layout on
    /// the SAME measurer, so agreement only proves internal self-consistency — a stale-fragment
    /// bug would corrupt both identically and still pass. Each token ALSO checks the incremental
    /// height against an independent from-scratch `TextMeasurementContext` measure of the same
    /// final content — that's the assertion pinning the real guarantee: the O(appended) path
    /// yields the same height a full measure would.
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

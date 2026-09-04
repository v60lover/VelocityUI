// HotBlockMeasurerMathTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
import SwaTex
import SwaTexRender
@testable import VelocityUI

/// Covers VelocityUI-gojy.7: the hot/streaming path (`HotBlockMeasurer`, `HotBlockRasterizer`)
/// ignored `descriptor.runs`, so inline math showed as literal TeX at the wrong height while a
/// block was still streaming, then jumped once it sealed and re-measured through the run-aware
/// sealed path. Fix threads `descriptor.attributedString(formulaCache:fontProvider:scale:)` into
/// the hot measurer's non-append branch, and forces `isAppendOnly` to `false` for any block
/// carrying an attachment-bearing or divergently-styled run.
///
/// | Bead acceptance # | Invariant being verified | Assertion |
/// |---|---|---|
/// | 1 | Hot measure of inline `$x^2$` produces an attachment, not literal glyphs | `testHotMeasure_InlineMath_ProducesAttachment_NotLiteralText` |
/// | 2 | Hot height of a tall inline formula matches sealed height within 1pt | `testHotMeasure_TallInlineFormula_HeightMatchesSealedWithinOnePoint` |
/// | 3 | Plain-text blocks still take the O(appended) fast path | `testPlainTextBlock_StillTakesAppendFastPath` |
/// | 4 | A run with `mathSource` forces `isAppendOnly` false | `testIsAppendOnly_MathSourceRun_ReturnsFalse` |
/// | 5 | A formula split across two stream chunks never flashes raw TeX, lands correct once closed | `testSplitAcrossChunks_MathRunClosesToAttachment_NoRawTeXFlash` |
/// | 6 | Malformed inline TeX degrades to literal text in the hot path, no crash | `testHotMeasure_MalformedInlineMath_DegradesToLiteralText` |
/// | 7 | A divergently-styled (inline-code) run measures at the correct height in the hot path | `testHotMeasure_DivergentStyleRun_HeightMatchesSealedWithinOnePoint`, `testIsAppendOnly_DivergentStyleRun_ReturnsFalse` |
@MainActor
final class HotBlockMeasurerMathTests: XCTestCase {
    private let font = VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight)
    private let width: CGFloat = 300

    /// Reads whether the measurer's live text storage contains an `InlineMathAttachment` —
    /// the hot-path equivalent of `InlineMathNodeTests`' attributed-string attachment checks.
    private func containsMathAttachment(_ measurer: HotBlockMeasurer) -> Bool {
        guard let storage = measurer.contentStorage.textStorage else { return false }
        var found = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value is InlineMathAttachment { found = true }
        }
        return found
    }

    // MARK: - Acceptance 1: hot measure produces an attachment, not literal text

    func testHotMeasure_InlineMath_ProducesAttachment_NotLiteralText() {
        let descriptor = TextDescriptor(
            content: "x",
            font: font,
            color: .primary,
            lineLimit: nil,
            lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [TextRun(length: 1, font: font, color: .primary, mathSource: "x^2")],
            layoutHash: 1,
            appearanceHash: 1
        )

        let measurer = HotBlockMeasurer()
        _ = measurer.measure(descriptor, width: width, formulaCache: nil, fontProvider: KaTeXFontProvider())

        XCTAssertTrue(
            containsMathAttachment(measurer),
            "hot measurer must build the run-aware attributed string, replacing the mathSource span with an InlineMathAttachment instead of the literal 'x' glyph"
        )
    }

    // MARK: - Acceptance 2: hot height parity with the sealed path for a tall formula

    func testHotMeasure_TallInlineFormula_HeightMatchesSealedWithinOnePoint() {
        let rawTeX = #"\frac{a}{\frac{b}{c}}"#
        let descriptor = TextDescriptor(
            content: "x",
            font: font,
            color: .primary,
            lineLimit: nil,
            lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [TextRun(length: 1, font: font, color: .primary, mathSource: rawTeX)],
            layoutHash: 1,
            appearanceHash: 1
        )

        let measurer = HotBlockMeasurer()
        let hot = measurer.measure(descriptor, width: width, formulaCache: nil, fontProvider: KaTeXFontProvider())
        let sealed = TextMeasurementContext().measure(descriptor, width: width, formulaCache: nil)

        XCTAssertEqual(
            hot.height, sealed.height, accuracy: 1.0,
            "hot-measured height of a tall inline formula must match the sealed TextMeasurementContext height within 1pt — a mismatch is exactly the jump users saw when a block froze"
        )
    }

    // MARK: - Acceptance 3: plain-text blocks are unaffected, still take the append fast path

    func testPlainTextBlock_StillTakesAppendFastPath() {
        let measurer = HotBlockMeasurer()

        func plainDescriptor(_ content: String) -> TextDescriptor {
            TextDescriptor(
                content: content, font: font, color: .primary,
                lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
                layoutHash: 0, appearanceHash: 0
            )
        }

        let first = measurer.measure(plainDescriptor("hello "), width: width)
        XCTAssertFalse(first.appended, "the very first call has no prior state, so it must take the full-measure path")

        let second = measurer.measure(plainDescriptor("hello world"), width: width)
        XCTAssertTrue(second.appended, "a plain-text, no-runs, prefix-matching descriptor must still take the O(appended) fast path")
    }

    // MARK: - Acceptance 4: a mathSource run forces isAppendOnly false

    func testIsAppendOnly_MathSourceRun_ReturnsFalse() {
        let measurer = HotBlockMeasurer()
        let plain = TextDescriptor(
            content: "answer: ", font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            layoutHash: 0, appearanceHash: 0
        )
        _ = measurer.measure(plain, width: width)

        // "answer: x^2" has "answer: " as a genuine string prefix, and the base font/color are
        // unchanged, so AttributeFingerprint alone (pre-fix behavior) would have classified this
        // as append-only -- the run-level mathSource check must override that.
        let withMath = TextDescriptor(
            content: "answer: x^2", font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [
                TextRun(length: 8, font: font, color: .primary),
                TextRun(length: 3, font: font, color: .primary, mathSource: "x^2")
            ],
            layoutHash: 0, appearanceHash: 0
        )

        XCTAssertFalse(
            measurer.isAppendOnly(withMath, width: width),
            "a descriptor whose runs contain a mathSource span must never be classified as append-only, even when its content is a genuine string-prefix continuation"
        )

        let result = measurer.measure(withMath, width: width, formulaCache: nil, fontProvider: KaTeXFontProvider())
        XCTAssertFalse(result.appended, "measure() must take the full (non-append) path for an attachment-bearing descriptor")
        XCTAssertTrue(containsMathAttachment(measurer), "the full-path measure must still build the attachment")
    }

    // MARK: - Acceptance 5: a formula split across two stream chunks closes correctly

    /// Simulates the real streaming shape: chunk 1 arrives before the closing `$`, so the parser
    /// hasn't recognized a formula yet (plain text, no runs) -- chunk 2 closes the delimiter,
    /// producing a run with `mathSource` set. The hot measurer must never show raw TeX once the
    /// formula closes, and must land on exactly one InlineMathAttachment.
    func testSplitAcrossChunks_MathRunClosesToAttachment_NoRawTeXFlash() {
        let measurer = HotBlockMeasurer()

        let chunk1 = TextDescriptor(
            content: "compute $x^", font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            layoutHash: 0, appearanceHash: 0
        )
        let openResult = measurer.measure(chunk1, width: width)
        XCTAssertFalse(
            containsMathAttachment(measurer),
            "an unclosed formula chunk must show as plain literal text -- no attachment yet, correctly matching the sealed path's own not-yet-a-formula state"
        )

        let chunk2 = TextDescriptor(
            content: "compute x^2", font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [
                TextRun(length: 8, font: font, color: .primary),
                TextRun(length: 3, font: font, color: .primary, mathSource: "x^2")
            ],
            layoutHash: 0, appearanceHash: 0
        )
        XCTAssertFalse(measurer.isAppendOnly(chunk2, width: width), "closing the formula must not be treated as a flat append")
        let closedResult = measurer.measure(chunk2, width: width, formulaCache: nil, fontProvider: KaTeXFontProvider())
        XCTAssertFalse(closedResult.appended)

        XCTAssertTrue(
            containsMathAttachment(measurer),
            "once the formula closes, the hot measurer must show the typeset formula image, never a flash of raw TeX text"
        )
        _ = openResult
    }

    // MARK: - Acceptance 6: malformed inline math degrades to literal text, no crash

    func testHotMeasure_MalformedInlineMath_DegradesToLiteralText() {
        let malformed = #"\frac{1}"#
        let descriptor = TextDescriptor(
            content: malformed, font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [TextRun(length: (malformed as NSString).length, font: font, color: .primary, mathSource: malformed)],
            layoutHash: 0, appearanceHash: 0
        )

        let measurer = HotBlockMeasurer()
        let result = measurer.measure(descriptor, width: width, formulaCache: nil, fontProvider: KaTeXFontProvider())

        XCTAssertGreaterThan(result.height, 0, "malformed TeX must still measure a positive height as literal text, never crash")
        XCTAssertFalse(containsMathAttachment(measurer), "malformed TeX must not produce an attachment")
        XCTAssertEqual(measurer.contentStorage.textStorage?.string, malformed, "malformed TeX's literal fallback text must be the raw TeX verbatim")
    }

    // MARK: - Acceptance 7 (bonus): a divergently-styled run (inline-code) measures correctly

    func testHotMeasure_DivergentStyleRun_HeightMatchesSealedWithinOnePoint() {
        let monoFont = VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight, family: "Menlo")
        let descriptor = TextDescriptor(
            content: "see foo() now", font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [
                TextRun(length: 4, font: font, color: .primary),
                TextRun(length: 5, font: monoFont, color: .primary),
                TextRun(length: 5, font: font, color: .primary)
            ],
            layoutHash: 0, appearanceHash: 0
        )

        let measurer = HotBlockMeasurer()
        let hot = measurer.measure(descriptor, width: width)
        let sealed = TextMeasurementContext().measure(descriptor, width: width)

        XCTAssertEqual(
            hot.height, sealed.height, accuracy: 1.0,
            "a hot block carrying a run whose font diverges from the base font (inline-code) must measure within 1pt of the sealed run-aware height"
        )
    }

    func testIsAppendOnly_DivergentStyleRun_ReturnsFalse() {
        let measurer = HotBlockMeasurer()
        let plain = TextDescriptor(
            content: "see ", font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            layoutHash: 0, appearanceHash: 0
        )
        _ = measurer.measure(plain, width: width)

        let monoFont = VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight, family: "Menlo")
        let withCode = TextDescriptor(
            content: "see code", font: font, color: .primary,
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [
                TextRun(length: 4, font: font, color: .primary),
                TextRun(length: 4, font: monoFont, color: .primary)
            ],
            layoutHash: 0, appearanceHash: 0
        )

        XCTAssertFalse(
            measurer.isAppendOnly(withCode, width: width),
            "a run whose font diverges from the base font must never be classified as append-only, even on a genuine string-prefix continuation"
        )
    }
}
#endif

// InlineMathNodeTests.swift

#if canImport(UIKit)
import XCTest
import SwaTex
import SwaTexRender
@testable import VelocityUI

/// Covers VelocityUI-gojy.4's acceptance criteria: inline `$...$` / `\(...\)` formulas render
/// mid-sentence on the correct baseline with surrounding text vertically centered around them;
/// line wrap works with formulas in the line; multiple inline formulas per paragraph work;
/// malformed inline math degrades to literal text.
///
/// | # | Invariant being verified | Assertion |
/// |---|---|---|
/// | 1 | Parser forwards `mathSource` onto `TextRun` without dropping it | `IncrementalMarkdownParser.textRun(for:baseFont:baseColor:)` preserves `run.mathSource` |
/// | 2 | Valid TeX produces `.formula` layout with positive, consistent metrics | `layoutInlineMath` returns `.formula`; metrics.width > 0, height > 0, baseline > 0, baseline ≤ height |
/// | 3 | Malformed TeX degrades to `.literal`, never crashes | `layoutInlineMath` returns `.literal` |
/// | 4 | Rasterized formula is BGRA8888 premultiplied, sized to metrics | image is non-nil, BGRA8888, dimensions match metrics * scale |
/// | 5 | `InlineMathAttachment.attachmentBounds` places image on baseline via descent formula | bounds.origin.y == -(metrics.height - metrics.baseline); bounds.size == (metrics.width, metrics.height); bounds.origin.x == 0 |
/// | 6a | A taller formula reserves more line height than a trivial one | differential: nested-fraction paragraph measures taller than a bare-variable paragraph |
/// | 6b | Measured height never falls short of the formula's own bounds | measured height ≥ formula metrics.height |
/// | 7 | Multiple inline formulas become independent attachments in `NSAttributedString` | each formula becomes a distinct attachment character at the right location |
/// | 8 | Malformed inline math degrades to literal text in attributed string | no attachment, no crash, content preserved as literal string |
/// | 9 | Math run's `linkURL` is preserved alongside attachment | `.link` attribute present at attachment location alongside `.attachment` |
final class InlineMathNodeTests: XCTestCase {
    private let font = VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight)

    // MARK: - 1. Parser preserves mathSource on TextRun

    func testTextRun_ParserForwardsMathSource() {
        let inlineRuns = inlineRuns("$x^2$")
        guard !inlineRuns.isEmpty else {
            return XCTFail("inlineRuns should parse inline math syntax")
        }
        let run = inlineRuns[0]
        XCTAssertEqual(run.mathSource, "x^2", "parser must extract raw TeX from inline math delimiters")

        let textRun = IncrementalMarkdownParser.textRun(
            for: run, baseFont: font, baseColor: .primary
        )
        XCTAssertEqual(textRun.mathSource, "x^2", "textRun must forward mathSource from InlineRun without dropping it")
    }

    // MARK: - 2/3. layoutInlineMath: formula vs. literal fallback

    func testLayoutInlineMath_ValidTeX_ProducesFormula() {
        let layout = layoutInlineMath(rawTeX: "x^2", font: font, color: .primary, cache: nil)
        guard case .formula(let list, let options, let metrics) = layout else {
            return XCTFail("valid TeX must produce a .formula layout, not literal fallback")
        }
        XCTAssertGreaterThan(metrics.width, 0, "formula width must be positive")
        XCTAssertGreaterThan(metrics.height, 0, "formula height must be positive")
        XCTAssertGreaterThan(metrics.baseline, 0, "formula baseline must be positive")
        XCTAssertLessThanOrEqual(metrics.baseline, metrics.height, "baseline must not exceed height")
    }

    func testLayoutInlineMath_MalformedTeX_DegradesToLiteral() {
        let malformed = #"\frac{1}"#
        let layout = layoutInlineMath(rawTeX: malformed, font: font, color: .primary, cache: nil)
        guard case .literal = layout else {
            return XCTFail("malformed TeX must degrade to .literal, never crash")
        }
    }

    // MARK: - 4. rasterizeInlineMath format + sizing

    func testRasterizeInlineMath_ValidFormula_IsBGRA8888AndSizedCorrectly() {
        let layout = layoutInlineMath(rawTeX: "x^2", font: font, color: .primary, cache: nil)
        guard case .formula(let list, let options, let metrics) = layout else {
            return XCTFail("expected a formula layout for this test")
        }

        let scale: CGFloat = 2
        guard let image = rasterizeInlineMath(
            list: list, options: options, metrics: metrics,
            fontProvider: KaTeXFontProvider(), scale: scale
        ) else {
            return XCTFail("rasterizeInlineMath must return a non-nil image for valid TeX")
        }

        XCTAssertTrue(isBGRA8888(image), "inline math raster must be BGRA8888 premultiplied")

        // `rasterizeInlineMath` sizes its canvas via `pixelLength` (round-half-away-from-zero,
        // ImageNormaliser.swift) -- pin that exact contract, not a plausible-looking `.rounded(.up)`
        // that happens to be within a loose accuracy window of it.
        let expectedPixelWidth = pixelLength(metrics.width, scale: scale)
        let expectedPixelHeight = pixelLength(metrics.height, scale: scale)
        XCTAssertEqual(image.width, expectedPixelWidth, "image width must match pixelLength(metrics.width, scale:)")
        XCTAssertEqual(image.height, expectedPixelHeight, "image height must match pixelLength(metrics.height, scale:)")
    }

    // MARK: - 5. InlineMathAttachment baseline positioning

    func testInlineMathAttachment_AttachmentBoundsPlacer_UsesDescentFormula() {
        let layout = layoutInlineMath(rawTeX: "x", font: font, color: .primary, cache: nil)
        guard case .formula(let list, let options, let metrics) = layout else {
            return XCTFail("expected a formula layout")
        }

        let attachment = InlineMathAttachment(
            list: list, options: options, metrics: metrics,
            fontProvider: KaTeXFontProvider(), scale: 1
        )

        let bounds = attachment.attachmentBounds(
            for: nil, proposedLineFragment: .zero, glyphPosition: .zero, characterIndex: 0
        )

        let expectedDescent = metrics.height - metrics.baseline
        XCTAssertEqual(
            bounds.origin.y, -expectedDescent, accuracy: 0.01,
            "bounds.origin.y must equal -(metrics.height - metrics.baseline)"
        )
        XCTAssertEqual(bounds.origin.x, 0, "bounds.origin.x must be 0")
        XCTAssertEqual(bounds.size.width, metrics.width, accuracy: 0.01, "bounds width must match metrics.width")
        XCTAssertEqual(bounds.size.height, metrics.height, accuracy: 0.01, "bounds height must match metrics.height")
    }

    // MARK: - 6. Baseline propagation through measurement

    /// TextKit's line height for a run carrying both a `.font` attribute (needed so a
    /// formula-only line still has font metrics to fall back on -- see `attributedString`'s
    /// comment on this) AND an attachment is `max(font's own line height, attachment bounds)`,
    /// not the attachment bounds alone -- a short formula (e.g. "x^2") can measure TALLER than
    /// its own `metrics.height` simply because the base font's natural leading exceeds it. So
    /// this test doesn't assert an absolute height; it proves attachment bounds actually drive
    /// layout differentially: two paragraphs, identical font/width, differing only in which
    /// formula is embedded -- a visibly taller formula (deeply nested fraction) must measure a
    /// taller paragraph than a trivial one, or the attachment's bounds aren't being consulted.
    func testMeasure_TallerInlineFormula_MeasuresTallerParagraph() {
        func measuredHeight(rawTeX: String) -> CGFloat {
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
            return TextMeasurementContext().measure(descriptor, width: 300, formulaCache: nil).height
        }

        let shortHeight = measuredHeight(rawTeX: "x")
        let tallHeight = measuredHeight(rawTeX: #"\frac{a}{\frac{b}{c}}"#)

        XCTAssertGreaterThan(
            tallHeight, shortHeight + 5,
            "a visibly taller formula (nested fraction) must reserve more line height than a trivial one -- proves attachmentBounds, not just the base font's line height, drives measurement"
        )
    }

    /// Independent of any font-leading ambiguity: the measured paragraph height must never be
    /// shorter than the formula's own bounds, or the formula's ink would clip against the next
    /// line -- the literal "line wraps correctly with a formula in the line" acceptance criterion.
    func testMeasure_InlineFormulaOnly_NeverShorterThanFormulaBounds() {
        let rawTeX = #"\frac{a}{\frac{b}{c}}"#
        let layout = layoutInlineMath(rawTeX: rawTeX, font: font, color: .primary, cache: nil)
        guard case .formula(_, _, let formulaMetrics) = layout else {
            return XCTFail("expected a formula layout")
        }

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

        let measured = TextMeasurementContext().measure(descriptor, width: 300, formulaCache: nil)

        XCTAssertGreaterThanOrEqual(
            measured.height, formulaMetrics.height - 0.5,
            "measured height must never be shorter than the formula's own bounds -- a formula must never get clipped by a too-short line"
        )
    }

    // MARK: - 7. Multiple inline formulas as independent attachments

    func testAttributedString_MultipleInlineFormulas_BecomesDistinctAttachments() {
        let descriptor = TextDescriptor(
            content: "ab",
            font: font,
            color: .primary,
            lineLimit: nil,
            lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [
                TextRun(length: 1, font: font, color: .primary, mathSource: "x^2"),
                TextRun(length: 1, font: font, color: .primary, mathSource: "y^2")
            ],
            layoutHash: 1,
            appearanceHash: 1
        )

        let attrStr = descriptor.attributedString(formulaCache: nil, fontProvider: nil, scale: 1)

        XCTAssertEqual(
            attrStr.length, 2,
            "attributed string must have exactly 2 attachment characters (one per formula run)"
        )

        var attachmentCount = 0
        attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length), options: []) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                attachmentCount += 1
                XCTAssertTrue(
                    attachment is InlineMathAttachment,
                    "attachment must be an InlineMathAttachment instance"
                )
            }
        }

        XCTAssertEqual(attachmentCount, 2, "both runs must produce attachments")
    }

    // MARK: - 8. Malformed inline math degrades to literal

    func testAttributedString_MalformedInlineMath_DegradesToLiteral() {
        let malformed = #"\frac{1}"#
        let descriptor = TextDescriptor(
            content: malformed,
            font: font,
            color: .primary,
            lineLimit: nil,
            lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [
                TextRun(length: (malformed as NSString).length, font: font, color: .primary, mathSource: malformed)
            ],
            layoutHash: 1,
            appearanceHash: 1
        )

        let attrStr = descriptor.attributedString(formulaCache: nil, fontProvider: nil, scale: 1)

        XCTAssertEqual(
            attrStr.string, malformed,
            "malformed math must fall back to literal text, preserving the raw TeX"
        )

        var hasAttachment = false
        attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length), options: []) { attrs, _, _ in
            if attrs[.attachment] != nil {
                hasAttachment = true
            }
        }

        XCTAssertFalse(hasAttachment, "malformed math must not produce an attachment")
    }

    // MARK: - 9. Link URL preserved with math attachment

    func testAttributedString_MathRunWithLinkURL_PreservesLinkAttribute() {
        let url = URL(string: "https://example.com")!
        let descriptor = TextDescriptor(
            content: "x",
            font: font,
            color: .primary,
            lineLimit: nil,
            lineBreakMode: NSLineBreakMode.byWordWrapping.rawValue,
            runs: [
                TextRun(length: 1, font: font, color: .primary, linkURL: url, mathSource: "x^2")
            ],
            layoutHash: 1,
            appearanceHash: 1
        )

        let attrStr = descriptor.attributedString(formulaCache: nil, fontProvider: nil, scale: 1)

        let attrs = attrStr.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(
            attrs[.attachment] as? NSTextAttachment,
            "math run must produce an attachment"
        )
        XCTAssertEqual(
            attrs[.link] as? URL, url,
            "link URL must be preserved alongside the attachment"
        )
    }
}
#endif

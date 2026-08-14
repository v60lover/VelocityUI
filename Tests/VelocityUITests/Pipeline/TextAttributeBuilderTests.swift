// TextAttributeBuilderTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Bead VelocityUI-ezo.2.2: TextMeasurementContext.measure and rasterizeText must build
/// their NSAttributedString from the same attribute dictionary (TextDescriptor.makeAttributes),
/// and that dictionary must carry descriptor.color as .foregroundColor.
///
/// Bead VelocityUI-ezo.2.3 extends this with the attribute catalog: font family, symbolic
/// traits (italic), underline, strikethrough, kerning, and line spacing — all routed through
/// the same makeAttributes() builder, so no path can drift from another on these attributes.
final class TextAttributeBuilderTests: XCTestCase {

    private func makeDescriptor(
        content: String = "Attribute parity",
        color: VColorDescriptor = VColorDescriptor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1),
        font: VFontDescriptor = VFontDescriptor(size: 18, weight: 0),
        lineLimit: Int? = nil,
        underlineStyle: Int = 0,
        strikethroughStyle: Int = 0,
        kerning: CGFloat = 0,
        lineSpacing: CGFloat = 0
    ) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: font,
            color: color,
            lineLimit: lineLimit,
            lineBreakMode: 0,
            underlineStyle: underlineStyle,
            strikethroughStyle: strikethroughStyle,
            kerning: kerning,
            lineSpacing: lineSpacing,
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    /// `attributedString` (the thing both measure and rasterizeText consume) must carry
    /// exactly the attributes `makeAttributes()` produces — for both the no-lineLimit case
    /// (measure's usual path) and the lineLimit case (paragraphStyle branch). This locks the
    /// single-builder contract: there is nowhere left for the two paths to diverge.
    func testAttributedStringIsBuiltFromMakeAttributes() {
        for lineLimit in [nil, 3] as [Int?] {
            let descriptor = makeDescriptor(lineLimit: lineLimit)
            let built = descriptor.makeAttributes()
            let fromString = descriptor.attributedString.attributes(at: 0, effectiveRange: nil)

            XCTAssertEqual(
                Set(built.keys), Set(fromString.keys),
                "attributedString(lineLimit: \(String(describing: lineLimit))) must carry exactly the keys makeAttributes() produced"
            )
            XCTAssertEqual(built[.font] as? UIFont, fromString[.font] as? UIFont)
            XCTAssertEqual(built[.foregroundColor] as? UIColor, fromString[.foregroundColor] as? UIColor)

            if lineLimit != nil {
                XCTAssertNotNil(fromString[.paragraphStyle])
            } else {
                XCTAssertNil(fromString[.paragraphStyle])
            }
        }
    }

    /// Determinism: calling makeAttributes() twice for the same descriptor must yield
    /// equal font/color attributes — a prerequisite for measure and rasterize to ever agree.
    func testMakeAttributesIsDeterministic() {
        let descriptor = makeDescriptor()
        let a = descriptor.makeAttributes()
        let b = descriptor.makeAttributes()
        XCTAssertEqual(a[.font] as? UIFont, b[.font] as? UIFont)
        XCTAssertEqual(a[.foregroundColor] as? UIColor, b[.foregroundColor] as? UIColor)
    }

    /// Color must reach rendered pixels: a red descriptor.color must not rasterize as black ink.
    /// Reads the highest-alpha (most opaque) pixel and unpremultiplies it, so anti-aliased edge
    /// pixels — which are near-black after premultiplication regardless of ink color — can't
    /// produce a false pass or false fail.
    func testForegroundColorAppliesToRenderedInk() {
        let color = VColorDescriptor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let descriptor = makeDescriptor(color: color)
        let measured = TextMeasurementContext().measure(descriptor, width: 320)
        XCTAssertGreaterThan(measured.width, 0)
        XCTAssertGreaterThan(measured.height, 0)

        guard let image = rasterizeText(descriptor, size: measured) else {
            XCTFail("rasterizeText returned nil"); return
        }
        guard let ink = strongestInkPixelColor(in: image) else {
            XCTFail("No ink found in rendered image"); return
        }
        XCTAssertFalse(
            ink.r == 0 && ink.g == 0 && ink.b == 0,
            "Ink rendered as pure black — .foregroundColor was not applied"
        )
        XCTAssertGreaterThan(ink.r, 100, "Red-heavy descriptor.color should produce red-heavy rendered ink")
    }

    // MARK: - ezo.2.3: family / traits

    /// A known system-bundled family (Georgia) must be resolved and carried into the
    /// attributed string's .font attribute — round-trips through the shared builder.
    func testKnownFontFamilyResolvesToNamedFont() {
        let descriptor = makeDescriptor(font: VFontDescriptor(size: 18, weight: 0).family("Georgia"))
        let font = descriptor.makeAttributes()[.font] as? UIFont
        XCTAssertEqual(font?.familyName, "Georgia")
    }

    /// An unknown/misspelled family must fall back to the system font deterministically —
    /// never crash, and produce the exact same font makeAttributes() would produce with no
    /// family set at all.
    func testUnknownFontFamilyFallsBackToSystemFont() {
        let systemDescriptor = makeDescriptor(font: VFontDescriptor(size: 18, weight: 0))
        let unknownDescriptor = makeDescriptor(
            font: VFontDescriptor(size: 18, weight: 0).family("ThisFontDoesNotExist-12345")
        )
        let systemFont = systemDescriptor.makeAttributes()[.font] as? UIFont
        let fallbackFont = unknownDescriptor.makeAttributes()[.font] as? UIFont
        XCTAssertEqual(systemFont, fallbackFont)
    }

    /// The italic symbolic trait must reach the resolved UIFont's fontDescriptor, and must
    /// compose with a custom family rather than being dropped.
    func testItalicTraitAppliesToResolvedFont() {
        let descriptor = makeDescriptor(font: VFontDescriptor(size: 18, weight: 0).italic)
        let font = descriptor.makeAttributes()[.font] as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false)

        let withFamily = makeDescriptor(font: VFontDescriptor(size: 18, weight: 0).family("Georgia").italic)
        let familyFont = withFamily.makeAttributes()[.font] as? UIFont
        XCTAssertEqual(familyFont?.familyName, "Georgia")
        XCTAssertTrue(familyFont?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false)
    }

    // MARK: - ezo.2.3: underline / strikethrough / kerning / lineSpacing round-trip + footguns

    /// underlineStyle/strikethroughStyle round-trip verbatim when non-zero, and must be
    /// absent entirely (not merely 0) when unset — the default TextDescriptor() case must
    /// produce exactly the same attribute set as before this bead.
    func testUnderlineAndStrikethroughRoundTripAndAreAbsentWhenUnset() {
        let unset = makeDescriptor()
        XCTAssertNil(unset.makeAttributes()[.underlineStyle])
        XCTAssertNil(unset.makeAttributes()[.strikethroughStyle])

        let styled = makeDescriptor(
            underlineStyle: NSUnderlineStyle.single.rawValue,
            strikethroughStyle: NSUnderlineStyle.thick.rawValue
        )
        XCTAssertEqual(styled.makeAttributes()[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(styled.makeAttributes()[.strikethroughStyle] as? Int, NSUnderlineStyle.thick.rawValue)
    }

    /// kerning: 0 must NOT add .kern at all — setting .kern to 0 explicitly disables the
    /// font's own default kerning, which would regress every caller that never asked for a
    /// kerning override. A non-zero value must round-trip verbatim.
    func testKerningOnlyAddedWhenNonZero() {
        let unset = makeDescriptor()
        XCTAssertNil(unset.makeAttributes()[.kern])

        let kerned = makeDescriptor(kerning: 2.5)
        XCTAssertEqual(kerned.makeAttributes()[.kern] as? CGFloat, 2.5)
    }

    /// lineSpacing must reach the paragraph style even when lineLimit is nil (previously the
    /// paragraph style was only built for the lineLimit branch).
    func testLineSpacingBuildsParagraphStyleWithoutLineLimit() {
        let descriptor = makeDescriptor(lineSpacing: 6)
        let para = descriptor.makeAttributes()[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(para?.lineSpacing, 6)
    }

    /// lineSpacing is an inter-line gap: on a single line (the fixture the tests above and
    /// below use) it has nothing to space and the checks pass trivially regardless of whether
    /// lineSpacing is wired correctly. Forcing two lines via an explicit newline exercises the
    /// actual mechanism: height must grow with lineSpacing, and the rendered ink still has to
    /// land within the same +1pt overflow budget as every other attribute.
    func testLineSpacingGrowsMultilineMeasuredHeightAndStaysWithinParity() {
        let multilineContent = "Attribute parity\nAttribute parity"
        let measureCtx = TextMeasurementContext()

        let noSpacing = makeDescriptor(content: multilineContent, lineSpacing: 0)
        let withSpacing = makeDescriptor(content: multilineContent, lineSpacing: 12)

        let measuredNoSpacing = measureCtx.measure(noSpacing, width: 320)
        let measuredWithSpacing = measureCtx.measure(withSpacing, width: 320)

        XCTAssertGreaterThan(
            measuredWithSpacing.height, measuredNoSpacing.height,
            "lineSpacing must measurably grow height across multiple lines — a single-line fixture can never show this"
        )

        guard let image = rasterizeText(withSpacing, size: measuredWithSpacing) else {
            XCTFail("rasterizeText returned nil"); return
        }
        let inkHeight = actualContentHeight(in: image)
        XCTAssertLessThanOrEqual(
            inkHeight, measuredWithSpacing.height + 1,
            "ink \(inkHeight)pt overflowed measured \(measuredWithSpacing.height)pt by more than 1pt with non-zero lineSpacing"
        )
    }

    // MARK: - ezo.2.3: measure == render within 1pt, per attribute and combined

    /// Every new attribute — in isolation and combined — must not perturb the
    /// measure/render parity contract from ezo.2.2/Spike 4: rendered ink must never overflow
    /// the measured height by more than 1pt.
    func testMeasureEqualsRenderWithin1ptForEachNewAttribute() {
        let variants: [(String, TextDescriptor)] = [
            ("family", makeDescriptor(font: VFontDescriptor(size: 18, weight: 0).family("Georgia"))),
            ("italic", makeDescriptor(font: VFontDescriptor(size: 18, weight: 0).italic)),
            ("underline", makeDescriptor(underlineStyle: NSUnderlineStyle.single.rawValue)),
            ("underline-double", makeDescriptor(underlineStyle: NSUnderlineStyle.double.rawValue)),
            ("strikethrough", makeDescriptor(strikethroughStyle: NSUnderlineStyle.single.rawValue)),
            ("kerning", makeDescriptor(kerning: 3)),
            ("lineSpacing", makeDescriptor(lineSpacing: 8)),
            ("combined", makeDescriptor(
                font: VFontDescriptor(size: 18, weight: 0).family("Georgia").italic,
                underlineStyle: NSUnderlineStyle.single.rawValue,
                strikethroughStyle: NSUnderlineStyle.single.rawValue,
                kerning: 3,
                lineSpacing: 8
            ))
        ]

        let measureCtx = TextMeasurementContext()
        for (name, descriptor) in variants {
            let measured = measureCtx.measure(descriptor, width: 320)
            XCTAssertGreaterThan(measured.width, 0, "\(name): zero measured width")
            XCTAssertGreaterThan(measured.height, 0, "\(name): zero measured height")

            guard let image = rasterizeText(descriptor, size: measured) else {
                XCTFail("\(name): rasterizeText returned nil"); continue
            }
            let inkHeight = actualContentHeight(in: image)
            XCTAssertLessThanOrEqual(
                inkHeight, measured.height + 1,
                "\(name): ink \(inkHeight)pt overflowed measured \(measured.height)pt by more than 1pt"
            )
        }
    }

    /// Scans from the bottom of the image upward and returns the height (in pixels) of the
    /// last row that contains any non-transparent pixel. Mirrors Spike4Tests' helper of the
    /// same shape — kept local since each test file's fixtures are self-contained.
    private func actualContentHeight(in image: CGImage) -> CGFloat {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for row in stride(from: h - 1, through: 0, by: -1) {
            for col in 0..<w {
                if bytes[(row * w + col) * 4 + 3] > 0 { return CGFloat(row + 1) }
            }
        }
        return 0
    }

    /// Scans the whole image for the pixel with the highest alpha (the most opaque point of a
    /// glyph stroke) and returns its unpremultiplied RGB, 0-255 per channel.
    private func strongestInkPixelColor(in image: CGImage) -> (r: Int, g: Int, b: Int)? {
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
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var best: (alpha: Int, r: Int, g: Int, b: Int)?
        for row in 0..<h {
            for col in 0..<w {
                let idx = (row * w + col) * 4
                let alpha = Int(bytes[idx + 3])
                guard alpha > 0, best == nil || alpha > best!.alpha else { continue }
                best = (alpha, Int(bytes[idx]), Int(bytes[idx + 1]), Int(bytes[idx + 2]))
            }
        }
        guard let strongest = best else { return nil }
        return (
            min(255, strongest.r * 255 / strongest.alpha),
            min(255, strongest.g * 255 / strongest.alpha),
            min(255, strongest.b * 255 / strongest.alpha)
        )
    }
}
#endif

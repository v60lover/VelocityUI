// TextAttributeBuilderTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Bead VelocityUI-ezo.2.2: TextMeasurementContext.measure and rasterizeText must build
/// their NSAttributedString from the same attribute dictionary (TextDescriptor.makeAttributes),
/// and that dictionary must carry descriptor.color as .foregroundColor.
final class TextAttributeBuilderTests: XCTestCase {

    private func makeDescriptor(
        color: VColorDescriptor = VColorDescriptor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1),
        lineLimit: Int? = nil
    ) -> TextDescriptor {
        TextDescriptor(
            content: "Attribute parity",
            font: VFontDescriptor(size: 18, weight: 0),
            color: color,
            lineLimit: lineLimit,
            lineBreakMode: 0,
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

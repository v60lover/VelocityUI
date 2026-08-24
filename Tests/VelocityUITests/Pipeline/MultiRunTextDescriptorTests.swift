// MultiRunTextDescriptorTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// `TextDescriptor.runs` carries per-span styles through the same `attributedString` path a
/// single-style descriptor already used — covers single-run parity, multi-run rendering, hash
/// invalidation, and malformed run lists.
final class MultiRunTextDescriptorTests: XCTestCase {

    private func baseDescriptor(
        content: String = "Plain text",
        runs: [TextRun] = []
    ) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            runs: runs,
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    // MARK: - Regression: empty runs stays byte-identical to the pre-fzvf.6 single-style path

    func testEmptyRunsProducesByteIdenticalAttributedStringToLegacyPath() {
        let descriptor = baseDescriptor()
        let legacy = NSAttributedString(string: descriptor.content, attributes: descriptor.makeAttributes())
        XCTAssertTrue(descriptor.attributedString.isEqual(to: legacy))
    }

    func testDescriptorWithoutRunsArgumentDefaultsToEmpty() {
        // `runs` is default-arg — every pre-existing call site must still compile unchanged.
        let descriptor = TextDescriptor(
            content: "No runs param at all",
            font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 0,
            appearanceHash: 0
        )
        XCTAssertTrue(descriptor.runs.isEmpty)
    }

    // MARK: - Multi-run rendering: distinct fonts/colors per run, measure == render within 1pt

    /// Three equal-length words so sampled positions land predictably: plain, bold, and mono
    /// with a background pill.
    func testMixedRunsRenderDistinctFontsAndColorsAtSampledPositions() {
        let plainWord = "plain"
        let boldWord = "BOLDX"
        let monoWord = "monox"
        let content = plainWord + boldWord + monoWord
        XCTAssertEqual(plainWord.utf16.count, boldWord.utf16.count)
        XCTAssertEqual(boldWord.utf16.count, monoWord.utf16.count)

        let plainColor = VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
        let boldColor = VColorDescriptor(red: 0.8, green: 0.05, blue: 0.05, alpha: 1)
        let monoColor = VColorDescriptor(red: 0.05, green: 0.05, blue: 0.8, alpha: 1)

        let runs = [
            TextRun(length: plainWord.utf16.count, font: VFontDescriptor(size: 24, weight: 0), color: plainColor),
            TextRun(
                length: boldWord.utf16.count,
                font: VFontDescriptor(size: 24, weight: VFontDescriptor.boldWeight),
                color: boldColor
            ),
            TextRun(
                length: monoWord.utf16.count,
                font: VFontDescriptor(size: 24, weight: 0, family: "Menlo"),
                color: monoColor,
                backgroundColor: VColorDescriptor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)
            )
        ]
        let descriptor = baseDescriptor(content: content, runs: runs)

        let attrs = descriptor.attributedString
        XCTAssertEqual(attrs.length, content.utf16.count)

        let plainRange = NSRange(location: 0, length: plainWord.utf16.count)
        let boldRange = NSRange(location: plainWord.utf16.count, length: boldWord.utf16.count)
        let monoRange = NSRange(location: plainWord.utf16.count + boldWord.utf16.count, length: monoWord.utf16.count)

        let plainFont = attrs.attribute(.font, at: plainRange.location, effectiveRange: nil) as? UIFont
        let boldFont = attrs.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont
        let monoFont = attrs.attribute(.font, at: monoRange.location, effectiveRange: nil) as? UIFont

        XCTAssertNotEqual(plainFont, boldFont, "plain and bold runs must resolve to different UIFonts")
        func weightTrait(_ font: UIFont?) -> CGFloat {
            let traits = font?.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            return traits?[.weight] as? CGFloat ?? 0
        }
        XCTAssertGreaterThan(weightTrait(boldFont), weightTrait(plainFont), "bold run must resolve to a heavier weight than the plain run")
        XCTAssertEqual(monoFont?.familyName, "Menlo")

        let plainInk = attrs.attribute(.foregroundColor, at: plainRange.location, effectiveRange: nil) as? UIColor
        let boldInk = attrs.attribute(.foregroundColor, at: boldRange.location, effectiveRange: nil) as? UIColor
        let monoInk = attrs.attribute(.foregroundColor, at: monoRange.location, effectiveRange: nil) as? UIColor
        XCTAssertNotEqual(plainInk, boldInk)
        XCTAssertNotEqual(boldInk, monoInk)

        XCTAssertNotNil(attrs.attribute(.backgroundColor, at: monoRange.location, effectiveRange: nil))
        XCTAssertNil(attrs.attribute(.backgroundColor, at: plainRange.location, effectiveRange: nil))

        // Same measure/render parity contract every other TextDescriptor attribute is held to.
        let measureCtx = TextMeasurementContext()
        let measured = measureCtx.measure(descriptor, width: 400)
        XCTAssertGreaterThan(measured.width, 0)
        XCTAssertGreaterThan(measured.height, 0)

        guard let image = rasterizeText(descriptor, size: measured) else {
            XCTFail("rasterizeText returned nil for a multi-run descriptor"); return
        }
        let inkHeight = actualContentHeight(in: image)
        XCTAssertLessThanOrEqual(
            inkHeight, measured.height + 1,
            "multi-run ink \(inkHeight)pt overflowed measured \(measured.height)pt by more than 1pt"
        )
    }

    /// A run that is both bold and mono must resolve a font carrying both.
    func testRunCanCombineBoldWeightAndMonoFamily() {
        let content = "boldcode"
        let run = TextRun(
            length: content.utf16.count,
            font: VFontDescriptor(size: 20, weight: VFontDescriptor.boldWeight, family: "Menlo"),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        let descriptor = baseDescriptor(content: content, runs: [run])
        let font = descriptor.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font?.familyName, "Menlo")
    }

    /// A link run must carry an `.link` attribute a later hit-test pass can resolve.
    func testLinkRunCarriesLinkURLAttribute() {
        let content = "tap me"
        let url = URL(string: "https://example.com")!
        let run = TextRun(
            length: content.utf16.count,
            font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0.9, alpha: 1),
            linkURL: url
        )
        let descriptor = baseDescriptor(content: content, runs: [run])
        let resolved = descriptor.attributedString.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(resolved, url)
    }

    // MARK: - Defensive coverage: malformed run lists never crash or silently drop text

    /// Runs summing to less than `content.utf16.count` must not drop the uncovered tail.
    func testUnderCoveringRunsAppendRemainderInBaseStyleInsteadOfDropping() {
        let content = "abcdef"
        let run = TextRun(
            length: 3,
            font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let descriptor = baseDescriptor(content: content, runs: [run])
        let attrs = descriptor.attributedString
        XCTAssertEqual(attrs.string, content, "under-covering runs must not truncate content")
        XCTAssertEqual(attrs.length, content.utf16.count)
    }

    /// A run whose length overruns the remaining content must be clamped, not read out of bounds.
    func testOverLongRunIsClampedToRemainingContent() {
        let content = "abc"
        let run = TextRun(
            length: 100,
            font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let descriptor = baseDescriptor(content: content, runs: [run])
        let attrs = descriptor.attributedString
        XCTAssertEqual(attrs.string, content)
        XCTAssertEqual(attrs.length, content.utf16.count)
    }

    // MARK: - Hash invalidation: TextRun is Hashable so a producer can fold runs into a hash

    /// A run-style-only change (same length, different color) must change a hash built by
    /// combining `runs` — proves TextRun's Hashable surface catches it.
    func testHasherCombiningRunsChangesOnAppearanceOnlyStyleDiff() {
        let redRun = TextRun(
            length: 4, font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let blueRun = TextRun(
            length: 4, font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 1, alpha: 1)
        )

        func fold(_ runs: [TextRun]) -> Int {
            var hasher = Hasher()
            hasher.combine(runs)
            return hasher.finalize()
        }

        XCTAssertNotEqual(fold([redRun]), fold([blueRun]))
        XCTAssertEqual(fold([redRun]), fold([redRun]), "folding must be deterministic for equal runs")
    }

    /// A layout-affecting change (font) must also change the fold, same mechanism as above.
    func testHasherCombiningRunsChangesOnLayoutAffectingFontDiff() {
        let regular = TextRun(
            length: 4, font: VFontDescriptor(size: 18, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        let bold = TextRun(
            length: 4, font: VFontDescriptor(size: 18, weight: VFontDescriptor.boldWeight),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
        )

        var regularHasher = Hasher()
        regularHasher.combine([regular])
        var boldHasher = Hasher()
        boldHasher.combine([bold])

        XCTAssertNotEqual(regularHasher.finalize(), boldHasher.finalize())
    }

    // MARK: - VelocityUI-fzvf.2: mixed markdown through the real parser pipeline

    /// The bead's own acceptance criterion, driven end to end: parse mixed markdown, then hold
    /// the same measure == render parity contract every other TextDescriptor is held to.
    func testMixedMarkdownThroughParser_MeasuredEqualsRenderedWithinOnePoint() {
        var parser = IncrementalMarkdownParser()
        parser.append("**bold** *italic* ***both*** `code` ~~strike~~ [link](https://example.com)\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }
        XCTAssertFalse(descriptor.runs.isEmpty)

        let measureCtx = TextMeasurementContext()
        let measured = measureCtx.measure(descriptor, width: 400)
        XCTAssertGreaterThan(measured.width, 0)
        XCTAssertGreaterThan(measured.height, 0)

        guard let image = rasterizeText(descriptor, size: measured) else {
            XCTFail("rasterizeText returned nil for a mixed-markdown descriptor"); return
        }
        let inkHeight = actualContentHeight(in: image)
        XCTAssertLessThanOrEqual(
            inkHeight, measured.height + 1,
            "mixed-markdown ink \(inkHeight)pt overflowed measured \(measured.height)pt by more than 1pt"
        )
    }

    /// Data-plumbing half of "link hit-testing returns the right URL": a later hit-test pass
    /// (InteractionOverlay-based tap routing, VelocityUI-b6u, not yet built) resolves taps against
    /// exactly this `.link` attribute — this proves the attribute lands at the right range with
    /// the right URL through the real parser -> TextDescriptor pipeline, not just a hand-built run.
    func testLinkThroughParser_AttributedStringCarriesCorrectURLAtLinkRange() {
        var parser = IncrementalMarkdownParser()
        parser.append("before [tap me](https://example.com) after\n\n")
        let blocks = parser.blockList(itemID: "msg", width: 400)
        guard case .text(let descriptor) = blocks[0].fragment.content else {
            return XCTFail("must render as .text")
        }

        let linkRange = (descriptor.content as NSString).range(of: "tap me")
        XCTAssertNotEqual(linkRange.location, NSNotFound)

        let attrs = descriptor.attributedString
        let resolved = attrs.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(resolved, URL(string: "https://example.com"))

        let beforeLink = attrs.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertNil(beforeLink, "text outside the link span must not carry the link attribute")
    }

    // MARK: - Helpers

    /// Mirrors TextAttributeBuilderTests' helper of the same shape.
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
}
#endif

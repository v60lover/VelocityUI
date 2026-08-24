// VFontDescriptorWeightTests.swift

import XCTest
@testable import VelocityUI

/// Regression guard: `VFontDescriptor.weight` stores `UIFont.Weight`'s raw `Double`
/// bit-pattern-encoded into an `Int` (`TextRasteriser.uiFontWeight` decodes it back). A plain
/// small literal like `4` or `7` decodes to a near-zero subnormal double, not the weight it
/// looks like — `IncrementalMarkdownParser.style()` did exactly that until this fix, so every
/// markdown block (including headings) silently rendered at `.regular` weight. Split from the
/// UIKit-dependent decode assertions (below, `#if canImport(UIKit)`, device-only per
/// `HotBlockMeasurerTests.swift`'s precedent) so the math itself is still checked under plain
/// `swift test`.
final class VFontDescriptorWeightTests: XCTestCase {

    func testRawSmallIntegerLiteral_DoesNotRoundTripAsItself() {
        // The bug this fix removes: a naive `weight: 7` does NOT decode back to anything near 7 —
        // reinterpreting the integer's bits as a Double's bit pattern yields a near-zero subnormal.
        let decoded = Double(bitPattern: UInt64(bitPattern: Int64(7)))
        XCTAssertLessThan(abs(decoded), 0.001, "a raw literal must decode near zero, not 7.0")
    }

    func testRegularAndBoldWeight_RoundTripThroughTheSameBitPatternTextRasteriserUses() {
        func decode(_ weight: Int) -> Double {
            Double(bitPattern: UInt64(bitPattern: Int64(weight)))
        }
        XCTAssertEqual(decode(VFontDescriptor.regularWeight), 0.0)
        XCTAssertEqual(decode(VFontDescriptor.boldWeight), 0.4, accuracy: 0.0001)
    }

    func testIncrementalMarkdownParser_HeadingUsesBoldWeight_OthersUseRegularWeight() {
        let heading = IncrementalMarkdownParser.style(ParsedMDBlock(kind: .heading(level: 1), text: "Title"))
        XCTAssertEqual(heading.font.weight, VFontDescriptor.boldWeight)

        let paragraph = IncrementalMarkdownParser.style(ParsedMDBlock(kind: .paragraph, text: "Body"))
        XCTAssertEqual(paragraph.font.weight, VFontDescriptor.regularWeight)
    }
}

#if canImport(UIKit)
import UIKit

final class VFontDescriptorWeightUIKitDecodeTests: XCTestCase {

    private func descriptor(weight: Int) -> TextDescriptor {
        TextDescriptor(
            content: "x",
            font: VFontDescriptor(size: 20, weight: weight),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    func testRegularWeight_DecodesToUIFontWeightRegular() {
        XCTAssertEqual(descriptor(weight: VFontDescriptor.regularWeight).uiFontWeight, .regular)
    }

    func testBoldWeight_DecodesToUIFontWeightBold() {
        let weight = descriptor(weight: VFontDescriptor.boldWeight).uiFontWeight
        XCTAssertEqual(weight.rawValue, UIFont.Weight.bold.rawValue, accuracy: 0.0001)
    }
}
#endif

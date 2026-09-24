// TextSelectionOffsetMapTests.swift

import XCTest
@testable import VelocityUI

final class TextSelectionOffsetMapTests: XCTestCase {
    /// content = "x^2 and y": TeX run [0,3) becomes one attachment char, then " and y" (6 units).
    private func mathThenPlain() -> (TextSelectionOffsetMap, String) {
        var map = TextSelectionOffsetMap()
        map.append(kitLength: 1, contentStart: 0, contentLength: 3, isMath: true)
        map.append(kitLength: 6, contentStart: 3, contentLength: 6, isMath: false)
        return (map, "x^2 and y")
    }

    func testPlainRangeAfterFormulaUsesContentOffsets() {
        let (map, content) = mathThenPlain()
        // TextKit offset 5 is "y" (kit: "\u{FFFC} and y"); content offset is 8.
        XCTAssertEqual(map.copiedText(kitRange: NSRange(location: 6, length: 1), content: content), "y")
    }

    func testFormulaInRangeCopiesAsDollarWrappedSource() {
        let (map, content) = mathThenPlain()
        XCTAssertEqual(map.copiedText(kitRange: NSRange(location: 0, length: 5), content: content), "$x^2$ and")
    }

    func testRangeInsideOnlyPlainTextSkipsFormula() {
        let (map, content) = mathThenPlain()
        XCTAssertEqual(map.copiedText(kitRange: NSRange(location: 1, length: 4), content: content), " and")
    }

    func testBuilderRecordsMapOnlyWhenAsked() {
        var map: TextSelectionOffsetMap? = TextSelectionOffsetMap()
        let d = TextDescriptor(
            content: "hello", font: VFontDescriptor(size: 14, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil, lineBreakMode: 0, layoutHash: 1, appearanceHash: 1
        )
        _ = d.attributedString(formulaCache: nil, fontProvider: nil, scale: 1, offsetMap: &map)
        XCTAssertEqual(map?.copiedText(kitRange: NSRange(location: 1, length: 3), content: "hello"), "ell")
    }
}

// TextSelectionSessionTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class TextSelectionSessionTests: XCTestCase {
    private func makeSession(_ content: String, origin: CGPoint = CGPoint(x: 10, y: 20), wrap: CGFloat = 300) -> TextSelectionSession {
        let d = TextDescriptor(
            content: content, font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil, lineBreakMode: 0, layoutHash: 1, appearanceHash: 1
        )
        return TextSelectionSession(
            itemIndex: 0, nodeIndex: 0, descriptor: d, origin: origin, wrapWidth: wrap,
            scale: 1, formulaCache: nil, fontProvider: nil
        )
    }

    func testBeginSelectsWordUnderPointAndCopiesRawText() {
        let s = makeSession("hello world")
        XCTAssertTrue(s.begin(at: CGPoint(x: 12, y: 28)))
        XCTAssertEqual(s.copiedText, "hello")
        XCTAssertFalse(s.selectionRects.isEmpty)
    }

    func testHighlightRectsAreOffsetByOrigin() throws {
        let s = makeSession("hello world", origin: CGPoint(x: 10, y: 20))
        XCTAssertTrue(s.begin(at: CGPoint(x: 12, y: 28)))
        let rect = try XCTUnwrap(s.selectionRects.first)
        XCTAssertGreaterThanOrEqual(rect.minX, 10)
        XCTAssertGreaterThanOrEqual(rect.minY, 20)
    }

    func testExtendGrowsSelectionToTheDragPoint() {
        let s = makeSession("hello world")
        XCTAssertTrue(s.begin(at: CGPoint(x: 12, y: 28)))
        s.extend(to: CGPoint(x: 280, y: 28))
        XCTAssertEqual(s.copiedText, "hello world")
    }

    func testMultiLineSelectionYieldsOneRectPerLine() {
        let s = makeSession("aaaa bbbb cccc dddd", wrap: 50)
        XCTAssertTrue(s.begin(at: CGPoint(x: 12, y: 28)))
        s.extend(to: CGPoint(x: 400, y: 400))
        XCTAssertGreaterThan(s.selectionRects.count, 1)
        XCTAssertEqual(s.copiedText, "aaaa bbbb cccc dddd")
    }

    func testBeginOutsideTextReturnsFalse() {
        let s = makeSession("")
        XCTAssertFalse(s.begin(at: CGPoint(x: 12, y: 28)))
    }
}
#endif

// LayoutEngineCodeBlockTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// VelocityUI-yvjr: `measureNode`'s `.text` case must measure a code block's body leaf as wide as
/// its longest line, not clamped to the proposed container width -- this is the wiring
/// `RenderPipeline.onIndexBoundary` and `AsyncFeed.warmUp` share via `measureNode`.
final class LayoutEngineCodeBlockTests: XCTestCase {
    private let font = VFontDescriptor(size: 15, weight: 0, family: "Menlo")

    private func codeBodyDescriptor(_ content: String) -> TextDescriptor {
        TextDescriptor(
            content: content, font: font,
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil, lineBreakMode: NSLineBreakMode.byClipping.rawValue,
            layoutHash: 1, appearanceHash: 1,
            codeBlockRole: .body(CodeBlockChrome(cornerRadius: 12, backgroundColor: .codeBlockBackground, language: "swift"))
        )
    }

    func testSealedCodeBlockBody_measuresWiderThanContainer_notClamped() async throws {
        let longLine = String(repeating: "m", count: 80)
        let content = "x\n" + longLine
        let table = NodeTable(
            itemID: "t1",
            nodes: [.text(codeBodyDescriptor(content))],
            parentIndices: [-1],
            layoutHash: 10, appearanceHash: 10
        )
        let pool = TextMeasurementPool(capacity: 1)
        let narrowWidth: CGFloat = 100

        let layout = await measureNode(table, nodeIndex: 0, width: narrowWidth, textPool: pool)

        // Solo-measure the longest line at unbounded width -- must match, proving the body
        // measured its true intrinsic width instead of clamping to `narrowWidth`.
        let solo = makeCodeTextDescriptor(lines: [longLine][...], colorRuns: [LineColorRuns(runs: [])], font: font, theme: .defaultLight)
        let soloSize = TextMeasurementContext().measure(solo, width: .greatestFiniteMagnitude)

        XCTAssertGreaterThan(layout.totalFrame.width, narrowWidth, "code body must not clamp to the container width")
        XCTAssertEqual(layout.totalFrame.width, soloSize.width, accuracy: 1)
    }

    func testHeaderRole_stillMeasuresAtProposedWidth_unaffected() async throws {
        // Sanity: the header leaf (short language label) isn't accidentally swept into the
        // wide-measurement branch -- only `.body` is.
        let header = TextDescriptor(
            content: "swift", font: font,
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil, lineBreakMode: 0,
            layoutHash: 1, appearanceHash: 1,
            codeBlockRole: .header(CodeBlockChrome(cornerRadius: 12, backgroundColor: .codeBlockBackground, language: "swift"))
        )
        let table = NodeTable(
            itemID: "t1", nodes: [.text(header)], parentIndices: [-1], layoutHash: 10, appearanceHash: 10
        )
        let pool = TextMeasurementPool(capacity: 1)
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: pool)
        XCTAssertLessThanOrEqual(layout.totalFrame.width, 320 + 1)
    }
}
#endif

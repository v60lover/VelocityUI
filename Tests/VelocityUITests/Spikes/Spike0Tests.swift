// Spike0Tests.swift

import XCTest
@testable import VelocityUI

/// Smoke tests confirming the package scaffolding is correct.
/// All substantive spike tests live in Spike1Tests–Spike4Tests.
final class Spike0Tests: XCTestCase {

    func testPackageImports() {
        // If this compiles and runs, the package structure is valid.
        let layout = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 100, height: 44))
        XCTAssertEqual(layout.totalFrame.width, 100)
        XCTAssertEqual(layout.totalFrame.height, 44)
    }

    func testNodeTableChildren() {
        let table = NodeTable(
            itemID: "test",
            nodes: [
                .vstack(VStackDescriptor.test(alignment: 0, spacing: 8)),
                .image(ImageDescriptor(url: nil, aspectRatio: 1.0, contentMode: 0,
                                       cornerRadius: 0, layoutHash: 1, appearanceHash: 1)),
                .text(TextDescriptor(content: "Hello", font: VFontDescriptor(size: 14, weight: 0),
                                     color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                                     lineLimit: nil, lineBreakMode: 0, layoutHash: 2, appearanceHash: 2))
            ],
            parentIndices: [-1, 0, 0],
            layoutHash: 3,
            appearanceHash: 3
        )

        let children = table.children(of: 0)
        XCTAssertEqual(children, [1, 2])
        XCTAssertEqual(table.children(of: 1), [])
    }

    func testWorkingRangeBasic() async {
        let range = await WorkingRange(capacity: 10)
        let layout = ResolvedLayout(totalFrame: CGRect(x: 0, y: 0, width: 100, height: 200))

        await range.commit(layout, at: 3)
        let result = await range.layout(at: 3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.totalFrame.height, 200)

        let outOfRange = await range.layout(at: 15)
        XCTAssertNil(outOfRange)
    }
}

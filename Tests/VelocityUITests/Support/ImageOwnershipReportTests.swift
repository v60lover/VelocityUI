// ImageOwnershipReportTests.swift

import CoreGraphics
import XCTest
@testable import VelocityUI

final class ImageOwnershipReportTests: XCTestCase {
    private func makeImage(_ side: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        return ctx.makeImage()!
    }

    func testSharedImageCountsOnceInTotal() {
        let shared = makeImage(8)
        let own = makeImage(4)
        let report = ImageOwnershipReport([
            ImageOwnerSnapshot(owner: "a", images: [shared, own]),
            ImageOwnerSnapshot(owner: "b", images: [shared]),
        ])
        XCTAssertEqual(report.uniqueImageCount, 2)
        XCTAssertEqual(report.rows[1].refCount, 1)
        XCTAssertEqual(report.rows[1].uniqueBytes, 0)
        XCTAssertEqual(report.uniqueBytes, report.rows[0].heldBytes)
    }

    #if canImport(UIKit)
    @MainActor
    func testEnvironmentReportSeesVisibleStoreImage() {
        let env = RenderEnvironment()
        let image = makeImage(8)
        env.visibleBlockStore.store(image, size: CGSize(width: 8, height: 8), for: BlockKey(itemID: 1, index: 0))
        let report = env.debugImageReport()
        XCTAssertEqual(report.rows.first { $0.owner == "visible" }?.refCount, 1)
    }
    #endif
}

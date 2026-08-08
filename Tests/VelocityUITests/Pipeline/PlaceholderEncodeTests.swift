// PlaceholderEncodeTests.swift

#if canImport(UIKit)
import CoreGraphics
import UIKit
import XCTest
@testable import VelocityUI

final class PlaceholderEncodeTests: XCTestCase {

    private func makeSolidColorImage(_ color: UIColor, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // MARK: - Encode correctness

    func testEncodeProducesWellFormedHashForDefaultComponents() {
        let image = makeSolidColorImage(.systemBlue, width: 64, height: 64)
        guard let hash = encodeBlurHash(image) else {
            XCTFail("solid-color image must encode")
            return
        }
        // sizeFlag(1) + quantisedMax(1) + dc(4) + ac(2 per non-DC component). Default
        // componentsX=4, componentsY=3 -> 12 components, 11 AC pairs.
        XCTAssertEqual(hash.count, 6 + 2 * 11)
        XCTAssertNotNil(decodeBlurHashPlaceholder(hash, targetSize: CGSize(width: 40, height: 40), cornerRadius: 0),
            "a hash this function produces must itself be decodable")
    }

    func testEncodeIsDeterministic() {
        let image = makeSolidColorImage(.systemOrange, width: 48, height: 48)
        let hash1 = encodeBlurHash(image)
        let hash2 = encodeBlurHash(image)
        XCTAssertEqual(hash1, hash2, "encoding the same image twice must produce the same hash")
    }

    func testEncodeClampsComponentCountsToBlurHashRange() {
        let image = makeSolidColorImage(.systemGreen, width: 32, height: 32)
        guard let hash = encodeBlurHash(image, componentsX: 0, componentsY: 20) else {
            XCTFail("must still encode with out-of-range component counts")
            return
        }
        // componentsX clamped to 1, componentsY clamped to 9 -> 9 components, 8 AC pairs.
        XCTAssertEqual(hash.count, 6 + 2 * 8)
    }

    func testEncodeHandlesNonSquareAspectRatio() {
        let wide = makeSolidColorImage(.systemRed, width: 200, height: 50)
        let tall = makeSolidColorImage(.systemRed, width: 50, height: 200)
        XCTAssertNotNil(encodeBlurHash(wide))
        XCTAssertNotNil(encodeBlurHash(tall))
    }

    func testEncodeZeroSizedImageReturnsNilWithoutCrashing() {
        let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let oneByOne = ctx.makeImage()!
        XCTAssertNotNil(encodeBlurHash(oneByOne), "a valid 1x1 image is a degenerate but legal source")
    }

    // MARK: - Round-trip fidelity

    func testEncodeThenDecodeApproximatesSolidColor() {
        // A flat-color source's DC (average) term should dominate; decoding the resulting
        // hash should reproduce a color close to the original everywhere in the grid.
        let image = makeSolidColorImage(.systemBlue, width: 64, height: 64)
        guard let hash = encodeBlurHash(image),
              let decoded = decodeBlurHashPlaceholder(hash, targetSize: CGSize(width: 64, height: 64), cornerRadius: 0)
        else {
            XCTFail("encode -> decode round trip must succeed")
            return
        }
        guard let data = decoded.dataProvider?.data as Data? else {
            XCTFail("decoded image must expose pixel data")
            return
        }
        var expectedR: CGFloat = 0, expectedG: CGFloat = 0, expectedB: CGFloat = 0, expectedA: CGFloat = 0
        UIColor.systemBlue.getRed(&expectedR, green: &expectedG, blue: &expectedB, alpha: &expectedA)

        // BGRA8888 premultiplied (normaliseAndRound's output format) — sample the center pixel.
        let bytesPerPixel = 4
        let bytesPerRow = decoded.bytesPerRow
        let midY = decoded.height / 2
        let midX = decoded.width / 2
        let offset = midY * bytesPerRow + midX * bytesPerPixel
        let bytes = [UInt8](data)
        let b = CGFloat(bytes[offset]) / 255
        let g = CGFloat(bytes[offset + 1]) / 255
        let r = CGFloat(bytes[offset + 2]) / 255

        let tolerance: CGFloat = 0.15
        XCTAssertLessThan(abs(r - expectedR), tolerance, "red channel should approximate the source color")
        XCTAssertLessThan(abs(g - expectedG), tolerance, "green channel should approximate the source color")
        XCTAssertLessThan(abs(b - expectedB), tolerance, "blue channel should approximate the source color")
    }
}
#endif

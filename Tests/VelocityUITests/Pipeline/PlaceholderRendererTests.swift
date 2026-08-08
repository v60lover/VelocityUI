// PlaceholderRendererTests.swift

#if canImport(UIKit)
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VelocityUI

final class PlaceholderRendererTests: XCTestCase {

    /// A payload shape thumbnailData/blurHash cannot express — proves .custom is not
    /// limited to the two built-in field types.
    private struct DominantColorPayload: Hashable, Sendable {
        let red: UInt8, green: UInt8, blue: UInt8
    }

    // MARK: - AnyPlaceholderPayload

    func testAnyPlaceholderPayloadUnwrapReturnsOriginalValue() {
        let color = DominantColorPayload(red: 10, green: 20, blue: 30)
        let boxed = AnyPlaceholderPayload(color)
        XCTAssertEqual(boxed.unwrap(as: DominantColorPayload.self), color)
    }

    func testAnyPlaceholderPayloadUnwrapWithMismatchedTypeReturnsNil() {
        let boxed = AnyPlaceholderPayload("a string payload")
        XCTAssertNil(boxed.unwrap(as: DominantColorPayload.self))
    }

    func testAnyPlaceholderPayloadEqualityAndHashingReflectWrappedValue() {
        let a = AnyPlaceholderPayload(DominantColorPayload(red: 1, green: 2, blue: 3))
        let b = AnyPlaceholderPayload(DominantColorPayload(red: 1, green: 2, blue: 3))
        let c = AnyPlaceholderPayload(DominantColorPayload(red: 9, green: 9, blue: 9))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - DefaultPlaceholderRenderer reproduces the free-function decoders exactly

    private let validBlurHash = "L6PZfSi_.AyE_3t7t7R**0o#DgR4"

    func testDefaultPlaceholderRendererThumbnailMatchesFreeFunction() {
        let data = makeTinyJPEGData(width: 8, height: 8)
        let renderer = DefaultPlaceholderRenderer()
        let target = CGSize(width: 100, height: 100)

        let viaRenderer = renderer.render(.thumbnail(data), targetSize: target, cornerRadius: 4)
        let viaFreeFunction = decodeThumbnailPlaceholder(data, targetSize: target, cornerRadius: 4)

        XCTAssertEqual(viaRenderer?.width, viaFreeFunction?.width)
        XCTAssertEqual(viaRenderer?.height, viaFreeFunction?.height)
    }

    func testDefaultPlaceholderRendererBlurHashMatchesFreeFunction() {
        let renderer = DefaultPlaceholderRenderer()
        let target = CGSize(width: 300, height: 300)

        let viaRenderer = renderer.render(.blurHash(validBlurHash), targetSize: target, cornerRadius: 0)
        let viaFreeFunction = decodeBlurHashPlaceholder(validBlurHash, targetSize: target, cornerRadius: 0)

        XCTAssertEqual(viaRenderer?.width, viaFreeFunction?.width)
        XCTAssertEqual(viaRenderer?.height, viaFreeFunction?.height)
    }

    func testDefaultPlaceholderRendererReturnsNilForCustomPayload() {
        let renderer = DefaultPlaceholderRenderer()
        let payload = AnyPlaceholderPayload(DominantColorPayload(red: 5, green: 5, blue: 5))
        XCTAssertNil(renderer.render(.custom(payload), targetSize: CGSize(width: 40, height: 40), cornerRadius: 0),
            "DefaultPlaceholderRenderer must not interpret .custom — falls through to the gray tint")
    }

    // MARK: - Fixtures

    private func makeTinyJPEGData(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
#endif

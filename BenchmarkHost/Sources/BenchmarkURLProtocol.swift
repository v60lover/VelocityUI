// BenchmarkURLProtocol.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// URLProtocol that handles benchmark:// URLs by generating solid-colour PNG data in-process.
///
/// Registered in the URLSessionConfiguration passed to VelocityUI's RenderEnvironment so
/// ImageActor can resolve benchmark:// image URLs without real network traffic.
/// The same palette and dimensions as BenchmarkDataLoader (IdiomaticImageSource) are used
/// so both image modes produce equivalent solid-colour thumbnails.
final class BenchmarkURLProtocol: URLProtocol {
    private static let palette: [(UInt8, UInt8, UInt8)] = [
        (220, 80,  80),  (80, 150, 220), (80, 200, 120),
        (220, 180, 80), (160,  80, 220), (80, 200, 200),
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "benchmark"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard
            let url = request.url,
            url.scheme == "benchmark",
            let id = Int(url.lastPathComponent)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let (r, g, b) = Self.palette[id % Self.palette.count]
        let w = Int(BenchmarkItem.thumbWidth)
        let h = max(1, w * 3 / 2)

        guard let data = Self.makePNG(r: r, g: g, b: b, width: w, height: h) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: "image/png",
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func makePNG(r: UInt8, g: UInt8, b: UInt8, width: Int, height: Int) -> Data? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}

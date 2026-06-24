// IdiomaticImageSource.swift

import CoreGraphics
import Foundation
import ImageIO
import Nuke
import UniformTypeIdentifiers

struct IdiomaticImageSource: ImageSource {
    // Fallback for UIKit runtimes (UICollectionView, Texture) that use imageData(for:).
    // SwiftUI cells in LazyVStack/List use LazyImage directly and bypass this path.
    // Uses data(for:) — raw bytes from BenchmarkDataLoader — so UIKit×Idiomatic incurs
    // the same single decode cycle as UIKit×SamePipeline (no extra encode→decode roundtrip).
    func imageData(for item: BenchmarkItem) async -> Data? {
        guard let (data, _) = try? await ImagePipeline.benchmark.data(for: item.imageURL) else { return nil }
        return data
    }
}

// MARK: - Shared benchmark pipeline

extension ImagePipeline {
    // Handles benchmark:// URLs via BenchmarkDataLoader. Used by IdiomaticImageSource and
    // by LazyImage cells via .pipeline(.benchmark). This is a Nuke-owned type extension
    // on BenchmarkHost app code — the no-singletons rule applies to VelocityUI library types.
    static let benchmark: ImagePipeline = {
        var config = ImagePipeline.Configuration()
        config.dataLoader = BenchmarkDataLoader()
        return ImagePipeline(configuration: config)
    }()
}

// MARK: - Synthetic data loader for benchmark:// URLs

struct BenchmarkDataLoader: DataLoading {
    private static let palette: [(UInt8, UInt8, UInt8)] = [
        (220, 80,  80),  (80, 150, 220), (80, 200, 120),
        (220, 180, 80), (160,  80, 220), (80, 200, 200),
    ]

    func loadData(
        with request: URLRequest,
        didReceiveData: @Sendable @escaping (Data, URLResponse) -> Void,
        completion: @Sendable @escaping (Error?) -> Void
    ) -> any Nuke.Cancellable {
        guard
            let url = request.url,
            url.scheme == "benchmark",
            let id = Int(url.lastPathComponent),
            let data = Self.makePNG(id: id)
        else {
            completion(URLError(.unsupportedURL))
            return NoopCancellable()
        }
        let response = URLResponse(
            url: url, mimeType: "image/png",
            expectedContentLength: data.count, textEncodingName: nil
        )
        didReceiveData(data, response)
        completion(nil)
        return NoopCancellable()
    }

    private static func makePNG(id: Int) -> Data? {
        let (r, g, b) = palette[id % palette.count]
        let w = Int(BenchmarkItem.thumbWidth)
        let h = max(1, w * 3 / 2)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
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

private final class NoopCancellable: Nuke.Cancellable {
    func cancel() {}
}

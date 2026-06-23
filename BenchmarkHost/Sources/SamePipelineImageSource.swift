// SamePipelineImageSource.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor SamePipelineImageSource: ImageSource {
    private let store: [Int: Data]

    init(items: [BenchmarkItem]) {
        let palette: [(UInt8, UInt8, UInt8)] = [
            (220, 80, 80), (80, 150, 220), (80, 200, 120),
            (220, 180, 80), (160, 80, 220), (80, 200, 200)
        ]
        var built: [Int: Data] = [:]
        for item in items {
            let (r, g, b) = palette[item.id % palette.count]
            let w = Int(BenchmarkItem.thumbWidth)
            let h = max(1, Int(item.thumbHeight))
            if let data = Self.makePNG(r: r, g: g, b: b, width: w, height: h) {
                built[item.id] = data
            }
        }
        self.store = built
    }

    func imageData(for item: BenchmarkItem) async -> Data? {
        store[item.id]
    }

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
        guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}

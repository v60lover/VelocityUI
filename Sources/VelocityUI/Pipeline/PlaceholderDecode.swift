// PlaceholderDecode.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO

/// Shared upper bound (px) for both placeholder decode paths. Placeholders are
/// intentionally low-fidelity: `CALayer`'s default `.resize` gravity stretches the backing
/// image to fill the frame at render time, so decoding past this bound on the synchronous
/// MainActor layout path is pure waste.
private let placeholderMaxPixelSize = 32

/// Decodes small (~4KB) JPEG bytes into a decode-guaranteed first-paint placeholder. Pure,
/// nonisolated, synchronous — safe on MainActor. Bounded by `placeholderMaxPixelSize`
/// (aspect-preserving), never upscaled to `targetSize`. Piped through `normaliseAndRound`
/// so it satisfies the same BGRA8888 invariants as the real image path.
nonisolated func decodeThumbnailPlaceholder(
    _ data: Data,
    targetSize: CGSize,
    cornerRadius: CGFloat
) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: placeholderMaxPixelSize,
        kCGImageSourceShouldCache: false,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
    let decodedSize = CGSize(width: thumb.width, height: thumb.height)
    let gridCornerRadius = targetSize.width > 0 ? cornerRadius * (decodedSize.width / targetSize.width) : 0
    return normaliseAndRound(thumb, targetSize: decodedSize, cornerRadius: gridCornerRadius, scale: 1)
}

/// Decodes a BlurHash string into a decode-guaranteed first-paint placeholder — a fixed
/// `placeholderMaxPixelSize`-square grid, normalised/clipped at that grid's own size, not
/// `targetSize`. `cornerRadius` is scaled proportionally into the grid's coordinate space.
nonisolated func decodeBlurHashPlaceholder(
    _ hash: String,
    targetSize: CGSize,
    cornerRadius: CGFloat
) -> CGImage? {
    let gridSize = placeholderMaxPixelSize
    guard let pixels = blurHashDecodePixels(hash, width: gridSize, height: gridSize) else { return nil }
    guard let small = makeCGImage(rgba8: pixels, width: gridSize, height: gridSize) else { return nil }
    let gridCornerRadius = targetSize.width > 0 ? cornerRadius * (CGFloat(gridSize) / targetSize.width) : 0
    return normaliseAndRound(
        small,
        targetSize: CGSize(width: gridSize, height: gridSize),
        cornerRadius: gridCornerRadius,
        scale: 1
    )
}

// MARK: - BlurHash algorithm (public-domain — https://blurha.sh)
//
// Shared base83/color-space primitives live in BlurHashMath.swift, reused by
// PlaceholderEncode.swift's offline tooling path.

/// Decodes a BlurHash string into an RGBA8 (non-premultiplied, alpha always 255) pixel
/// buffer at the given grid size. Returns nil for malformed hashes (wrong length,
/// unrecognised base83 characters, or component-count mismatch) — never crashes.
private nonisolated func blurHashDecodePixels(_ hash: String, width: Int, height: Int) -> [UInt8]? {
    let chars = Array(hash)
    guard chars.count >= 6 else { return nil }

    guard let sizeFlag = base83Decode(chars[0..<1]) else { return nil }
    let numY = (sizeFlag / 9) + 1
    let numX = (sizeFlag % 9) + 1

    let expectedLength = 4 + 2 * numX * numY
    guard chars.count == expectedLength else { return nil }

    guard let quantisedMaxValue = base83Decode(chars[1..<2]) else { return nil }
    let maxValue = Float(quantisedMaxValue + 1) / 166

    var colors = [(Float, Float, Float)](repeating: (0, 0, 0), count: numX * numY)

    guard let dcValue = base83Decode(chars[2..<6]) else { return nil }
    colors[0] = decodeDC(dcValue)

    for i in 1..<(numX * numY) {
        let start = 4 + i * 2
        guard let acValue = base83Decode(chars[start..<(start + 2)]) else { return nil }
        colors[i] = decodeAC(acValue, maxValue: maxValue)
    }

    // Separable cosine basis: cos(pi*x*i/width) depends only on (x,i), not (y,j). Precomputing
    // both tables turns the decode from O(W*H*numX*numY) cos() calls into O(W*numX + H*numY)
    // — measured ~4.5ms vs ~100us at a 300x300pt target without this.
    var cosX = [Float](repeating: 0, count: width * numX)
    for x in 0..<width {
        for i in 0..<numX {
            cosX[x * numX + i] = cos(Float.pi * Float(x) * Float(i) / Float(width))
        }
    }
    var cosY = [Float](repeating: 0, count: height * numY)
    for y in 0..<height {
        for j in 0..<numY {
            cosY[y * numY + j] = cos(Float.pi * Float(y) * Float(j) / Float(height))
        }
    }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let cosYRow = y * numY
        for x in 0..<width {
            let cosXRow = x * numX
            var r: Float = 0, g: Float = 0, b: Float = 0
            for j in 0..<numY {
                let cy = cosY[cosYRow + j]
                let rowBase = j * numX
                for i in 0..<numX {
                    let basis = cosX[cosXRow + i] * cy
                    let color = colors[rowBase + i]
                    r += color.0 * basis
                    g += color.1 * basis
                    b += color.2 * basis
                }
            }
            let idx = (y * width + x) * 4
            pixels[idx]     = linearToSRGB(r)
            pixels[idx + 1] = linearToSRGB(g)
            pixels[idx + 2] = linearToSRGB(b)
            pixels[idx + 3] = 255
        }
    }
    return pixels
}

private nonisolated func makeCGImage(rgba8 pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}
#endif

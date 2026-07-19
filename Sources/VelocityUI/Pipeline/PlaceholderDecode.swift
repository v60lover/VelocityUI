// PlaceholderDecode.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO

/// Shared upper bound (in pixels) for both placeholder decode paths. Placeholders are
/// intentionally low-fidelity: CALayer's default contentsGravity (`.resize`) stretches any
/// backing image to fill the fragment's frame via hardware compositing at render time, so
/// decoding — or upscaling — either placeholder past this bound in software on the
/// synchronous MainActor layout path would be pure waste. A prior revision of the BlurHash
/// path normalised at the CALLER's full targetSize (e.g. 900x900px for 300pt@3x), measuring
/// ~2-6ms on-device via CGContext.draw — the opposite of the sub-millisecond budget this
/// exists for (VelocityUI-1su.3 AC3). Both decode functions are bounded by this constant so
/// neither path can regress the same way independently.
private let placeholderMaxPixelSize = 32

/// Decodes small (~4KB) JPEG bytes into a decode-guaranteed first-paint placeholder.
///
/// Pure, nonisolated, synchronous — safe to call on MainActor. Decodes bounded by
/// `placeholderMaxPixelSize` (aspect-preserving — ImageIO scales the LONGER side down to
/// this bound, or up to it if the source is smaller, never beyond) regardless of the
/// fragment's actual on-screen size; the result is normalised/clipped at that decoded size,
/// not upscaled to `targetSize`. Pipes the decoded thumbnail through `normaliseAndRound` so
/// the result satisfies the same BGRA8888-premultiplied / decode-time-rounding invariants as
/// the real image path (ImageActor) — one CGContext-clip implementation, not two.
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

/// Decodes a BlurHash string into a decode-guaranteed first-paint placeholder.
///
/// Pure, nonisolated, synchronous CPU work (no I/O) — decodes into a fixed
/// `placeholderMaxPixelSize`-square internal grid, then normalises/clips at THAT grid's own
/// size (not `targetSize`). See `placeholderMaxPixelSize`'s docstring for why. `cornerRadius`
/// (given in points against `targetSize`) is scaled proportionally into the small grid's
/// coordinate space.
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

private let blurHashDigits: [Character: Int] = {
    let chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    var d = [Character: Int]()
    for (i, c) in chars.enumerated() { d[c] = i }
    return d
}()

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

    // Separable cosine basis: cos(pi*x*i/width) depends only on (x,i), never (y,j), and vice
    // versa. Precomputing both tables turns the decode from O(W*H*numX*numY) cos() calls into
    // O(W*numX + H*numY) — the per-pixel loop below is then plain float multiply-adds. This is
    // the standard optimization used by reference BlurHash decoders; without it, decode cost is
    // dominated almost entirely by redundant cos() evaluations (measured ~4.5ms vs ~100us at a
    // 300x300pt target on-device — see VelocityUI-1su.3 AC3's <500us p99 budget).
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

private nonisolated func base83Decode(_ chars: ArraySlice<Character>) -> Int? {
    var value = 0
    for c in chars {
        guard let digit = blurHashDigits[c] else { return nil }
        value = value * 83 + digit
    }
    return value
}

private nonisolated func decodeDC(_ value: Int) -> (Float, Float, Float) {
    let r = (value >> 16) & 255
    let g = (value >> 8) & 255
    let b = value & 255
    return (sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b))
}

private nonisolated func decodeAC(_ value: Int, maxValue: Float) -> (Float, Float, Float) {
    let quantR = value / (19 * 19)
    let quantG = (value / 19) % 19
    let quantB = value % 19
    return (
        signPow((Float(quantR) - 9) / 9, 2.0) * maxValue,
        signPow((Float(quantG) - 9) / 9, 2.0) * maxValue,
        signPow((Float(quantB) - 9) / 9, 2.0) * maxValue
    )
}

private nonisolated func signPow(_ value: Float, _ exp: Float) -> Float {
    let sign: Float = value < 0 ? -1 : 1
    return sign * pow(abs(value), exp)
}

private nonisolated func sRGBToLinear(_ value: Int) -> Float {
    let v = Float(value) / 255
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private nonisolated func linearToSRGB(_ value: Float) -> UInt8 {
    let v = max(0, min(1, value))
    let s: Float = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    return UInt8(max(0, min(255, (s * 255).rounded())))
}

private nonisolated func makeCGImage(rgba8 pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}
#endif

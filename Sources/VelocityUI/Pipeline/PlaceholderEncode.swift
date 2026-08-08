// PlaceholderEncode.swift

#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// Encodes a decoded image into a BlurHash string — the producer-side inverse of
/// `decodeBlurHashPlaceholder`.
///
/// Guarded by `canImport(CoreGraphics)` rather than `canImport(UIKit)` (unlike the rest of
/// this pipeline directory): CGImage/CGContext are CoreGraphics, not UIKit, APIs, so this
/// function builds equally on-device (iOS) and as plain macOS command-line tooling — the
/// latter is the point. VelocityUI-1su.3 scoped BlurHash *encoding* out of the package
/// (data-source responsibility); VelocityUI-9x0 brings it in as public API so any consumer
/// (BenchmarkHost's offline dataset generator included) can derive a real per-item BlurHash
/// from its own images instead of hand-picking sample hashes, without VelocityUI itself doing
/// any I/O or owning a producer pipeline.
///
/// Pure, nonisolated, synchronous CPU work — no I/O, no caching, no hidden state. Downsamples
/// the source to a small internal grid before summing basis functions: a BlurHash only ever
/// reconstructs `componentsX * componentsY` frequency components, so summing against a
/// full-resolution source would cost more with no accuracy benefit — mirrors the decode side's
/// bounded-grid rationale (see `placeholderMaxPixelSize`'s docstring in PlaceholderDecode.swift).
///
/// - Parameters:
///   - componentsX: Horizontal frequency component count, clamped to BlurHash's 1...9 range.
///   - componentsY: Vertical frequency component count, clamped to BlurHash's 1...9 range.
/// - Returns: nil only if the source image is zero-sized or CGContext allocation fails (OOM).
public nonisolated func encodeBlurHash(
    _ image: CGImage,
    componentsX: Int = 4,
    componentsY: Int = 3
) -> String? {
    guard image.width > 0, image.height > 0 else { return nil }
    let numX = max(1, min(9, componentsX))
    let numY = max(1, min(9, componentsY))

    let sourceMaxPixelSize = 32
    let aspect = CGFloat(image.width) / CGFloat(image.height)
    let width: Int
    let height: Int
    if aspect >= 1 {
        width = sourceMaxPixelSize
        height = max(1, Int((CGFloat(sourceMaxPixelSize) / aspect).rounded()))
    } else {
        height = sourceMaxPixelSize
        width = max(1, Int((CGFloat(sourceMaxPixelSize) * aspect).rounded()))
    }

    // CGContext allocates and owns its own buffer (data: nil) rather than us handing it an
    // Array's backing pointer — an Array's address is only guaranteed stable for the duration
    // of a single withUnsafeMutableBytes closure, but the context (and the pixel reads below)
    // need that address to stay valid across draw() and the whole basis-function summation
    // that follows. Mirrors ImageNormaliser.swift's normaliseAndRound.
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = ctx.data else { return nil }
    let pixels = data.assumingMemoryBound(to: UInt8.self)

    // Same separable-cosine-table optimisation as the decode path (PlaceholderDecode.swift's
    // blurHashDecodePixels) — avoids O(w*h*numX*numY) cos() evaluations.
    var cosX = [Float](repeating: 0, count: width * numX)
    for x in 0..<width {
        for i in 0..<numX {
            cosX[x * numX + i] = cos(Float.pi * Float(i) * Float(x) / Float(width))
        }
    }
    var cosY = [Float](repeating: 0, count: height * numY)
    for y in 0..<height {
        for j in 0..<numY {
            cosY[y * numY + j] = cos(Float.pi * Float(j) * Float(y) / Float(height))
        }
    }

    var components = [(Float, Float, Float)](repeating: (0, 0, 0), count: numX * numY)
    for y in 0..<height {
        let cosYRow = y * numY
        for x in 0..<width {
            let idx = (y * width + x) * 4
            let r = sRGBToLinear(Int(pixels[idx]))
            let g = sRGBToLinear(Int(pixels[idx + 1]))
            let b = sRGBToLinear(Int(pixels[idx + 2]))
            let cosXRow = x * numX
            for j in 0..<numY {
                let cy = cosY[cosYRow + j]
                let rowBase = j * numX
                for i in 0..<numX {
                    let basis = cosX[cosXRow + i] * cy
                    components[rowBase + i].0 += basis * r
                    components[rowBase + i].1 += basis * g
                    components[rowBase + i].2 += basis * b
                }
            }
        }
    }

    let pixelCount = Float(width * height)
    for i in 0..<components.count {
        let normalisation: Float = i == 0 ? 1 : 2
        let n = normalisation / pixelCount
        components[i] = (components[i].0 * n, components[i].1 * n, components[i].2 * n)
    }

    let dc = components[0]
    let acComponents = components[1...]

    var quantisedMaximumValue = 0
    var maximumValue: Float = 1
    if !acComponents.isEmpty {
        let actualMaximum = acComponents.reduce(Float(0)) { m, c in
            max(m, abs(c.0), abs(c.1), abs(c.2))
        }
        quantisedMaximumValue = max(0, min(82, Int((actualMaximum * 166 - 0.5).rounded(.down))))
        maximumValue = Float(quantisedMaximumValue + 1) / 166
    }

    let sizeFlag = (numX - 1) + (numY - 1) * 9
    var hash = base83Encode(sizeFlag, length: 1)
    hash += base83Encode(quantisedMaximumValue, length: 1)
    hash += base83Encode(encodeDC(dc), length: 4)
    for c in acComponents {
        hash += base83Encode(encodeAC(c, maximumValue: maximumValue), length: 2)
    }
    return hash
}
#endif

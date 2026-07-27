// ImageNormaliser.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Normalises a decoded image to BGRA8888 premultiplied (Core Animation's preferred
/// format) and optionally clips to a rounded rect — all in a single CGContext blit.
///
/// Called off-main on the decode queue. `scale` must be passed from the @MainActor
/// call site; UIScreen.main is not safe to access off main.
///
/// - cornerRadius = 0: format normalisation only (no clip path).
/// - Returns nil only if CGContext allocation fails (OOM).
/// Convert a point dimension to pixels using round-half-away-from-zero.
/// Use this instead of bare `Int(pts * scale)` (which truncates) everywhere a point
/// value is converted to pixels — CacheKey, normaliseAndRound, thumbnail MaxPixelSize —
/// so all three sites agree on the same output size.
public nonisolated func pixelLength(_ points: CGFloat, scale: CGFloat) -> Int {
    Int((points * scale).rounded())
}

public nonisolated func normaliseAndRound(
    _ image: CGImage,
    targetSize: CGSize,
    cornerRadius: CGFloat,
    scale: CGFloat = 1
) -> CGImage? {
    _normaliseAndRound(image, targetSize: targetSize, cornerRadius: cornerRadius, scale: scale, scratchPool: nil)
}

/// Module-internal overload used by `ImageActor` to pool the CGContext scratch buffer.
/// Not `public` — `DecodeScratchBufferPool` is an implementation detail, not part of the
/// library's public surface (Section 7: default internal).
///
/// - Parameter scratchPool: pool of reusable CGContext backing buffers. The draw surface is
///   checked out from the pool instead of freshly malloc'd, and the returned CGImage is
///   copied into independent, pool-unaliased storage before returning — a pooled buffer is
///   reused by the next decode, so the returned image must never reference it directly.
nonisolated func normaliseAndRound(
    _ image: CGImage,
    targetSize: CGSize,
    cornerRadius: CGFloat,
    scale: CGFloat,
    scratchPool: DecodeScratchBufferPool
) -> CGImage? {
    _normaliseAndRound(image, targetSize: targetSize, cornerRadius: cornerRadius, scale: scale, scratchPool: scratchPool)
}

private nonisolated func _normaliseAndRound(
    _ image: CGImage,
    targetSize: CGSize,
    cornerRadius: CGFloat,
    scale: CGFloat,
    scratchPool: DecodeScratchBufferPool?
) -> CGImage? {
    let w = pixelLength(targetSize.width, scale: scale)
    let h = pixelLength(targetSize.height, scale: scale)
    guard w > 0, h > 0 else { return nil }

    // Fast path: thumbnail already matches CA's preferred format and the exact target pixel
    // size, and no clip is needed — skip the scratch CGContext + blit entirely.
    if cornerRadius == 0, image.width == w, image.height == h, isBGRA8888(image) {
        return image
    }

    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                      CGBitmapInfo.byteOrder32Little.rawValue   // BGRA8888
    let bytesPerRow = w * 4
    let rect = CGRect(x: 0, y: 0, width: w, height: h)

    func render(in ctx: CGContext) -> Bool {
        if cornerRadius > 0 {
            let scaledRadius = cornerRadius * scale
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: scaledRadius,
                cornerHeight: scaledRadius,
                transform: nil
            )
            ctx.addPath(path)
            ctx.clip()
        }
        ctx.draw(image, in: rect)
        return true
    }

    guard let scratchPool else {
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,          // auto-stride: Core Animation can use directly
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        _ = render(in: ctx)
        return ctx.makeImage()
    }

    return scratchPool.withBuffer(byteCount: bytesPerRow * h) { buffer in
        // A pooled buffer carries the previous decode's bytes. `data: nil` CGContext gives
        // zero-filled memory, so a clip path leaves untouched corners transparent; a reused
        // buffer must be zeroed the same way or clipped-out pixels leak stale alpha/color.
        memset(buffer, 0, bytesPerRow * h)

        guard let ctx = CGContext(
            data: buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        guard render(in: ctx) else { return nil }

        // Copy out of the pooled buffer — see docstring: the pool reuses this memory for the
        // next decode, so the returned CGImage must own independent storage.
        let copy = Data(bytes: buffer, count: bytesPerRow * h)
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Returns true when a CGImage is already in CA's preferred BGRA8888 format.
public func isBGRA8888(_ image: CGImage) -> Bool {
    let info = image.bitmapInfo
    let alphaInfo = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
    let byteOrder = info.intersection(.byteOrderMask)
    return alphaInfo == .premultipliedFirst && byteOrder == .byteOrder32Little
}
#endif

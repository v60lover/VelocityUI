// ImageNormaliser.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Converts a point dimension to pixels using round-half-away-from-zero. Use instead of
/// bare `Int(pts * scale)` (which truncates) so CacheKey, normaliseAndRound, and thumbnail
/// sizing all agree on the same output size.
public nonisolated func pixelLength(_ points: CGFloat, scale: CGFloat) -> Int {
    Int((points * scale).rounded())
}

/// Normalises a decoded image to BGRA8888 premultiplied (Core Animation's preferred
/// format) and optionally clips to a rounded rect, in one CGContext blit. `scale` must
/// come from the @MainActor call site — `UIScreen.main` isn't safe off-main. Returns nil
/// only on CGContext OOM.
public nonisolated func normaliseAndRound(
    _ image: CGImage,
    targetSize: CGSize,
    cornerRadius: CGFloat,
    scale: CGFloat = 1
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
    let rect = CGRect(x: 0, y: 0, width: w, height: h)

    // Named sRGB, not CGColorSpaceCreateDeviceRGB() — DeviceRGB is untagged, so Core Animation
    // can't recognise it as matching the display's working space and color-matches this layer's
    // contents on every composite (sustained "Color Copied Images", not just first-paint).
    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,          // auto-stride: Core Animation can use directly
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else { return nil }

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
    return ctx.makeImage()
}

/// Returns true when a CGImage is already in CA's preferred BGRA8888 format.
public func isBGRA8888(_ image: CGImage) -> Bool {
    let info = image.bitmapInfo
    let alphaInfo = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
    let byteOrder = info.intersection(.byteOrderMask)
    return alphaInfo == .premultipliedFirst && byteOrder == .byteOrder32Little
}
#endif

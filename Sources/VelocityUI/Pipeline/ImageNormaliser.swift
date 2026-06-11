// ImageNormaliser.swift

#if canImport(UIKit)
import CoreGraphics

/// Normalises a decoded image to BGRA8888 premultiplied (Core Animation's preferred
/// format) and optionally clips to a rounded rect — all in a single CGContext blit.
///
/// Called off-main on the decode queue. `scale` must be passed from the @MainActor
/// call site; UIScreen.main is not safe to access off main.
///
/// - cornerRadius = 0: format normalisation only (no clip path).
/// - Returns nil only if CGContext allocation fails (OOM).
public nonisolated func normaliseAndRound(
    _ image: CGImage,
    targetSize: CGSize,
    cornerRadius: CGFloat,
    scale: CGFloat = 1
) -> CGImage? {
    let w = Int(targetSize.width * scale)
    let h = Int(targetSize.height * scale)
    guard w > 0, h > 0 else { return nil }

    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,          // auto-stride: Core Animation can use directly
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue   // BGRA8888
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: w, height: h)

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

// PlaceholderRenderer.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Produces a fragment's first-paint image before the real image decodes.
///
/// - Runs SYNCHRONOUSLY on MainActor, inline in `RenderCell.applyLayout` (scroll path,
///   never awaits). Budget: p99 < 500us (VelocityUI-1su.3 AC3). Never full-res decode here —
///   pre-shrink at fetch/cache time and hand this a small thumbnail.
/// - Called once per fragment lifetime (gated by `contents == nil`), not once per frame.
/// - Return a small bitmap — `CALayer`'s `.resize` gravity scales it up, so anything bigger
///   than the built-in 32px bound (`PlaceholderDecode.swift`) is wasted work.
/// - Must return BGRA8888-premultiplied, corner-clipped output (use `normaliseAndRound`) —
///   the call site does not re-normalise.
/// - Replaces ALL three payload cases, not just `.custom`. To add a custom case without
///   losing built-in `.thumbnail`/`.blurHash` handling, delegate unhandled cases to
///   `DefaultPlaceholderRenderer().render(payload, targetSize:, cornerRadius:)`.
public protocol PlaceholderRenderer: Sendable {
    /// - Parameters:
    ///   - payload: `.thumbnail`/`.blurHash` for built-in cases, `.custom` for a payload set
    ///     via `AsyncImageNode.placeholder(custom:)`.
    ///   - targetSize: fragment's on-screen point size — decode smaller and let Core Animation
    ///     scale up (see performance contract above).
    ///   - cornerRadius: points, in `targetSize`'s coordinate space.
    /// - Returns: BGRA8888-premultiplied, decode-time-rounded `CGImage`, or `nil` if this
    ///   payload can't produce one — caller falls back to the next tier or a plain gray tint.
    nonisolated func render(
        _ payload: PlaceholderPayload,
        targetSize: CGSize,
        cornerRadius: CGFloat
    ) -> CGImage?
}

/// Reproduces VelocityUI's built-in first-paint behavior: `.thumbnail` via
/// `decodeThumbnailPlaceholder`, `.blurHash` via `decodeBlurHashPlaceholder`, both bounded by
/// `placeholderMaxPixelSize` and piped through `normaliseAndRound`. Wired in automatically by
/// `RenderEnvironment`'s convenience init — inject a different `PlaceholderRenderer` through
/// the designated init to override.
///
/// `.custom` isn't this renderer's job — returns `nil` for it like any payload it can't handle;
/// consumers wanting `.custom` support supply their own renderer.
public struct DefaultPlaceholderRenderer: PlaceholderRenderer {
    public init() {}

    public nonisolated func render(
        _ payload: PlaceholderPayload,
        targetSize: CGSize,
        cornerRadius: CGFloat
    ) -> CGImage? {
        switch payload {
        case .thumbnail(let data):
            return decodeThumbnailPlaceholder(data, targetSize: targetSize, cornerRadius: cornerRadius)
        case .blurHash(let hash):
            return decodeBlurHashPlaceholder(hash, targetSize: targetSize, cornerRadius: cornerRadius)
        case .custom:
            return nil
        }
    }
}
#endif

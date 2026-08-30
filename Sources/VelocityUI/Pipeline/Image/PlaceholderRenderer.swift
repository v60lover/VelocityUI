// PlaceholderRenderer.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Produces a fragment's first-paint image before the real image decodes. Runs
/// synchronously on MainActor, inline in the scroll path — budget p99 < 500us, so never
/// full-res decode here. Must return a small, BGRA8888-premultiplied, corner-clipped
/// `CGImage` (`normaliseAndRound`) — the call site doesn't re-normalise. Handles all three
/// payload cases; to add `.custom` without losing built-ins, delegate to
/// `DefaultPlaceholderRenderer`.
public protocol PlaceholderRenderer: Sendable {
    /// - Parameters:
    ///   - targetSize: fragment's on-screen point size — decode smaller and let Core
    ///     Animation scale up.
    ///   - cornerRadius: points, in `targetSize`'s coordinate space.
    /// - Returns: `nil` if this payload can't produce one — caller falls back to the
    ///   next tier or a plain gray tint.
    nonisolated func render(
        _ payload: PlaceholderPayload,
        targetSize: CGSize,
        cornerRadius: CGFloat
    ) -> CGImage?
}

/// VelocityUI's built-in first-paint renderer: `.thumbnail`/`.blurHash` via the matching
/// decode function, piped through `normaliseAndRound`. Wired in automatically by
/// `RenderEnvironment`'s convenience init. Returns `nil` for `.custom` — consumers wanting
/// that supply their own renderer.
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

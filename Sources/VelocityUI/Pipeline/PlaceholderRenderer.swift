// PlaceholderRenderer.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation

/// A pluggable strategy for producing a fragment's first-paint image before its real
/// image has finished decoding.
///
/// ## Read before implementing — MainActor / frame-budget contract
/// `render(_:targetSize:cornerRadius:)` runs SYNCHRONOUSLY on the MainActor, inline in
/// `RenderCell.applyLayout` — the scroll path, which never awaits. It is NOT called off
/// the main thread. Every microsecond spent here lands directly on the current frame's
/// budget and can drop frames while scrolling.
///
/// It runs once per fragment lifetime, gated by `contents == nil` at bind time — not once
/// per frame — but a slow single call still stutters whichever bind frame it lands on.
///
/// Match the built-in decoders' budget: **p99 < 500us** (VelocityUI-1su.3 AC3). A solid-color
/// fill is effectively free and beats BlurHash; a full-resolution decode inside `render` is
/// an anti-pattern. Do heavy work off-main elsewhere (e.g. at fetch/cache time) and feed this
/// method a small, pre-shrunk thumbnail.
///
/// Return a CHEAP, small bitmap: the result is hardware-composited up to the fragment's real
/// on-screen size via `CALayer`'s default `.resize` content gravity, so producing anything
/// larger than the built-in decoders' bound (32px, see `PlaceholderDecode.swift`) is pure
/// waste — decode/draw small and let Core Animation scale it up.
///
/// The returned image MUST be BGRA8888-premultiplied and rounded/clipped for the given
/// `cornerRadius` — the same invariant every `CALayer.contents` in VelocityUI satisfies. Call
/// the public `normaliseAndRound(_:targetSize:cornerRadius:scale:)` to get this for free, or
/// match its guarantees exactly. The call site does NOT re-normalise the result — an image
/// that skips this contract paints a subtly wrong (wrong color space, unclipped corners)
/// first frame.
///
/// ## Your renderer replaces ALL three cases, not just `.custom`
/// Injecting a `PlaceholderRenderer` through `RenderEnvironment` replaces the renderer for
/// EVERY fragment, including ones still using the built-in `.thumbnail`/`.blurHash` via
/// `.placeholder(thumbnail:)`/`.placeholder(blurHash:)` — `RenderCell` has no separate path
/// for those. A renderer written only to handle `.custom` and returning `nil` for the other
/// two silently disables built-in first paint everywhere else in the app, dropping those
/// fragments straight to the gray tint. To add a custom case while keeping the built-in
/// behavior for everything else, delegate the cases you don't handle to a
/// `DefaultPlaceholderRenderer` instance:
/// ```swift
/// struct MyRenderer: PlaceholderRenderer {
///     let fallback = DefaultPlaceholderRenderer()
///     func render(_ payload: PlaceholderPayload, targetSize: CGSize, cornerRadius: CGFloat) -> CGImage? {
///         if case .custom(let box) = payload { return myDecode(box, targetSize, cornerRadius) }
///         return fallback.render(payload, targetSize: targetSize, cornerRadius: cornerRadius)
///     }
/// }
/// ```
public protocol PlaceholderRenderer: Sendable {
    /// - Parameters:
    ///   - payload: `.thumbnail`/`.blurHash` for the built-in cases; `.custom` for a
    ///     payload set via `AsyncImageNode.placeholder(custom:)`.
    ///   - targetSize: the fragment's on-screen point size. Most renderers should decode far
    ///     smaller than this (see the performance contract above) and let Core Animation
    ///     scale the result up.
    ///   - cornerRadius: points, in `targetSize`'s coordinate space.
    /// - Returns: a BGRA8888-premultiplied, decode-time-rounded `CGImage`, or `nil` if this
    ///   payload can't produce a placeholder — the caller falls back to the next tier
    ///   (another payload) or, if none remain, a plain gray tint.
    nonisolated func render(
        _ payload: PlaceholderPayload,
        targetSize: CGSize,
        cornerRadius: CGFloat
    ) -> CGImage?
}

/// Reproduces VelocityUI's original built-in first-paint behavior: decodes `.thumbnail`
/// via `decodeThumbnailPlaceholder` and `.blurHash` via `decodeBlurHashPlaceholder`, both
/// bounded by the built-in `placeholderMaxPixelSize` and piped through `normaliseAndRound`.
/// `RenderEnvironment`'s convenience init wires this in automatically — inject a different
/// `PlaceholderRenderer` through the designated init to override.
///
/// `.custom` payloads are not this renderer's job — it returns `nil` for them, same as any
/// payload it can't handle; a consumer wanting `.custom` support supplies their own renderer.
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

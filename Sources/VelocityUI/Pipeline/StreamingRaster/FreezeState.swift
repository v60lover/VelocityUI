// FreezeState.swift

import Foundation
import CoreGraphics

// MARK: - FreezeState

/// A block's freeze state: `.hot` (may still grow, never cached) or `.frozen`
/// (measured + rasterized once, immutable after that).
///
/// `@unchecked Sendable` because `.frozen` carries a `CGImage`, which CoreGraphics doesn't
/// mark `Sendable`. Safe here since the image is produced once by `freeze(_:)` and never
/// mutated — an immutable, write-once value is safe to share across isolation domains.
public enum FreezeState: @unchecked Sendable {
    case hot
    case frozen(size: CGSize, bitmap: CGImage)
}

// MARK: - Injected measure/rasterize collaborators

/// Signature of `TextMeasurementContext.measure(_:width:)`. Injected instead of taking the
/// concrete UIKit-gated type directly, so `freeze(_:)` stays pure/nonisolated and testable
/// without linking UIKit.
public typealias TextMeasure = (TextDescriptor, CGFloat) -> CGSize

/// Signature of `rasterizeText(_:layoutWidth:outputSize:scale:)`. Injected for the same reason
/// as `TextMeasure`. Params: descriptor, layoutWidth (the width text was measured at), output
/// size (tight canvas), scale.
public typealias TextRasterize = (TextDescriptor, CGFloat, CGSize, CGFloat) -> CGImage?

// MARK: - freeze

/// Measures + rasterizes `block`'s text content once, caching the result under `block.key`.
/// If already `.frozen`, returns it as-is with no re-measure/rasterize.
///
/// Precondition: `block.fragment.content` must be `.text`. Image/geometry blocks aren't
/// frozen here — their reuse goes through `ImageActor`'s decode cache instead.
///
/// - Returns: `.frozen` on success; `.hot` (uncached) if rasterization fails, so a later
///   call can retry instead of caching a bad empty result.
@discardableResult
public nonisolated func freeze(
    _ block: Block,
    scale: CGFloat,
    cache: inout [BlockKey: FreezeState],
    measure: TextMeasure,
    rasterize: TextRasterize
) -> FreezeState {
    if let existing = cache[block.key], case .frozen = existing {
        return existing
    }
    guard case .text(let descriptor) = block.fragment.content else {
        preconditionFailure(
            "freeze(_:) only applies to text blocks — image/geometry blocks are not measured/"
            + "rasterized here; see the doc comment for where their reuse lives instead."
        )
    }

    let size = measure(descriptor, block.width)
    // Lay out at block.width (the width the height was measured at) but draw into the tight
    // `size` canvas — keeps rasterized wrap identical to measured wrap, so height never
    // undershoots and nothing clips. See rasterizeText's layoutWidth/outputSize split.
    guard let bitmap = rasterize(descriptor, block.width, size, scale) else {
        return .hot
    }

    let state = FreezeState.frozen(size: size, bitmap: bitmap)
    cache[block.key] = state
    return state
}

// FreezeState.swift

import Foundation
import CoreGraphics

// MARK: - FreezeState

/// A block's freeze state: `.hot` (last block, may still grow, never cached) or `.frozen`
/// (measured + rasterized exactly once, immutable from then on — VelocityUI-6qd LB4).
///
/// `@unchecked Sendable`: `.frozen` carries a `CGImage`, which CoreGraphics does not mark
/// `Sendable` in this SDK (see `ImageActor.DecodeResult` for the identical pattern). Safety
/// holds because a frozen `CGImage` is produced exactly once by `freeze(_:)` and never mutated
/// afterward — an immutable, single-produce/multi-read value is safe to share across isolation
/// domains.
public enum FreezeState: @unchecked Sendable {
    case hot
    case frozen(size: CGSize, bitmap: CGImage)
}

// MARK: - Injected measure/rasterize collaborators

/// Signature of `TextMeasurementContext.measure(_:width:)`. Injected rather than depending on
/// the concrete (UIKit-gated) type, so `freeze(_:)` stays pure/nonisolated and testable without
/// linking UIKit (CLAUDE.md: nonisolated helpers take their pool/context as an argument, never
/// a global lookup).
public typealias TextMeasure = (TextDescriptor, CGFloat) -> CGSize

/// Signature of `rasterizeText(_:size:scale:)`. Injected for the same reason as `TextMeasure`.
public typealias TextRasterize = (TextDescriptor, CGSize, CGFloat) -> CGImage?

// MARK: - freeze

/// Measures + rasterizes `block`'s text content exactly once and caches the result under
/// `block.key` in `cache`. If `cache[block.key]` is already `.frozen`, returns it verbatim —
/// zero calls to `measure`/`rasterize` (VelocityUI-6qd LB4: a frozen block is never re-touched).
///
/// Precondition: `block.fragment.content` must be `.text`. Image/geometry blocks are never
/// frozen here — their reuse lives in the content-addressed image decode cache (`ImageActor`,
/// keyed by URL), not in block-level measure/rasterize caching (VelocityUI-qc7's explicit
/// corollary: diff only earns its keep on content overlap, which images never have).
///
/// - Returns: `.frozen(size:bitmap:)` on success. `.hot` (uncached) if rasterization fails on a
///   degenerate size, so a later call can retry instead of caching a bogus empty result.
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
    guard let bitmap = rasterize(descriptor, size, scale) else {
        return .hot
    }

    let state = FreezeState.frozen(size: size, bitmap: bitmap)
    cache[block.key] = state
    return state
}

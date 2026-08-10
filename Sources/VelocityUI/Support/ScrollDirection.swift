// ScrollDirection.swift

#if canImport(UIKit)

/// Direction of travel along the feed's scroll axis, derived from real `contentOffset` deltas.
///
/// Determines which side of `leadingIndex` prefetch items are classified `.ahead` vs `.behind`
/// in `RenderPipeline.onIndexBoundary`. Defaults to `.down` — the direction VelocityUI-he0
/// originally assumed — so callers that don't observe scroll direction see unchanged behavior.
public enum ScrollDirection: Sendable, Equatable {
    /// Content is moving toward higher indices (bottom of the feed).
    case down
    /// Content is moving toward lower indices (top of the feed).
    case up
}

#endif

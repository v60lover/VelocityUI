// GridLayout.swift

import CoreGraphics

/// Declares the layout strategy for a feed or grid.
/// Phase 1: only .vertical is implemented. .custom enables future extension without
/// breaking the public shape — preferred over shipping dead Phase 5 stubs (.masonry etc.)
/// that would never fatalError cleanly.
public enum GridLayout: Sendable {
    case vertical(spacing: CGFloat = 8)
    /// Caller-supplied strategy; must be Sendable (actor-safe, value type preferred).
    case custom(any LayoutProvider)
}

extension GridLayout {
    /// Returns the layout provider that implements this strategy.
    /// Value-semantically stable: the provider is fully determined by the enum case's associated value,
    /// so callers may rebuild it freely or cache it — both produce equivalent behaviour.
    /// The `.vertical` case allocates one CGFloat-sized struct per access; callers that invoke this
    /// repeatedly in a tight loop should cache the result.
    public var provider: any LayoutProvider {
        switch self {
        case .vertical(let spacing): VerticalLayoutProvider(spacing: spacing)
        case .custom(let p):         p
        }
    }
}

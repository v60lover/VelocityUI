// GridLayout.swift

import CoreGraphics

/// Declares the layout strategy for a feed or grid.
/// .custom enables future extension without breaking the public shape — preferred over
/// shipping dead Phase 5 stubs (.masonry etc.) that would never fatalError cleanly.
public enum GridLayout: Sendable {
    case vertical(spacing: CGFloat = 8)
    /// Classic row-major grid: `columns` fixed-width columns, ragged final row, each row
    /// top-aligned to its tallest cell. Cells are measured at column width, not linearly
    /// scaled from the full container width — see `GridLayoutProvider.measureWidth(availableWidth:)`.
    case grid(columns: Int, spacing: CGFloat = 8)
    /// Caller-supplied strategy; must be Sendable (actor-safe, value type preferred).
    case custom(any LayoutProvider)
}

extension GridLayout {
    /// Returns the layout provider that implements this strategy.
    /// Value-semantically stable: the provider is fully determined by the enum case's associated value,
    /// so callers may rebuild it freely or cache it — both produce equivalent behaviour.
    /// The `.vertical`/`.grid` cases allocate one small struct per access; callers that invoke this
    /// repeatedly in a tight loop should cache the result.
    public var provider: any LayoutProvider {
        switch self {
        case .vertical(let spacing):
            return VerticalLayoutProvider(spacing: spacing)
        case .grid(let columns, let spacing):
            // GridLayoutProvider.init silently clamps columns >= 1 / spacing >= 0 — this assert
            // exists only to catch a caller bug loudly in debug builds, not as the real guard.
            #if DEBUG
            assert(columns >= 1, "GridLayout.grid: columns must be >= 1, got \(columns)")
            assert(spacing >= 0, "GridLayout.grid: spacing must be >= 0, got \(spacing)")
            #endif
            return GridLayoutProvider(columns: columns, spacing: spacing)
        case .custom(let p):
            return p
        }
    }
}

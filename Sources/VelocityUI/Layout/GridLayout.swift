// GridLayout.swift

import CoreGraphics

/// Declares the layout strategy for a feed or grid. `.custom` allows caller-supplied strategies
/// without expanding this enum's public cases.
public enum GridLayout: Sendable {
    case vertical(spacing: CGFloat = 8)
    /// Row-major grid: `columns` fixed-width columns, ragged final row, top-aligned. Cells measure
    /// at column width, not the full container width.
    case grid(columns: Int, spacing: CGFloat = 8)
    /// Caller-supplied strategy; must be Sendable (actor-safe, value type preferred).
    case custom(any LayoutProvider)
}

extension GridLayout {
    /// Returns the layout provider for this strategy. `.vertical`/`.grid` allocate a new struct each
    /// access — cache the result if calling in a tight loop.
    public var provider: any LayoutProvider {
        switch self {
        case .vertical(let spacing):
            return VerticalLayoutProvider(spacing: spacing)
        case .grid(let columns, let spacing):
            // Debug-only guard; GridLayoutProvider.init silently clamps out-of-range values anyway.
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

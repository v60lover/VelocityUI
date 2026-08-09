// DecodePriority.swift

#if canImport(UIKit)

/// Admission tier for `ImageActor`'s bounded decode gate (`AsyncSemaphore`).
///
/// Lower `rawValue` is admitted into a free decode slot first. Tiers only affect
/// ADMISSION ORDER — nothing is ever cancelled or preempted once a decode has
/// acquired a slot. Within a tier, waiters are served FIFO.
public enum DecodePriority: Int, Sendable, Comparable, CaseIterable {
    /// On-screen `ImageActor.image()` fetches. Admitted before any prefetch.
    case visible = 0
    /// Prefetch for items at or after the leading visible index — coming into view next.
    case ahead = 1
    /// Prefetch for items before the leading visible index — already scrolled past.
    case behind = 2

    public static func < (lhs: DecodePriority, rhs: DecodePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

#endif

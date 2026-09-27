// StreamingDeliveryCoordinator.swift

#if canImport(UIKit)
import Foundation

/// Owns per-feed streaming document revisions and, once dependent beads land, the measurement
/// and raster scheduling `FeedScrollView` currently performs inline (VelocityUI-ln1g.5). This
/// bead only wires the type through `RenderEnvironment` and records revisions -- no scheduling
/// work has moved yet.
///
/// `@MainActor final class`, not `Sendable` -- same shape as `HotTableRasterizerStore` and
/// `HotBlockRasterizerStore`: touched only from `FeedScrollView`'s synchronous MainActor path.
@MainActor
public final class StreamingDeliveryCoordinator {
    private var revisions: [AnyHashable: UInt64] = [:]

    public init() {}

    /// Records the latest known document revision for an item. Pure observation for now --
    /// dependent beads will use this to decide what to schedule and what to reject as stale.
    public func noteDocumentRevision<ID: Hashable & Sendable>(itemID: ID, revision: UInt64) {
        revisions[AnyHashable(itemID)] = revision
    }
}
#endif

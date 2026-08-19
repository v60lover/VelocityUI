// ReuseDecision.swift

/// Identity-based reuse decision for a slot receiving new content (VelocityUI-qc7): compare the
/// new item's stable id to whatever id is currently bound in that slot.
///
/// - `.inPlace`: SAME identity as currently bound — reconfigure the existing shell and run a
///   per-block diff (`diff(previous:new:)`) to skip frozen blocks, re-rasterize only the hot tail
///   (Telegram's `asyncLayout(previousNode)` path).
/// - `.pool`: different (or no previous) identity — no overlap to diff, so return the old shell
///   to a typed reuse pool and bind fresh (pool itself is VelocityUI-qc7 phase B, not built here).
///
/// A pure scroll/image feed NEVER produces `.inPlace` — every visible item has a different
/// identity than whatever occupied that slot before. `.inPlace` only fires when the SAME item id
/// streams an update into an already-bound slot (e.g. a chat message growing token-by-token).
public enum ReuseDecision: Sendable, Equatable {
    case inPlace
    case pool
}

/// Pure identity comparison — the ONE decision rule for choosing in-place reconfigure vs pool
/// recycling for a slot receiving `newID`. See `ReuseDecision` for what each case means.
///
/// Generic over any `Hashable` id (not `AnyHashable`-specific) so it composes with
/// `NodeTable.itemID` or any concrete id type a caller already has.
///
/// - Parameters:
///   - oldID: identity currently bound in the slot, or `nil` if empty.
///   - newID: identity that needs to be bound.
public nonisolated func reuseDecision<ItemID: Hashable>(oldID: ItemID?, newID: ItemID) -> ReuseDecision {
    if let oldID, oldID == newID {
        return .inPlace
    }
    return .pool
}

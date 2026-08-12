// ReuseDecision.swift

/// The identity-based reuse decision for a slot receiving new content — the one decision rule
/// from VelocityUI-qc7's design: compare the new item's stable id to whatever id is currently
/// bound in that slot.
///
/// - `.inPlace`: the new item has the SAME stable identity as what is currently bound —
///   reconfigure the existing shell and run a per-block diff (`diff(previous:new:)`) to skip
///   frozen blocks and only re-measure/re-rasterize the hot tail. Telegram's
///   `asyncLayout(previousNode)` path.
/// - `.pool`: different (or no previous) identity — old and new content have no overlap to
///   diff, so return the old shell to a typed reuse pool and bind fresh. (The typed pool itself
///   is VelocityUI-qc7 phase B — not built here.)
///
/// A pure scroll feed or an image feed NEVER produces `.inPlace`: every new visible item has a
/// different identity than whatever previously occupied that slot, so `reuseDecision` always
/// returns `.pool` for them. `.inPlace` only fires when the SAME item id streams an update into
/// an already-bound slot (e.g. a chat message growing token-by-token).
public enum ReuseDecision: Sendable, Equatable {
    case inPlace
    case pool
}

/// Pure identity comparison — the ONE decision rule for choosing in-place reconfigure vs pool
/// recycling for a slot receiving `newID`. See `ReuseDecision` for what each case means.
///
/// Generic over any `Hashable` id (not `AnyHashable`-specific) so it composes directly with
/// `NodeTable.itemID` (`AnyHashable`) or any concrete id type a caller already has in hand.
///
/// - Parameters:
///   - oldID: the identity currently bound in the slot, or `nil` if the slot is empty.
///   - newID: the identity that needs to be bound.
public nonisolated func reuseDecision<ItemID: Hashable>(oldID: ItemID?, newID: ItemID) -> ReuseDecision {
    if let oldID, oldID == newID {
        return .inPlace
    }
    return .pool
}

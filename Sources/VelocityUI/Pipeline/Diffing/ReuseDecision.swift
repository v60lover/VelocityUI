// ReuseDecision.swift

/// Whether a slot receiving `newID` should reconfigure in place or pull from the reuse pool.
/// `.inPlace` only fires when the same item id streams an update into an already-bound slot
/// (e.g. a chat message growing token-by-token) — a plain scroll feed never produces it.
public enum ReuseDecision: Sendable, Equatable {
    case inPlace
    case pool
}

/// The one rule for choosing in-place reconfigure vs pool recycling: same id as before → `.inPlace`, else `.pool`.
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

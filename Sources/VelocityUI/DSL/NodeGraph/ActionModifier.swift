// ActionModifier.swift

import Foundation

/// Opaque per-node action identity for a later hit-test/gesture pass (VelocityUI-ye8a.2+).
/// Carries no closure — only a Sendable+Hashable id crosses the Layer 1/2 boundary. Mirrors
/// `BlockID`'s AnyHashable-box shape exactly.
public struct ActionID: Hashable, Sendable {
    nonisolated(unsafe) public let rawValue: AnyHashable

    public init<ID: Hashable & Sendable>(_ rawValue: ID) {
        self.rawValue = AnyHashable(rawValue)
    }
}

/// Transparent Layer-1 wrapper produced by `.action(_:)` and consumed by `flatten()`.
public struct ActionModifierNode: RenderNode {
    public let content: any RenderNode
    public let actionID: ActionID

    public var layoutHash: Int { content.layoutHash }
    public var appearanceHash: Int { content.appearanceHash }
}

extension RenderNode {
    /// Tags this node with an opaque action identity, carried through `NodeTable`/`Fragment`
    /// to a later hit-test pass. Excluded from `layoutHash`/`appearanceHash` — changing only
    /// the id triggers no relayout or repaint.
    ///
    /// Known limitation (VelocityUI-m5tl.2): `LayoutCache`'s key is `(layoutHash, width)`, which
    /// doesn't include this id. Two items whose content produces the same `layoutHash` but
    /// different action ids can collide on the same cache entry and briefly resolve taps to the
    /// wrong id until the item's own re-measure overwrites the cache. Keep ids stable for a given
    /// node identity rather than relying on this for per-item uniqueness of otherwise-identical content.
    public func action<ID: Hashable & Sendable>(_ id: ID) -> ActionModifierNode {
        ActionModifierNode(content: self, actionID: ActionID(id))
    }
}

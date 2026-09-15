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
    public func action<ID: Hashable & Sendable>(_ id: ID) -> ActionModifierNode {
        ActionModifierNode(content: self, actionID: ActionID(id))
    }
}

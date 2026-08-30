import Foundation

/// Transparent Layer-1 wrapper produced by `.renderID(_:)` and consumed by `flatten()`.
public struct RenderIDModifierNode: RenderNode {
    public let content: any RenderNode
    public let blockID: BlockID

    public var layoutHash: Int { content.layoutHash }
    public var appearanceHash: Int { content.appearanceHash }
}

extension RenderNode {
    /// Assigns a stable block identity without changing layout or appearance hashes.
    public func renderID<ID: Hashable & Sendable>(_ id: ID) -> RenderIDModifierNode {
        RenderIDModifierNode(content: self, blockID: BlockID(id))
    }
}

// RenderNode.swift

import Foundation

/// Base protocol for all nodes in the developer DSL.
/// Implementations are value types (structs) and must be Sendable.
/// layoutHash covers all properties that affect geometry.
/// appearanceHash covers all properties that affect only visual style.
public protocol RenderNode: Sendable {
    var layoutHash: Int { get }
    var appearanceHash: Int { get }
}

/// Entry point for a developer-defined cell.
/// renderBody is evaluated on @MainActor and immediately flattened to
/// a NodeTable before crossing to Layer 2. No existential boxes escape.
public protocol RenderView: Sendable {
    associatedtype Body: RenderNode
    @MainActor var renderBody: Body { get }
}

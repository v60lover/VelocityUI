// RenderNodeBuilder.swift

import Foundation

// MARK: - Result builder

/// Transforms DSL closure bodies into [any RenderNode] arrays.
/// Used as a parameter attribute on container node initializers.
/// All erasure to [any RenderNode] is Layer-1-internal; flatten() at the
/// Layer 1/2 boundary unwraps children before they cross to NodeTable.
@resultBuilder
public enum RenderNodeBuilder {
    public static func buildExpression<N: RenderNode>(_ expression: N) -> [any RenderNode] {
        [expression]
    }

    public static func buildBlock(_ components: [any RenderNode]...) -> [any RenderNode] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [any RenderNode]?) -> [any RenderNode] {
        component ?? []
    }

    // Both branches return the same type ([any RenderNode]), so if/else compiles
    // without needing _ConditionalNode. This is the Layer-1-internal erasure noted in
    // the bead polish findings — existentials never escape past flatten().
    public static func buildEither(first: [any RenderNode]) -> [any RenderNode] { first }
    public static func buildEither(second: [any RenderNode]) -> [any RenderNode] { second }

    public static func buildArray(_ components: [[any RenderNode]]) -> [any RenderNode] {
        components.flatMap { $0 }
    }
}

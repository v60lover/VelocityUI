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

    /// Lets an already-built `[any RenderNode]` value — e.g. `IncrementalMarkdownParser.renderNodes`
    /// — be spliced directly into a container's builder closure. The generic overload above only
    /// matches a single `RenderNode`-conforming value; `Array` doesn't conform to `RenderNode`.
    public static func buildExpression(_ expression: [any RenderNode]) -> [any RenderNode] {
        expression
    }

    public static func buildBlock(_ components: [any RenderNode]...) -> [any RenderNode] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [any RenderNode]?) -> [any RenderNode] {
        component ?? []
    }

    // Both branches return the same type ([any RenderNode]), so if/else compiles without needing
    // _ConditionalNode — existentials never escape past flatten().
    public static func buildEither(first: [any RenderNode]) -> [any RenderNode] { first }
    public static func buildEither(second: [any RenderNode]) -> [any RenderNode] { second }

    public static func buildArray(_ components: [[any RenderNode]]) -> [any RenderNode] {
        components.flatMap { $0 }
    }
}

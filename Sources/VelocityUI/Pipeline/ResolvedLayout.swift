// ResolvedLayout.swift

import Foundation
import CoreGraphics

/// The output of measureNode for a single node.
/// Sendable value type — crosses actor boundaries freely.
public struct ResolvedLayout: Sendable {
    public let totalFrame: CGRect
    public let children: [ResolvedLayout]
    /// Index of the corresponding node in NodeTable.nodes.
    /// -1 for manually constructed layouts (e.g. placeholder, test fixtures).
    public let nodeIndex: Int

    public init(totalFrame: CGRect, children: [ResolvedLayout] = [], nodeIndex: Int = -1) {
        self.totalFrame = totalFrame
        self.children = children
        self.nodeIndex = nodeIndex
    }

    // Offsets totalFrame only — children remain in this node's local coordinate space.
    // collectFragments depends on this: it reconstructs absolute positions by passing
    // each container's absolute origin down as parentOrigin. If children were also shifted
    // here, absolute frames would be double-counted at every nesting level.
    public func offsetBy(dy: CGFloat) -> ResolvedLayout {
        ResolvedLayout(
            totalFrame: totalFrame.offsetBy(dx: 0, dy: dy),
            children: children,
            nodeIndex: nodeIndex
        )
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> ResolvedLayout {
        ResolvedLayout(
            totalFrame: totalFrame.offsetBy(dx: dx, dy: dy),
            children: children,
            nodeIndex: nodeIndex
        )
    }

    public static let placeholder = ResolvedLayout(totalFrame: .zero)
}

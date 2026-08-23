// ResolvedLayout.swift

import Foundation
import CoreGraphics

/// The output of measureNode for a single node.
/// Sendable value type — crosses actor boundaries freely.
public struct ResolvedLayout: Sendable {
    public let totalFrame: CGRect
    /// Leaf-only content box within `totalFrame`, set by `.frame()` framing when the slot
    /// is larger/smaller than intrinsic content. `nil` in the unframed case, and always
    /// nil for containers, which shift `children` instead.
    public let contentFrame: CGRect?
    public let children: [ResolvedLayout]
    /// Index of the corresponding node in NodeTable.nodes.
    /// -1 for manually constructed layouts (e.g. placeholder, test fixtures).
    public let nodeIndex: Int

    public init(totalFrame: CGRect, contentFrame: CGRect? = nil, children: [ResolvedLayout] = [], nodeIndex: Int = -1) {
        self.totalFrame = totalFrame
        self.contentFrame = contentFrame
        self.children = children
        self.nodeIndex = nodeIndex
    }

    // Offsets totalFrame/contentFrame only — children stay in local coordinate space.
    // collectFragments reconstructs absolute positions from parentOrigin; shifting
    // children here too would double-count offsets at every nesting level.
    public func offsetBy(dy: CGFloat) -> ResolvedLayout {
        ResolvedLayout(
            totalFrame: totalFrame.offsetBy(dx: 0, dy: dy),
            contentFrame: contentFrame?.offsetBy(dx: 0, dy: dy),
            children: children,
            nodeIndex: nodeIndex
        )
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> ResolvedLayout {
        ResolvedLayout(
            totalFrame: totalFrame.offsetBy(dx: dx, dy: dy),
            contentFrame: contentFrame?.offsetBy(dx: dx, dy: dy),
            children: children,
            nodeIndex: nodeIndex
        )
    }

    public static let placeholder = ResolvedLayout(totalFrame: .zero)
}

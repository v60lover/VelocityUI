// ResolvedLayout.swift

import Foundation
import CoreGraphics

/// The output of measureNode for a single node.
/// Sendable value type — crosses actor boundaries freely.
public struct ResolvedLayout: Sendable {
    public let totalFrame: CGRect
    /// The LEAF-only content box within `totalFrame`, set by `LayoutEngine.applyFrame`
    /// (VelocityUI-rsg) when a `.frame()` slot is larger or smaller than the node's
    /// intrinsic content — `nil` in the common unframed case (and always nil for
    /// container nodes, which express framing by shifting `children` instead; see
    /// `applyFrame`'s doc comment). `extractFragments` draws leaves at
    /// `contentFrame ?? totalFrame`, so a `nil` here is byte-identical to today's behavior.
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

    // Offsets totalFrame (and contentFrame, when present) only — children remain in this
    // node's local coordinate space. collectFragments depends on this: it reconstructs
    // absolute positions by passing each container's absolute origin down as parentOrigin.
    // If children were also shifted here, absolute frames would be double-counted at every
    // nesting level.
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

// ResolvedLayout.swift

import Foundation
import CoreGraphics

/// The output of measureNode for a single node.
/// Sendable value type — crosses actor boundaries freely.
public struct ResolvedLayout: Sendable {
    public let totalFrame: CGRect
    public let children: [ResolvedLayout]

    public init(totalFrame: CGRect, children: [ResolvedLayout] = []) {
        self.totalFrame = totalFrame
        self.children = children
    }

    public func offsetBy(dy: CGFloat) -> ResolvedLayout {
        ResolvedLayout(
            totalFrame: totalFrame.offsetBy(dx: 0, dy: dy),
            children: children
        )
    }

    public static let placeholder = ResolvedLayout(totalFrame: .zero)
}

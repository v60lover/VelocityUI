// VEdgeInsets.swift

import CoreGraphics

/// Per-edge padding, mirroring SwiftUI's `EdgeInsets`. Used by `TextBackgroundChrome.padding`
/// to inset a text row's content within its rounded background.
public struct VEdgeInsets: Sendable, Hashable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(all: CGFloat) {
        self.init(top: all, leading: all, bottom: all, trailing: all)
    }

    public init(horizontal: CGFloat, vertical: CGFloat) {
        self.init(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    public static let zero = VEdgeInsets()
}

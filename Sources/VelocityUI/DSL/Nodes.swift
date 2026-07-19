// Nodes.swift

import Foundation
import CoreGraphics

// MARK: - Alignment types

public enum VHorizontalAlignment: Int, Sendable, Hashable {
    case leading = 0, center = 1, trailing = 2
}

public enum VVerticalAlignment: Int, Sendable, Hashable {
    case top = 0, center = 1, bottom = 2, firstTextBaseline = 3, lastTextBaseline = 4
}

public enum VAlignment: Int, Sendable, Hashable {
    case topLeading = 0, top = 1, topTrailing = 2
    case leading = 3, center = 4, trailing = 5
    case bottomLeading = 6, bottom = 7, bottomTrailing = 8
}

// MARK: - Supporting types

public enum VContentMode: Int, Sendable, Hashable {
    case fit = 0
    case fill = 1
}

public enum VLineBreakMode: Int, Sendable, Hashable {
    case byWordWrapping = 0
    case byCharWrapping = 1
    case byClipping = 2
    case byTruncatingHead = 3
    case byTruncatingTail = 4
    case byTruncatingMiddle = 5
}

// MARK: - VFontDescriptor convenience

extension VFontDescriptor {
    /// Regular-weight body text (17pt, weight 0 = UIFont.Weight.regular).
    public static let body = VFontDescriptor(size: 17, weight: 0)
}

// MARK: - VColorDescriptor convenience

extension VColorDescriptor {
    /// Opaque black (RGBA 0,0,0,1).
    public static let primary = VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
    /// Opaque white.
    public static let white = VColorDescriptor(red: 1, green: 1, blue: 1, alpha: 1)
}

// MARK: - VStackNode

public struct VStackNode: RenderNode {
    public let alignment: VHorizontalAlignment
    public let spacing: CGFloat
    /// Layer-1-internal. Consumed by flatten() at the Layer 1/2 boundary.
    /// Production code must not cache or inspect this array past flatten().
    public let children: [any RenderNode]

    public init(
        alignment: VHorizontalAlignment = .center,
        spacing: CGFloat = 0,
        @RenderNodeBuilder _ content: () -> [any RenderNode]
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.children = content()
    }

    public var layoutHash: Int {
        var h = Hasher()
        h.combine(alignment)
        h.combine(spacing)
        for child in children { h.combine(child.layoutHash) }
        return h.finalize()
    }

    public var appearanceHash: Int {
        var h = Hasher()
        for child in children { h.combine(child.appearanceHash) }
        return h.finalize()
    }
}

// MARK: - HStackNode

public struct HStackNode: RenderNode {
    public let alignment: VVerticalAlignment
    public let spacing: CGFloat
    /// Layer-1-internal. Consumed by flatten() at the Layer 1/2 boundary.
    /// Production code must not cache or inspect this array past flatten().
    public let children: [any RenderNode]

    public init(
        alignment: VVerticalAlignment = .center,
        spacing: CGFloat = 0,
        @RenderNodeBuilder _ content: () -> [any RenderNode]
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.children = content()
    }

    public var layoutHash: Int {
        var h = Hasher()
        h.combine(alignment)
        h.combine(spacing)
        for child in children { h.combine(child.layoutHash) }
        return h.finalize()
    }

    public var appearanceHash: Int {
        var h = Hasher()
        for child in children { h.combine(child.appearanceHash) }
        return h.finalize()
    }
}

// MARK: - ZStackNode

public struct ZStackNode: RenderNode {
    public let alignment: VAlignment
    /// Layer-1-internal. Consumed by flatten() at the Layer 1/2 boundary.
    /// Production code must not cache or inspect this array past flatten().
    public let children: [any RenderNode]

    public init(
        alignment: VAlignment = .center,
        @RenderNodeBuilder _ content: () -> [any RenderNode]
    ) {
        self.alignment = alignment
        self.children = content()
    }

    public var layoutHash: Int {
        var h = Hasher()
        h.combine(alignment)
        for child in children { h.combine(child.layoutHash) }
        return h.finalize()
    }

    public var appearanceHash: Int {
        var h = Hasher()
        for child in children { h.combine(child.appearanceHash) }
        return h.finalize()
    }
}

// MARK: - SpacerNode

public struct SpacerNode: RenderNode {
    /// Minimum length in the stack's primary axis.
    /// flatten() maps nil → 0.0 when writing NodeKind.spacer(CGFloat).
    /// A nil spacer fills remaining space in SwiftUI semantics; here it collapses to zero
    /// height until the layout engine grows to support flexible spacers. See bead b52.
    public let minLength: CGFloat?

    public init(minLength: CGFloat? = nil) {
        self.minLength = minLength
    }

    public var layoutHash: Int {
        var h = Hasher()
        h.combine(minLength)
        return h.finalize()
    }

    public var appearanceHash: Int { 0 }
}

// MARK: - TextNode

public struct TextNode: RenderNode {
    public let content: String
    public let font: VFontDescriptor
    public let color: VColorDescriptor
    public let lineLimit: Int?
    public let lineBreakMode: VLineBreakMode

    public init(
        _ content: String,
        font: VFontDescriptor = .body,
        color: VColorDescriptor = .primary,
        lineLimit: Int? = nil,
        lineBreakMode: VLineBreakMode = .byWordWrapping
    ) {
        self.content = content
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.lineBreakMode = lineBreakMode
    }

    /// layoutHash covers all properties that affect geometry: content, font metrics, line limit, line break mode.
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(content)
        h.combine(font.size)
        h.combine(font.weight)
        h.combine(lineLimit)
        h.combine(lineBreakMode)
        return h.finalize()
    }

    /// appearanceHash covers color only — changing color never affects layout.
    public var appearanceHash: Int {
        var h = Hasher()
        h.combine(color)
        return h.finalize()
    }

    public func font(_ newFont: VFontDescriptor) -> TextNode {
        TextNode(content, font: newFont, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode)
    }

    public func lineLimit(_ limit: Int) -> TextNode {
        TextNode(content, font: font, color: color, lineLimit: limit, lineBreakMode: lineBreakMode)
    }
}

// MARK: - AsyncImageNode

public struct AsyncImageNode: RenderNode {
    public let url: URL?
    public let aspectRatio: CGFloat?
    public let contentMode: VContentMode
    /// Rounding applied at decode time via CGContext clip — never set on CALayer.
    /// Appearance-only: a cornerRadius change requires re-decode but does not affect layout geometry.
    public let cornerRadius: CGFloat
    /// Small (~4KB) JPEG bytes decoded synchronously on MainActor for an instant first
    /// paint when the real image has not finished fetching. Takes precedence over
    /// `blurHash` when both are set. Appearance-only — never affects layout geometry.
    public let thumbnailData: Data?
    /// Compact (~30 char) BlurHash string decoded synchronously on MainActor as a
    /// fallback first paint when `thumbnailData` is nil. Appearance-only — never
    /// affects layout geometry.
    public let blurHash: String?

    public init(url: URL?, aspectRatio: CGFloat? = nil, contentMode: VContentMode = .fit) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
        self.cornerRadius = 0
        self.thumbnailData = nil
        self.blurHash = nil
    }

    private init(
        url: URL?,
        aspectRatio: CGFloat?,
        contentMode: VContentMode,
        cornerRadius: CGFloat,
        thumbnailData: Data?,
        blurHash: String?
    ) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.thumbnailData = thumbnailData
        self.blurHash = blurHash
    }

    /// layoutHash covers url, aspectRatio, and contentMode.
    /// cornerRadius, thumbnailData, and blurHash are intentionally excluded: all three
    /// are appearance-only (they affect what gets painted before the real image arrives,
    /// never the fragment's geometry).
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(url)
        h.combine(aspectRatio)
        h.combine(contentMode)
        return h.finalize()
    }

    /// appearanceHash covers cornerRadius, thumbnailData, and blurHash.
    /// Note: changing cornerRadius triggers a re-decode of the image (rounding happens
    /// at decode time via CGContext clip), so the cost is higher than a typical appearance update.
    public var appearanceHash: Int {
        var h = Hasher()
        h.combine(cornerRadius)
        h.combine(thumbnailData)
        h.combine(blurHash)
        return h.finalize()
    }

    public func cornerRadius(_ radius: CGFloat) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: radius,
            thumbnailData: thumbnailData, blurHash: blurHash
        )
    }

    public func aspectRatio(_ ratio: CGFloat) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: ratio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnailData, blurHash: blurHash
        )
    }

    /// Sets the decode-guaranteed first-paint thumbnail. Takes precedence over
    /// `.placeholder(blurHash:)` when both are set on the same node.
    public func placeholder(thumbnail: Data?) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnail, blurHash: blurHash
        )
    }

    /// Sets the decode-guaranteed first-paint BlurHash fallback, used when `thumbnailData` is nil.
    public func placeholder(blurHash: String?) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnailData, blurHash: blurHash
        )
    }
}

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

/// Mirrors NSUnderlineStyle's raw values exactly — converted to it verbatim in
/// TextRasteriser.makeAttributes() — so TextDescriptor can carry the raw Int without
/// importing UIKit into the Layer 1 value-type layer.
public enum VUnderlineStyle: Int, Sendable, Hashable {
    case none = 0
    case single = 1
    case thick = 2
    case double = 9
}

// MARK: - VFontDescriptor convenience

extension VFontDescriptor {
    /// Regular-weight body text (17pt, weight 0 = UIFont.Weight.regular).
    public static let body = VFontDescriptor(size: 17, weight: 0)

    /// `weight` stores `UIFont.Weight`'s raw `Double`, bit-pattern-encoded into an `Int` (see
    /// `TextRasteriser.uiFontWeight`, which decodes it back). A plain literal like `4` or `7`
    /// decodes to a near-zero subnormal, not the weight you meant — use these instead.
    public static let regularWeight = encodeWeight(0.0)
    public static let boldWeight = encodeWeight(0.4)

    private static func encodeWeight(_ rawValue: Double) -> Int {
        Int(Int64(bitPattern: rawValue.bitPattern))
    }

    /// Returns a copy using the given custom font family. Falls back to the system font
    /// deterministically at render time if the family can't be loaded.
    public func family(_ name: String) -> VFontDescriptor {
        VFontDescriptor(size: size, weight: weight, family: name, traits: traits)
    }

    /// Returns a copy with the italic symbolic trait applied.
    public var italic: VFontDescriptor {
        VFontDescriptor(size: size, weight: weight, family: family, traits: traits.union(.italic))
    }
}

// MARK: - VColorDescriptor convenience

extension VColorDescriptor {
    /// Opaque black (RGBA 0,0,0,1).
    public static let primary = VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1)
    /// Opaque white.
    public static let white = VColorDescriptor(red: 1, green: 1, blue: 1, alpha: 1)
    /// Neutral light-gray tint — default fill for `CodeBlockNode`'s container background.
    public static let codeBlockBackground = VColorDescriptor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
    /// Default grid-line color for a rasterized `MarkdownTableNode`.
    public static let tableGridLine = VColorDescriptor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1)
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
    /// Minimum length in the stack's primary axis. flatten() maps nil → 0.0. A nil spacer fills
    /// remaining space in SwiftUI semantics; here it collapses to zero until flexible spacers land.
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
    /// Stable block identity used by parser-created text nodes; excluded from render hashes.
    public let blockID: BlockID?
    /// Residency supplied by a block producer; excluded from render hashes.
    public let blockLifecycle: BlockLifecycle
    public let font: VFontDescriptor
    public let color: VColorDescriptor
    public let lineLimit: Int?
    public let lineBreakMode: VLineBreakMode
    public let underlineStyle: VUnderlineStyle
    public let strikethroughStyle: VUnderlineStyle
    /// Extra tracking, in points. 0 = the font's own default kerning.
    public let kerning: CGFloat
    /// Extra spacing between lines, in points. 0 = no adjustment.
    public let lineSpacing: CGFloat
    /// Ordered per-span styling, same shape and precedence as `TextDescriptor.runs`: empty (the
    /// default) is the legacy single-style path where `font`/`color`/`underlineStyle`/
    /// `strikethroughStyle` apply to the whole string. Non-empty runs win — those scalar fields
    /// are ignored for run-covered text.
    public let runs: [TextRun]
    /// Fill for a vertical bar drawn into the raster along the text's left edge (e.g. a markdown
    /// blockquote). `nil` (the default) draws no bar. Mirrors `TextDescriptor.leadingBarColor`.
    public let leadingBarColor: VColorDescriptor?
    /// Bar thickness in points, same contract as `TextDescriptor.leadingBarWidth`.
    public let leadingBarWidth: CGFloat
    /// Gap between the bar and the text, same contract as `TextDescriptor.leadingBarGap`.
    public let leadingBarGap: CGFloat
    /// Fill for a horizontal rule drawn across the full raster width (e.g. a markdown thematic
    /// break). `nil` (the default) draws no rule. Mirrors `TextDescriptor.ruleColor`.
    public let ruleColor: VColorDescriptor?
    /// Horizontal alignment of this text's row within its container. `.leading` (the default)
    /// matches existing rows. A user-message bubble sets `.trailing`.
    public let alignment: VHorizontalAlignment
    /// Fraction (0...1) of the container's proposed width this row may occupy. `1.0` (the
    /// default) matches existing rows. A user-message bubble narrows this to ~0.8.
    public let maxWidthFraction: Double
    /// Marks this node as one of `CodeBlockNode`'s expanded header/body leaves. Internal — only
    /// `CodeBlockNode.expandedChildren` sets this; the public init always defaults it to `nil`.
    let codeBlockRole: CodeBlockRole?

    public init(
        _ content: String,
        font: VFontDescriptor = .body,
        color: VColorDescriptor = .primary,
        lineLimit: Int? = nil,
        lineBreakMode: VLineBreakMode = .byWordWrapping,
        underlineStyle: VUnderlineStyle = .none,
        strikethroughStyle: VUnderlineStyle = .none,
        kerning: CGFloat = 0,
        lineSpacing: CGFloat = 0,
        runs: [TextRun] = [],
        leadingBarColor: VColorDescriptor? = nil,
        leadingBarWidth: CGFloat = 0,
        leadingBarGap: CGFloat = 0,
        ruleColor: VColorDescriptor? = nil,
        alignment: VHorizontalAlignment = .leading,
        maxWidthFraction: Double = 1.0,
        blockID: BlockID? = nil,
        blockLifecycle: BlockLifecycle = .positional
    ) {
        self.init(
            content, font: font, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: strikethroughStyle,
            kerning: kerning, lineSpacing: lineSpacing, runs: runs,
            leadingBarColor: leadingBarColor, leadingBarWidth: leadingBarWidth, leadingBarGap: leadingBarGap,
            ruleColor: ruleColor, alignment: alignment, maxWidthFraction: maxWidthFraction,
            blockID: blockID, blockLifecycle: blockLifecycle, codeBlockRole: nil
        )
    }

    init(
        _ content: String,
        font: VFontDescriptor = .body,
        color: VColorDescriptor = .primary,
        lineLimit: Int? = nil,
        lineBreakMode: VLineBreakMode = .byWordWrapping,
        underlineStyle: VUnderlineStyle = .none,
        strikethroughStyle: VUnderlineStyle = .none,
        kerning: CGFloat = 0,
        lineSpacing: CGFloat = 0,
        runs: [TextRun] = [],
        leadingBarColor: VColorDescriptor? = nil,
        leadingBarWidth: CGFloat = 0,
        leadingBarGap: CGFloat = 0,
        ruleColor: VColorDescriptor? = nil,
        alignment: VHorizontalAlignment = .leading,
        maxWidthFraction: Double = 1.0,
        blockID: BlockID? = nil,
        blockLifecycle: BlockLifecycle = .positional,
        codeBlockRole: CodeBlockRole?
    ) {
        self.content = content
        self.blockID = blockID
        self.blockLifecycle = blockLifecycle
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.lineBreakMode = lineBreakMode
        self.underlineStyle = underlineStyle
        self.strikethroughStyle = strikethroughStyle
        self.kerning = kerning
        self.lineSpacing = lineSpacing
        self.runs = runs
        self.leadingBarColor = leadingBarColor
        self.leadingBarWidth = leadingBarWidth
        self.leadingBarGap = leadingBarGap
        self.ruleColor = ruleColor
        self.alignment = alignment
        self.maxWidthFraction = maxWidthFraction
        self.codeBlockRole = codeBlockRole
    }

    /// layoutHash covers all properties that affect geometry: content, font metrics
    /// (size, weight, family, traits), line limit, line break mode, kerning, line spacing,
    /// alignment, maxWidthFraction, and each run's length + font (the run fields that affect
    /// glyph advances/wrapping).
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(content)
        h.combine(font.size)
        h.combine(font.weight)
        h.combine(font.family)
        h.combine(font.traits)
        h.combine(lineLimit)
        h.combine(lineBreakMode)
        h.combine(kerning)
        h.combine(lineSpacing)
        h.combine(leadingBarWidth)
        h.combine(leadingBarGap)
        h.combine(alignment)
        h.combine(maxWidthFraction)
        for run in runs {
            h.combine(run.length)
            h.combine(run.font)
        }
        return h.finalize()
    }

    /// appearanceHash covers color and decoration ink (underline/strikethrough) — none of these
    /// affect glyph advances or line wrapping — plus each run's paint-only fields (color,
    /// underline/strikethrough style, background color, link URL).
    public var appearanceHash: Int {
        var h = Hasher()
        h.combine(color)
        h.combine(underlineStyle)
        h.combine(strikethroughStyle)
        h.combine(leadingBarColor)
        h.combine(ruleColor)
        for run in runs {
            h.combine(run.color)
            h.combine(run.underlineStyle)
            h.combine(run.strikethroughStyle)
            h.combine(run.backgroundColor)
            h.combine(run.linkURL)
        }
        return h.finalize()
    }

    public func font(_ newFont: VFontDescriptor) -> TextNode {
        TextNode(
            content, font: newFont, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: strikethroughStyle,
            kerning: kerning, lineSpacing: lineSpacing, runs: runs, blockID: blockID, blockLifecycle: blockLifecycle
        )
    }

    public func lineLimit(_ limit: Int) -> TextNode {
        TextNode(
            content, font: font, color: color, lineLimit: limit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: strikethroughStyle,
            kerning: kerning, lineSpacing: lineSpacing, runs: runs, blockID: blockID, blockLifecycle: blockLifecycle
        )
    }

    public func underline(_ style: VUnderlineStyle = .single) -> TextNode {
        TextNode(
            content, font: font, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: style, strikethroughStyle: strikethroughStyle,
            kerning: kerning, lineSpacing: lineSpacing, runs: runs, blockID: blockID, blockLifecycle: blockLifecycle
        )
    }

    public func strikethrough(_ style: VUnderlineStyle = .single) -> TextNode {
        TextNode(
            content, font: font, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: style,
            kerning: kerning, lineSpacing: lineSpacing, runs: runs, blockID: blockID, blockLifecycle: blockLifecycle
        )
    }

    public func kerning(_ value: CGFloat) -> TextNode {
        TextNode(
            content, font: font, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: strikethroughStyle,
            kerning: value, lineSpacing: lineSpacing, runs: runs, blockID: blockID, blockLifecycle: blockLifecycle
        )
    }

    public func lineSpacing(_ value: CGFloat) -> TextNode {
        TextNode(
            content, font: font, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: strikethroughStyle,
            kerning: kerning, lineSpacing: value, runs: runs, blockID: blockID, blockLifecycle: blockLifecycle
        )
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
    /// Small (~4KB) JPEG bytes decoded synchronously on MainActor for an instant first paint before
    /// the real image fetches. Takes precedence over `blurHash`. Appearance-only.
    public let thumbnailData: Data?
    /// Compact (~30 char) BlurHash string decoded synchronously on MainActor as a fallback first
    /// paint when `thumbnailData` is nil. Appearance-only.
    public let blurHash: String?
    /// Consumer-supplied placeholder payload for a custom `PlaceholderRenderer`, used as the last
    /// fallback tier when `thumbnailData` and `blurHash` are both nil or fail to decode. Appearance-only.
    public let customPlaceholderPayload: AnyPlaceholderPayload?

    public init(url: URL?, aspectRatio: CGFloat? = nil, contentMode: VContentMode = .fit) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
        self.cornerRadius = 0
        self.thumbnailData = nil
        self.blurHash = nil
        self.customPlaceholderPayload = nil
    }

    private init(
        url: URL?,
        aspectRatio: CGFloat?,
        contentMode: VContentMode,
        cornerRadius: CGFloat,
        thumbnailData: Data?,
        blurHash: String?,
        customPlaceholderPayload: AnyPlaceholderPayload?
    ) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.thumbnailData = thumbnailData
        self.blurHash = blurHash
        self.customPlaceholderPayload = customPlaceholderPayload
    }

    /// layoutHash covers url, aspectRatio, and contentMode. cornerRadius, thumbnailData, and blurHash
    /// are intentionally excluded — they're appearance-only, affecting paint but never geometry.
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(url)
        h.combine(aspectRatio)
        h.combine(contentMode)
        return h.finalize()
    }

    /// appearanceHash covers cornerRadius, thumbnailData, blurHash, and customPlaceholderPayload.
    /// Note: changing cornerRadius triggers a re-decode of the image (rounding happens
    /// at decode time via CGContext clip), so the cost is higher than a typical appearance update.
    public var appearanceHash: Int {
        var h = Hasher()
        h.combine(cornerRadius)
        h.combine(thumbnailData)
        h.combine(blurHash)
        h.combine(customPlaceholderPayload)
        return h.finalize()
    }

    public func cornerRadius(_ radius: CGFloat) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: radius,
            thumbnailData: thumbnailData, blurHash: blurHash, customPlaceholderPayload: customPlaceholderPayload
        )
    }

    public func aspectRatio(_ ratio: CGFloat) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: ratio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnailData, blurHash: blurHash, customPlaceholderPayload: customPlaceholderPayload
        )
    }

    /// Sets the decode-guaranteed first-paint thumbnail. Takes precedence over
    /// `.placeholder(blurHash:)` when both are set on the same node.
    public func placeholder(thumbnail: Data?) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnail, blurHash: blurHash, customPlaceholderPayload: customPlaceholderPayload
        )
    }

    /// Sets the decode-guaranteed first-paint BlurHash fallback, used when `thumbnailData` is nil.
    public func placeholder(blurHash: String?) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnailData, blurHash: blurHash, customPlaceholderPayload: customPlaceholderPayload
        )
    }

    /// Sets a consumer-defined placeholder payload, tried when `thumbnailData` and `blurHash` are both
    /// nil or fail to decode. Interpreted only by a custom `PlaceholderRenderer` injected via
    /// `RenderEnvironment` — the built-in `DefaultPlaceholderRenderer` ignores it. `payload` must be
    /// `Hashable & Sendable` so it folds into `appearanceHash`.
    ///
    /// `PlaceholderRenderer.render(...)` runs SYNCHRONOUSLY on the MainActor in the cell-bind scroll
    /// path — keep it cheap (p99 < 500us; a full-res decode here drops scroll frames).
    public func placeholder<T: Hashable & Sendable>(custom payload: T?) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnailData, blurHash: blurHash,
            customPlaceholderPayload: payload.map(AnyPlaceholderPayload.init)
        )
    }

    /// Clears (or sets from an already-boxed value) the custom placeholder payload. The generic
    /// `placeholder<T>(custom:)` overload can't infer `T` from a bare `nil` literal, so this overload
    /// avoids requiring a spelled-out `Optional<T>.none`.
    public func placeholder(custom payload: AnyPlaceholderPayload?) -> AsyncImageNode {
        AsyncImageNode(
            url: url, aspectRatio: aspectRatio, contentMode: contentMode, cornerRadius: cornerRadius,
            thumbnailData: thumbnailData, blurHash: blurHash,
            customPlaceholderPayload: payload
        )
    }
}

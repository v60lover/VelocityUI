// CodeBlockNode.swift

import Foundation

/// Cornering + tint for a code block's container background.
struct CodeBlockChrome: Sendable, Equatable {
    let cornerRadius: CGFloat
    let backgroundColor: VColorDescriptor
    /// Raw fence-info language string (e.g. "python", "js"), `nil` if the fence had none.
    /// The body leaf uses this to look up a highlighting grammar via `LanguageID(fenceInfo:)`.
    let language: String?
}

/// Marks a text render part belonging to a code block. `nil` for ordinary text.
enum CodeBlockRole: Sendable, Equatable {
    case header(CodeBlockChrome)
    case body(CodeBlockChrome)
}

/// A fenced code block: language label + raw, verbatim source.
///
/// `flatten()` preserves this as one direct code-block leaf. Its render plan owns the
/// background, header, and body without introducing a nested container.
///
/// Highlighting, card background, and horizontal scroll land in later beads
/// (VelocityUI-oz5q.2–.7) — today this renders as plain monospaced text.
public struct CodeBlockNode: RenderNode {
    public let language: String?
    public let rawCode: String
    /// Font for the code body. Defaults to a real monospace face — paragraphs default
    /// to the system font, which code should never share.
    public let font: VFontDescriptor
    public let blockID: BlockID?
    public let blockLifecycle: BlockLifecycle
    /// Corner radius for the container background, pre-rounded via `CGContext` clip at
    /// rasterization time — never `CALayer.cornerRadius`/`masksToBounds`.
    public let cornerRadius: CGFloat
    /// Fill color for the container background.
    public let backgroundColor: VColorDescriptor

    public init(
        language: String? = nil,
        rawCode: String,
        font: VFontDescriptor = CodeBlockNode.defaultFont,
        cornerRadius: CGFloat = 12,
        backgroundColor: VColorDescriptor = .codeBlockBackground,
        blockID: BlockID? = nil,
        blockLifecycle: BlockLifecycle = .positional
    ) {
        self.language = language
        self.rawCode = rawCode
        self.font = font
        self.cornerRadius = cornerRadius
        self.backgroundColor = backgroundColor
        self.blockID = blockID
        self.blockLifecycle = blockLifecycle
    }

    /// Menlo ships on every iOS device and is always resolvable, unlike a downloaded
    /// custom family — see `VFontDescriptor.family`'s fallback contract.
    public static let defaultFont = VFontDescriptor(size: 15, weight: VFontDescriptor.regularWeight, family: "Menlo")

    private static let headerFont = VFontDescriptor(size: 12, weight: VFontDescriptor.regularWeight, family: "Menlo")

    /// Covers `rawCode` and the body font's metrics — the same split `TextNode.layoutHash`
    /// uses. `language` only affects the header label's paint, not geometry.
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(rawCode)
        h.combine(font.size)
        h.combine(font.weight)
        h.combine(font.family)
        return h.finalize()
    }

    public var appearanceHash: Int {
        var h = Hasher()
        h.combine(language)
        h.combine(cornerRadius)
        h.combine(backgroundColor)
        return h.finalize()
    }

    var descriptor: CodeBlockDescriptor {
        let chrome = CodeBlockChrome(cornerRadius: cornerRadius, backgroundColor: backgroundColor, language: language)
        return CodeBlockDescriptor(
            language: language,
            rawCode: rawCode,
            font: font,
            headerFont: Self.headerFont,
            chrome: chrome,
            blockID: blockID,
            lifecycle: blockLifecycle,
            layoutHash: layoutHash,
            appearanceHash: appearanceHash
        )
    }
}

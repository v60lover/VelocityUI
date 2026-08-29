// CodeBlockNode.swift

import Foundation

/// Cornering + tint for a code block's container background. Threaded from `CodeBlockNode`
/// through its header/body leaves' `codeBlockRole` so `extractFragments` can synthesize the
/// background fragment without CodeBlockNode wrapping them in a container (see this file's
/// doc comment on `flatten()`'s FLAT-siblings requirement, and VelocityUI-qinu for why the
/// general ZStack sibling-size primitive is deliberately not used here instead).
struct CodeBlockChrome: Sendable, Equatable {
    let cornerRadius: CGFloat
    let backgroundColor: VColorDescriptor
    /// Raw fence-info language string (e.g. "python", "js"), `nil` if the fence had none.
    /// The body leaf uses this to look up a highlighting grammar via `LanguageID(fenceInfo:)`.
    let language: String?
}

/// Marks a `TextNode`/`TextDescriptor` as one of a code block's two expanded leaves. `nil` for
/// ordinary text. `extractFragments` pairs an adjacent `.header` immediately followed by `.body`
/// to synthesize the background fragment beneath both.
enum CodeBlockRole: Sendable, Equatable {
    case header(CodeBlockChrome)
    case body(CodeBlockChrome)
}

/// A fenced code block: language label + raw, verbatim source.
///
/// `flatten()` expands this into two FLAT sibling leaves (header, body), not a nested
/// container — `FeedScrollView.flatBlocks` requires direct children under a message's
/// root VStack, and nesting would silently degrade the whole message to the slow
/// full-refresh diff path. `.frame()`/`.renderID()` wrapping isn't supported; pass
/// `blockID:` directly instead.
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

    /// The two flat leaves `flatten()` visits in this node's place. Internal — production
    /// code never inspects this past flatten(), same convention as `VStackNode.children`.
    var expandedChildren: (header: TextNode, body: TextNode) {
        let chrome = CodeBlockChrome(cornerRadius: cornerRadius, backgroundColor: backgroundColor, language: language)
        let header = TextNode(
            language ?? "",
            font: Self.headerFont,
            color: .primary,
            blockID: blockID.map { Self.derivedBlockID($0, suffix: "header") },
            blockLifecycle: blockLifecycle,
            codeBlockRole: .header(chrome)
        )
        let body = TextNode(
            rawCode,
            font: font,
            color: .primary,
            lineBreakMode: .byClipping,
            blockID: blockID.map { Self.derivedBlockID($0, suffix: "body") },
            blockLifecycle: blockLifecycle,
            codeBlockRole: .body(chrome)
        )
        return (header, body)
    }

    /// Combines a base id + suffix into a distinct one. `BlockID.rawValue` is a boxed
    /// `AnyHashable`, not a `String`, so this can't be plain concatenation.
    private struct DerivedKey: Hashable, Sendable {
        let base: BlockID
        let suffix: String
    }

    private static func derivedBlockID(_ base: BlockID, suffix: String) -> BlockID {
        BlockID(DerivedKey(base: base, suffix: suffix))
    }
}

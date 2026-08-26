// CodeBlockNode.swift

import Foundation

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

    public init(
        language: String? = nil,
        rawCode: String,
        font: VFontDescriptor = CodeBlockNode.defaultFont,
        blockID: BlockID? = nil,
        blockLifecycle: BlockLifecycle = .positional
    ) {
        self.language = language
        self.rawCode = rawCode
        self.font = font
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
        return h.finalize()
    }

    /// The two flat leaves `flatten()` visits in this node's place. Internal — production
    /// code never inspects this past flatten(), same convention as `VStackNode.children`.
    var expandedChildren: (header: TextNode, body: TextNode) {
        let header = TextNode(
            language ?? "",
            font: Self.headerFont,
            color: .primary,
            blockID: blockID.map { Self.derivedBlockID($0, suffix: "header") },
            blockLifecycle: blockLifecycle
        )
        let body = TextNode(
            rawCode,
            font: font,
            color: .primary,
            lineBreakMode: .byClipping,
            blockID: blockID.map { Self.derivedBlockID($0, suffix: "body") },
            blockLifecycle: blockLifecycle
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

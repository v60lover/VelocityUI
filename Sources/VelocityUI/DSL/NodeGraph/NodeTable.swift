// NodeTable.swift

import Foundation
import CoreGraphics

// MARK: - Sendable descriptors (Layer 1 → Layer 2 boundary)

/// Sendable font descriptor. Wraps UIFont parameters without importing UIKit
/// into the value-type layer. Converted to UIFont only inside TextMeasurementContext.
public struct VFontDescriptor: Sendable, Hashable {
    public let size: CGFloat
    public let weight: Int  // raw value of UIFont.Weight for Sendable conformance
    /// Custom font family name, as passed to `UIFont(name:size:)`. nil = system font.
    /// If the named font can't be loaded, TextRasteriser falls back to the system font
    /// deterministically — never crashes.
    public let family: String?
    /// Symbolic traits (e.g. italic). See VFontTraits.
    public let traits: VFontTraits

    public init(size: CGFloat, weight: Int, family: String? = nil, traits: VFontTraits = []) {
        self.size = size
        self.weight = weight
        self.family = family
        self.traits = traits
    }
}

/// Sendable substitute for UIFontDescriptor.SymbolicTraits — keeps VFontDescriptor UIKit-free.
/// Converted to the real UIKit type only inside TextRasteriser.swift.
public struct VFontTraits: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let italic = VFontTraits(rawValue: 1 << 0)
}

/// Sendable substitute for UIContentSizeCategory — keeps TextDescriptor UIKit-free at the
/// value-type layer; converts to/from the real UIKit type only inside TextRasteriser.swift.
///
/// `.unspecified` short-circuits before `UIFontMetrics` is ever called, so `resolvedFont`
/// returns the declared point size verbatim. This matters because passing `.unspecified`
/// itself INTO `UIFontMetrics` silently falls back to a hidden global read
/// (`UIApplication.shared.preferredContentSizeCategory`), banned in nonisolated helpers
/// (CLAUDE.md §4) — so every caller that never opts in stays byte-identical to before.
public enum VContentSizeCategory: Sendable, Hashable {
    case unspecified
    case extraSmall
    case small
    case medium
    case large
    case extraLarge
    case extraExtraLarge
    case extraExtraExtraLarge
    case accessibilityMedium
    case accessibilityLarge
    case accessibilityExtraLarge
    case accessibilityExtraExtraLarge
    case accessibilityExtraExtraExtraLarge
}

/// Sendable color descriptor. RGBA components, display-P3 assumed.
public struct VColorDescriptor: Sendable, Hashable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// flatten() always passes the real layoutHash/appearanceHash from the corresponding DSL node.
/// There is no defaulted-zero init — hand-built test fixtures must go through the explicit
/// `.test(...)` factory in the test target so the sentinel stays greppable, never silently
/// reachable from production code.
public struct VStackDescriptor: Sendable {
    public let alignment: Int  // raw HorizontalAlignment
    public let spacing: CGFloat
    public let layoutHash: Int
    public let appearanceHash: Int

    public init(alignment: Int, spacing: CGFloat, layoutHash: Int, appearanceHash: Int) {
        self.alignment = alignment
        self.spacing = spacing
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
    }
}

public struct HStackDescriptor: Sendable {
    public let alignment: Int  // raw VerticalAlignment
    public let spacing: CGFloat
    public let layoutHash: Int
    public let appearanceHash: Int

    public init(alignment: Int, spacing: CGFloat, layoutHash: Int, appearanceHash: Int) {
        self.alignment = alignment
        self.spacing = spacing
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
    }
}

public struct ZStackDescriptor: Sendable {
    public let alignment: Int  // raw Alignment
    public let layoutHash: Int
    public let appearanceHash: Int

    public init(alignment: Int, layoutHash: Int, appearanceHash: Int) {
        self.alignment = alignment
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
    }
}

/// One styled span within a multi-run `TextDescriptor`, in document order. `length` is the
/// number of UTF-16 units this run consumes from `TextDescriptor.content`; run lengths should
/// sum to `content.utf16.count`.
///
/// Producers folding runs into a hash: `length`/`font` affect layout, the rest is paint-only —
/// same split as `TextNode.layoutHash`/`appearanceHash`.
public struct TextRun: Sendable, Hashable {
    public let length: Int
    public let font: VFontDescriptor
    public let color: VColorDescriptor
    /// Raw NSUnderlineStyle.rawValue. 0 = no underline.
    public let underlineStyle: Int
    /// Raw NSUnderlineStyle.rawValue, applied as strikethrough. 0 = none.
    public let strikethroughStyle: Int
    /// Drawn into the bitmap as a `.backgroundColor` attribute — never a CALayer cornerRadius.
    public let backgroundColor: VColorDescriptor?
    /// Carried as an `.link` attribute for a later hit-test pass to resolve.
    public let linkURL: URL?

    public init(
        length: Int,
        font: VFontDescriptor,
        color: VColorDescriptor,
        underlineStyle: Int = 0,
        strikethroughStyle: Int = 0,
        backgroundColor: VColorDescriptor? = nil,
        linkURL: URL? = nil
    ) {
        self.length = length
        self.font = font
        self.color = color
        self.underlineStyle = underlineStyle
        self.strikethroughStyle = strikethroughStyle
        self.backgroundColor = backgroundColor
        self.linkURL = linkURL
    }
}

public struct TextDescriptor: Sendable {
    public let content: String
    public let font: VFontDescriptor
    public let color: VColorDescriptor
    public let lineLimit: Int?
    public let lineBreakMode: Int  // raw NSLineBreakMode
    /// Raw NSUnderlineStyle.rawValue. 0 = no underline.
    public let underlineStyle: Int
    /// Raw NSUnderlineStyle.rawValue, applied as strikethrough. 0 = none.
    public let strikethroughStyle: Int
    /// Extra tracking added to NSAttributedString.Key.kern, in points. 0 = the font's
    /// own default kerning (no attribute is set — see TextRasteriser.makeAttributes()).
    public let kerning: CGFloat
    /// Extra spacing between lines, in points. 0 = no adjustment.
    public let lineSpacing: CGFloat
    /// Dynamic Type category `resolvedFont` scales against via `UIFontMetrics`. `.unspecified` (the
    /// default) skips scaling entirely. `flatten()` is the only production writer of a non-default
    /// value, and folds it into `layoutHash` so a category change misses `LayoutCache` and re-measures.
    public let contentSizeCategory: VContentSizeCategory
    /// Ordered per-span styling within `content`. Empty (the default) is the legacy single-style
    /// path — `font`/`color`/etc. apply to the whole string. Non-empty runs are applied
    /// left-to-right, each consuming `TextRun.length` UTF-16 units of `content`.
    public let runs: [TextRun]
    public let layoutHash: Int
    public let appearanceHash: Int
    /// Marks this descriptor as one of `CodeBlockNode`'s expanded header/body leaves. Internal —
    /// only `Flattener` sets this (threaded from `TextNode.codeBlockRole`); the public init always
    /// defaults it to `nil`. `extractFragments` pairs adjacent header+body descriptors carrying
    /// this to synthesize the container background fragment.
    let codeBlockRole: CodeBlockRole?

    /// Public and memberwise on purpose: `rasterizeText(_:size:scale:)` and
    /// `TextMeasurementContext.measure(_:width:)` are public entry points taking a TextDescriptor,
    /// so callers outside this module need a way to build one directly.
    public init(
        content: String,
        font: VFontDescriptor,
        color: VColorDescriptor,
        lineLimit: Int?,
        lineBreakMode: Int,
        underlineStyle: Int = 0,
        strikethroughStyle: Int = 0,
        kerning: CGFloat = 0,
        lineSpacing: CGFloat = 0,
        contentSizeCategory: VContentSizeCategory = .unspecified,
        runs: [TextRun] = [],
        layoutHash: Int,
        appearanceHash: Int
    ) {
        self.init(
            content: content, font: font, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: strikethroughStyle,
            kerning: kerning, lineSpacing: lineSpacing, contentSizeCategory: contentSizeCategory, runs: runs,
            layoutHash: layoutHash, appearanceHash: appearanceHash, codeBlockRole: nil
        )
    }

    init(
        content: String,
        font: VFontDescriptor,
        color: VColorDescriptor,
        lineLimit: Int?,
        lineBreakMode: Int,
        underlineStyle: Int = 0,
        strikethroughStyle: Int = 0,
        kerning: CGFloat = 0,
        lineSpacing: CGFloat = 0,
        contentSizeCategory: VContentSizeCategory = .unspecified,
        runs: [TextRun] = [],
        layoutHash: Int,
        appearanceHash: Int,
        codeBlockRole: CodeBlockRole?
    ) {
        self.content = content
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.lineBreakMode = lineBreakMode
        self.underlineStyle = underlineStyle
        self.strikethroughStyle = strikethroughStyle
        self.kerning = kerning
        self.lineSpacing = lineSpacing
        self.contentSizeCategory = contentSizeCategory
        self.runs = runs
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
        self.codeBlockRole = codeBlockRole
    }
}

/// Background fill for a code block's container chrome. Sendable and content-only — geometry
/// (the union of header + body frames) lives on the owning `Fragment`, not here. Cross-platform
/// (no CGImage/UIKit dependency) — the CGContext rasterization itself lives in
/// `CodeBlockRasterizer.swift`, which is UIKit-gated.
public struct CodeBlockBackgroundDescriptor: Sendable, Equatable {
    public let cornerRadius: CGFloat
    public let color: VColorDescriptor

    public init(cornerRadius: CGFloat, color: VColorDescriptor) {
        self.cornerRadius = cornerRadius
        self.color = color
    }
}

/// One logical code block at the Layer 1 → Layer 2 boundary. Its three render parts stay
/// ordered and owned by the same block identity until fragment extraction.
public struct CodeBlockDescriptor: Sendable {
    public let language: String?
    public let rawCode: String
    public let font: VFontDescriptor
    let headerFont: VFontDescriptor
    let chrome: CodeBlockChrome
    let blockID: BlockID?
    let lifecycle: BlockLifecycle
    public let layoutHash: Int
    public let appearanceHash: Int

    var headerText: TextDescriptor {
        TextDescriptor(
            content: language ?? "", font: headerFont, color: .primary, lineLimit: nil,
            lineBreakMode: VLineBreakMode.byWordWrapping.rawValue, layoutHash: layoutHash,
            appearanceHash: appearanceHash, codeBlockRole: .header(chrome)
        )
    }

    var bodyText: TextDescriptor {
        TextDescriptor(
            content: rawCode, font: font, color: .primary, lineLimit: nil,
            lineBreakMode: VLineBreakMode.byClipping.rawValue, layoutHash: layoutHash,
            appearanceHash: appearanceHash, codeBlockRole: .body(chrome)
        )
    }
}

public struct ImageDescriptor: Sendable {
    public let url: URL?
    public let aspectRatio: CGFloat?
    public let contentMode: Int  // raw ContentMode
    public let cornerRadius: CGFloat  // decode-time rounding — never set on CALayer
    public let layoutHash: Int
    public let appearanceHash: Int
    /// Small (~4KB) JPEG bytes for a decode-guaranteed first paint. Takes precedence
    /// over `blurHash` when both are set. See AsyncImageNode.placeholder(thumbnail:).
    public let thumbnailData: Data?
    /// Compact BlurHash string, decoded when `thumbnailData` is nil.
    /// See AsyncImageNode.placeholder(blurHash:).
    public let blurHash: String?
    /// Consumer-supplied placeholder payload, tried when both `thumbnailData` and
    /// `blurHash` are nil or fail to decode. Only a custom `PlaceholderRenderer` injected
    /// via `RenderEnvironment` interprets this — the built-in `DefaultPlaceholderRenderer`
    /// returns nil for it. See AsyncImageNode.placeholder(custom:).
    public let customPlaceholderPayload: AnyPlaceholderPayload?

    public init(
        url: URL?,
        aspectRatio: CGFloat?,
        contentMode: Int,
        cornerRadius: CGFloat,
        layoutHash: Int,
        appearanceHash: Int,
        thumbnailData: Data? = nil,
        blurHash: String? = nil,
        customPlaceholderPayload: AnyPlaceholderPayload? = nil
    ) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
        self.thumbnailData = thumbnailData
        self.blurHash = blurHash
        self.customPlaceholderPayload = customPlaceholderPayload
    }
}

public struct GIFDescriptor: Sendable {
    public let url: URL?
    public let loopCount: Int
    public let autoplay: Bool
    public let layoutHash: Int
    public let appearanceHash: Int
}

public struct VideoDescriptor: Sendable {
    public let url: URL?
    public let autoplayThreshold: CGFloat?  // nil = never, 0.0–1.0 = onVisible
    public let muted: Bool
    public let loopEnabled: Bool
    public let layoutHash: Int
    public let appearanceHash: Int
}

public struct HostingDescriptor: Sendable {
    public let size: CGSize
    public let layoutHash: Int
    public let appearanceHash: Int
}

// MARK: - NodeKind

/// Flat enum — no existential, no heap alloc per node.
/// switch is O(1) with no witness table dispatch.
/// All associated values are Sendable value types.
public enum NodeKind: Sendable {
    case vstack(VStackDescriptor)
    case hstack(HStackDescriptor)
    case zstack(ZStackDescriptor)
    case spacer(CGFloat)
    case text(TextDescriptor)
    case codeBlock(CodeBlockDescriptor)
    case image(ImageDescriptor)
    case gif(GIFDescriptor)
    case video(VideoDescriptor)
    case hosting(HostingDescriptor)
    case customLayer(CGSize)
}

// MARK: - NodeTable

/// Flat, index-based representation of a DSL node tree. Created once on @MainActor from a
/// RenderNode tree; passed by value across all layer boundaries — no existentials past this point.
///
/// `itemID` is `AnyHashable` so it can be a Set/Dictionary key for the differ and cell-recycling
/// layer. `AnyHashable` isn't stdlib-Sendable, hence `nonisolated(unsafe)` — safe because the
/// generic init constrains ID to `Hashable & Sendable`, so the boxed payload is always Sendable.
public struct NodeTable: Sendable {
    // See struct-level doc for the full rationale on nonisolated(unsafe) here.
    nonisolated(unsafe) private let _itemID: AnyHashable

    public var itemID: AnyHashable {
        NodeTable._itemIDCounter += 1
        return _itemID
    }

    public let nodes: [NodeKind]
    public let parentIndices: [Int]  // parentIndices[i] = parent of node i; -1 for root
    public let layoutHash: Int
    public let appearanceHash: Int
    /// Optional stable identity for each flattened node, indexed identically to `nodes`.
    public let blockIDs: [BlockID?]
    /// Per-node lifecycle metadata. `.positional` preserves legacy trailing-hot behavior.
    public let blockLifecycles: [BlockLifecycle]

    /// Parallel array of per-node `.frame()` specs, indexed identically to `nodes`. `nil` (not an
    /// all-`.unspecified` array) whenever no node in the tree was framed — the zero-cost unframed
    /// path: no allocation, and `frame(at:)` takes a single predicted `nil`-check branch. Populated
    /// by `flatten()` at the wrapped node's index.
    public let frames: [FrameSpec]?

    // Precomputed in init — turns the old O(n) scan in children(of:) into O(k). childIndices is a
    // contiguous array of child node indices grouped by parent; childRanges[i] is its slice for node i.
    // Insertion order (= DSL child order = z-order) is preserved because buildChildIndex iterates
    // parentIndices in node-index order, which equals DFS pre-order.
    private let childRanges: [Range<Int>]
    private let childIndices: [Int]

    /// Generic init: callers pass any Hashable & Sendable itemID; it is boxed to AnyHashable here.
    /// This is the only place AnyHashable boxing occurs — the rest of the stack reads itemID as AnyHashable.
    public init<ID: Hashable & Sendable>(
        itemID: ID,
        nodes: [NodeKind],
        parentIndices: [Int],
        layoutHash: Int,
        appearanceHash: Int,
        frames: [FrameSpec]? = nil,
        blockIDs: [BlockID?]? = nil,
        blockLifecycles: [BlockLifecycle]? = nil
    ) {
        self._itemID = AnyHashable(itemID)
        self.nodes = nodes
        self.parentIndices = parentIndices
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
        self.frames = frames
        self.blockIDs = NodeTable.sanitizedBlockIDs(blockIDs, nodeCount: nodes.count)
        self.blockLifecycles = NodeTable.sanitizedBlockLifecycles(blockLifecycles, nodeCount: nodes.count)
        (childRanges, childIndices) = NodeTable.buildChildIndex(parentIndices: parentIndices)
    }

    /// Returns the indices of direct children of `nodeIndex` in insertion order.
    /// O(1) slice — no allocation, no linear scan. The backing buffer is shared with childIndices.
    public func children(of nodeIndex: Int) -> ArraySlice<Int> {
        guard nodeIndex >= 0, nodeIndex < childRanges.count else { return [] }
        return childIndices[childRanges[nodeIndex]]
    }

    /// Returns the `.frame()` spec recorded for `i`, or `.unspecified` when this table has no frames
    /// at all or `i` is out of bounds. Callers branch on `spec.isSpecified` rather than `frames == nil`
    /// so a bounds-safe default reads identically to "never framed".
    public func frame(at i: Int) -> FrameSpec {
        guard let frames, i >= 0, i < frames.count else { return .unspecified }
        return frames[i]
    }

    public func blockID(at i: Int) -> BlockID? {
        guard i >= 0, i < blockIDs.count else { return nil }
        return blockIDs[i]
    }

    public func blockLifecycle(at i: Int) -> BlockLifecycle {
        guard i >= 0, i < blockLifecycles.count else { return .positional }
        return blockLifecycles[i]
    }

    // MARK: - Private

    private static func buildChildIndex(parentIndices: [Int]) -> (ranges: [Range<Int>], indices: [Int]) {
        let n = parentIndices.count
        guard n > 0 else { return ([], []) }

        var childCount = [Int](repeating: 0, count: n)
        for p in parentIndices where p >= 0 { childCount[p] += 1 }

        var starts = [Int](repeating: 0, count: n)
        var total = 0
        for i in 0..<n { starts[i] = total; total += childCount[i] }

        var idx = [Int](repeating: 0, count: total)
        var cursor = starts
        for (i, p) in parentIndices.enumerated() where p >= 0 {
            idx[cursor[p]] = i
            cursor[p] += 1
        }

        let ranges = (0..<n).map { i in starts[i]..<(starts[i] + childCount[i]) }
        return (ranges, idx)
    }

    private static func sanitizedBlockIDs(_ proposed: [BlockID?]?, nodeCount: Int) -> [BlockID?] {
        guard var proposed, proposed.count == nodeCount else {
            return [BlockID?](repeating: nil, count: nodeCount)
        }
        var counts: [BlockID: Int] = [:]
        for case let id? in proposed { counts[id, default: 0] += 1 }
        let duplicates = counts.filter { $0.value > 1 }.map(\.key)
        if !duplicates.isEmpty {
            assertionFailure("Duplicate render IDs in one NodeTable")
            let duplicateSet = Set(duplicates)
            for index in proposed.indices where proposed[index].map(duplicateSet.contains) == true {
                proposed[index] = nil
            }
        }
        return proposed
    }

    private static func sanitizedBlockLifecycles(
        _ proposed: [BlockLifecycle]?, nodeCount: Int
    ) -> [BlockLifecycle] {
        guard let proposed, proposed.count == nodeCount else {
            return [BlockLifecycle](repeating: .positional, count: nodeCount)
        }
        return proposed
    }
}

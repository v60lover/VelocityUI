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

/// flatten() always passes the real layoutHash/appearanceHash from the corresponding DSL
/// node. There is no defaulted-zero init — hand-built test fixtures that don't care about
/// the hash value must go through the explicit `.test(...)` factory in the test target
/// (Tests/VelocityUITests/Support/DescriptorTestFactories.swift) so the sentinel is visible
/// and greppable at the call site, never silently reachable from production code.
/// Phase 2+ subtree-level classifier will rely on these — do not remove.
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
    /// Dynamic Type category `resolvedFont` scales against via `UIFontMetrics`.
    /// `.unspecified` (the default) skips scaling entirely — see `VContentSizeCategory`'s doc.
    /// `flatten()` is the only production writer of a non-default value (VelocityUI-ezo.2.5) —
    /// it also folds this into `layoutHash` so a category change misses `LayoutCache` and
    /// reclassifies as `.layout`/re-freezes, the same way any other geometry-affecting
    /// attribute does.
    public let contentSizeCategory: VContentSizeCategory
    public let layoutHash: Int
    public let appearanceHash: Int

    /// Public and memberwise on purpose: `rasterizeText(_:size:scale:)` and
    /// `TextMeasurementContext.measure(_:width:)` are both public entry points that take a
    /// TextDescriptor as their argument, so callers outside this module need a way to build
    /// one directly — this init is that contract, not an accident of Sendable-struct synthesis.
    /// Keep its parameter list in sync with those two entry points' needs.
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
        layoutHash: Int,
        appearanceHash: Int
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
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
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
/// `itemID` is `AnyHashable` (not `any Hashable & Sendable`) so it can be a Set/Dictionary key
/// for the differ and cell-recycling layer. `AnyHashable` isn't stdlib-Sendable (its box can hold
/// non-Sendable payloads), hence `nonisolated(unsafe)` — safe because the generic init constrains
/// ID to `Hashable & Sendable`, so the boxed payload is always Sendable in practice. Don't remove
/// the annotation without first making `AnyHashable` Sendable upstream.
public struct NodeTable: Sendable {
    // See struct-level doc for the full rationale on nonisolated(unsafe) here.
    nonisolated(unsafe) private let _itemID: AnyHashable

    #if canImport(XCTest)
    // No-singletons exemption: test-only instrumentation. Injecting this through the nonisolated
    // pure helpers (classify, measureNode) would violate their "no implicit cache lookup"
    // contract (CLAUDE.md §4); static placement is the lesser violation.
    //
    // Counts every .itemID read, not AnyHashable constructions. RenderDiffer.diff reads it 4x
    // per surviving item (prevIndex build, lookup, removeValue, removed-check); itemsDidChange
    // height-forwarding adds zero (uses (prevIdx, nextIdx) pairs). A regression that rebuilds an
    // [AnyHashable: _] dict for height-forwarding raises the count to 6×N — tests catch it.
    //
    // NOT thread-safe: the 4×N bound assumes serial access, no concurrent Task reading .itemID
    // during measurement. testAppearanceOnlyUpdateAnyHashableAccessCountBounded enforces this
    // via frame.height=0 (blocks updateVisibleCells Task spawns) — without that guard a test
    // would under-count and false-pass.
    nonisolated(unsafe) static var _itemIDCounter: Int = 0
    #endif

    public var itemID: AnyHashable {
        #if canImport(XCTest)
        NodeTable._itemIDCounter += 1
        #endif
        return _itemID
    }

    public let nodes: [NodeKind]
    public let parentIndices: [Int]  // parentIndices[i] = parent of node i; -1 for root
    public let layoutHash: Int
    public let appearanceHash: Int
    /// Optional stable identity for each flattened node, indexed identically to `nodes`.
    public let blockIDs: [BlockID?]

    /// Parallel array of per-node `.frame()` specs, indexed identically to `nodes`.
    /// `nil` (not an all-`.unspecified` array) whenever no node in the tree was framed —
    /// that is the zero-cost unframed path: no `[FrameSpec]` allocation, and `frame(at:)`
    /// takes a single predicted `nil`-check branch instead of an array bounds check.
    /// Populated by `flatten()` (VelocityUI-dv7) at the wrapped node's index — see
    /// `FrameModifierNode`'s doc comment for why framing folds in rather than becoming
    /// its own `NodeKind`.
    public let frames: [FrameSpec]?

    // Precomputed in init — turns the old O(n) scan in children(of:) into O(k).
    // childIndices is a contiguous array of child node indices grouped by parent.
    // childRanges[i] is the slice in childIndices that holds the children of node i.
    // Insertion order (= DSL child order = z-order) is preserved because buildChildIndex
    // iterates parentIndices in node-index order, which equals DFS pre-order.
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
        blockIDs: [BlockID?]? = nil
    ) {
        self._itemID = AnyHashable(itemID)
        self.nodes = nodes
        self.parentIndices = parentIndices
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
        self.frames = frames
        self.blockIDs = NodeTable.sanitizedBlockIDs(blockIDs, nodeCount: nodes.count)
        (childRanges, childIndices) = NodeTable.buildChildIndex(parentIndices: parentIndices)
    }

    /// Returns the indices of direct children of `nodeIndex` in insertion order.
    /// O(1) slice — no allocation, no linear scan. The backing buffer is shared with childIndices.
    public func children(of nodeIndex: Int) -> ArraySlice<Int> {
        guard nodeIndex >= 0, nodeIndex < childRanges.count else { return [] }
        return childIndices[childRanges[nodeIndex]]
    }

    /// Returns the `.frame()` spec recorded for `i`, or `.unspecified` when this table has
    /// no frames at all (the common unframed case) or `i` is out of bounds. Callers on the
    /// measure path (`measureNode`) branch on `spec.isSpecified` rather than on `frames == nil`
    /// directly so a bounds-safe default reads identically to "never framed".
    public func frame(at i: Int) -> FrameSpec {
        guard let frames, i >= 0, i < frames.count else { return .unspecified }
        return frames[i]
    }

    public func blockID(at i: Int) -> BlockID? {
        guard i >= 0, i < blockIDs.count else { return nil }
        return blockIDs[i]
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
}

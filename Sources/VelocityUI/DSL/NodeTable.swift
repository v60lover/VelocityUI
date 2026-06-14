// NodeTable.swift

import Foundation
import CoreGraphics

// MARK: - Sendable descriptors (Layer 1 → Layer 2 boundary)

/// Sendable font descriptor. Wraps UIFont parameters without importing UIKit
/// into the value-type layer. Converted to UIFont only inside TextMeasurementContext.
public struct VFontDescriptor: Sendable, Hashable {
    public let size: CGFloat
    public let weight: Int  // raw value of UIFont.Weight for Sendable conformance

    public init(size: CGFloat, weight: Int) {
        self.size = size
        self.weight = weight
    }
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

/// layoutHash / appearanceHash default to 0 for hand-constructed test fixtures.
/// flatten() always passes the real values from the corresponding DSL node.
/// Phase 2+ subtree-level classifier will rely on these — do not remove.
public struct VStackDescriptor: Sendable {
    public let alignment: Int  // raw HorizontalAlignment
    public let spacing: CGFloat
    public let layoutHash: Int
    public let appearanceHash: Int

    public init(alignment: Int, spacing: CGFloat, layoutHash: Int = 0, appearanceHash: Int = 0) {
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

    public init(alignment: Int, spacing: CGFloat, layoutHash: Int = 0, appearanceHash: Int = 0) {
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

    public init(alignment: Int, layoutHash: Int = 0, appearanceHash: Int = 0) {
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
    public let layoutHash: Int
    public let appearanceHash: Int
}

public struct ImageDescriptor: Sendable {
    public let url: URL?
    public let aspectRatio: CGFloat?
    public let contentMode: Int  // raw ContentMode
    public let cornerRadius: CGFloat  // decode-time rounding — never set on CALayer
    public let layoutHash: Int
    public let appearanceHash: Int
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

/// Flat, index-based representation of a DSL node tree.
/// Created once on @MainActor from a RenderNode tree; passed by value
/// across all layer boundaries. No existentials past this point.
///
/// itemID is AnyHashable (not `any Hashable & Sendable`) so it participates in
/// Set membership and dictionary keying — required by the differ and cell-recycling layer.
/// AnyHashable is NOT stdlib-Sendable (its box can hold non-Sendable payloads), so the
/// stored property is annotated `nonisolated(unsafe)`. Safety holds because the generic
/// init constrains ID to Hashable & Sendable — the boxed payload is always Sendable in
/// practice. Do not remove the annotation without first making AnyHashable Sendable upstream.
public struct NodeTable: Sendable {
    // See struct-level doc for the full rationale on nonisolated(unsafe) here.
    nonisolated(unsafe) public let itemID: AnyHashable
    public let nodes: [NodeKind]
    public let parentIndices: [Int]  // parentIndices[i] = parent of node i; -1 for root
    public let layoutHash: Int
    public let appearanceHash: Int

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
        appearanceHash: Int
    ) {
        self.itemID = AnyHashable(itemID)
        self.nodes = nodes
        self.parentIndices = parentIndices
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
        (childRanges, childIndices) = NodeTable.buildChildIndex(parentIndices: parentIndices)
    }

    /// Returns the indices of direct children of `nodeIndex` in insertion order.
    /// O(1) slice — no allocation, no linear scan. The backing buffer is shared with childIndices.
    public func children(of nodeIndex: Int) -> ArraySlice<Int> {
        guard nodeIndex >= 0, nodeIndex < childRanges.count else { return [] }
        return childIndices[childRanges[nodeIndex]]
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
}

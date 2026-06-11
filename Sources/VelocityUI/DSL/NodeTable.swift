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

public struct VStackDescriptor: Sendable {
    public let alignment: Int  // raw HorizontalAlignment
    public let spacing: CGFloat
}

public struct HStackDescriptor: Sendable {
    public let alignment: Int  // raw VerticalAlignment
    public let spacing: CGFloat
}

public struct ZStackDescriptor: Sendable {
    public let alignment: Int  // raw Alignment
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
public struct NodeTable: Sendable {
    public let itemID: any Hashable & Sendable
    public let nodes: [NodeKind]
    public let parentIndices: [Int]  // parentIndices[i] = parent of node i; -1 for root
    public let layoutHash: Int
    public let appearanceHash: Int

    public init(
        itemID: any Hashable & Sendable,
        nodes: [NodeKind],
        parentIndices: [Int],
        layoutHash: Int,
        appearanceHash: Int
    ) {
        self.itemID = itemID
        self.nodes = nodes
        self.parentIndices = parentIndices
        self.layoutHash = layoutHash
        self.appearanceHash = appearanceHash
    }

    /// Returns the indices of direct children of nodeIndex.
    public func children(of nodeIndex: Int) -> [Int] {
        var result: [Int] = []
        for (i, parent) in parentIndices.enumerated() where parent == nodeIndex {
            result.append(i)
        }
        return result
    }
}

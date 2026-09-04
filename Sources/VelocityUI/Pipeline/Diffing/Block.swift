// Block.swift

import Foundation
import CoreGraphics

// MARK: - BlockKey

/// Caller-supplied identity for a block, separate from its array index.
/// Lets a block keep its cache identity even when its siblings move.
public struct BlockID: Hashable, Sendable {
    nonisolated(unsafe) public let rawValue: AnyHashable

    public init<ID: Hashable & Sendable>(_ rawValue: ID) {
        self.rawValue = AnyHashable(rawValue)
    }
}

/// Identity for one block: item id + position, or a stable `BlockID` if it has one.
/// Content changes are tracked separately, via `Block.contentHash`.
public struct BlockKey: Hashable, Sendable {
    // See struct-level doc for the nonisolated(unsafe) rationale — identical to NodeTable's.
    nonisolated(unsafe) public let itemID: AnyHashable
    public let index: Int
    public let blockID: BlockID?

    public init<ID: Hashable & Sendable>(itemID: ID, index: Int) {
        self.itemID = AnyHashable(itemID)
        self.index = index
        self.blockID = nil
    }

    /// Same as above but keyed by a stable `BlockID` instead of position.
    /// Two blocks with the same ID in the same item share a key on purpose.
    public init<ID: Hashable & Sendable>(itemID: ID, blockID: BlockID) {
        self.itemID = AnyHashable(itemID)
        self.index = 0
        self.blockID = blockID
    }

    /// Reuses the itemID already boxed by `NodeTable.init`.
    init(boxedItemID: AnyHashable, index: Int, blockID: BlockID? = nil) {
        self.itemID = boxedItemID
        self.index = blockID == nil ? index : 0
        self.blockID = blockID
    }

    public static func == (lhs: BlockKey, rhs: BlockKey) -> Bool {
        guard lhs.itemID == rhs.itemID else { return false }
        switch (lhs.blockID, rhs.blockID) {
        case let (.some(lhs), .some(rhs)): return lhs == rhs
        case (.none, .none): return lhs.index == rhs.index
        case (.some, .none), (.none, .some): return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(itemID)
        if let blockID {
            hasher.combine(1)
            hasher.combine(blockID)
        } else {
            hasher.combine(0)
            hasher.combine(index)
        }
    }
}

// MARK: - Block

/// Whether a block is still growing (`.hot`) or done (`.sealed`).
/// `.positional` is the legacy fallback: only the last block counts as hot.
/// Producers with a stable `BlockID` should use `.sealed`/`.hot` directly, so
/// reordering blocks doesn't change which one is treated as hot.
public enum BlockLifecycle: Sendable, Equatable {
    case sealed
    case hot
    case positional
}

/// Layout input a block contributes before its final frame is resolved.
public enum BlockGeometryPolicy: Sendable {
    case measured
    case aspectRatio(CGFloat)
    case fixed(CGSize)
    case spacer(CGFloat)
}

/// Synchronous geometry for a leaf whose size is fully described without measurement.
struct LeafGeometryResolution: Sendable, Equatable {
    let slotSize: CGSize
    let contentFrame: CGRect
}

/// Resolves geometry for a block whose size doesn't need measurement (fixed, aspect ratio, spacer).
/// Returns `nil` if the block still needs `measureNode`.
nonisolated func resolveLeafGeometry(
    _ policy: BlockGeometryPolicy,
    presentation: BlockPresentationPolicy,
    frame: FrameSpec,
    proposedWidth: CGFloat
) -> LeafGeometryResolution? {
    let measurementWidth = frame.width ?? proposedWidth
    let intrinsic: CGSize
    switch policy {
    case .measured:
        return nil
    case .aspectRatio(let ratio):
        intrinsic = CGSize(width: measurementWidth, height: measurementWidth / ratio)
    case .fixed(let size):
        intrinsic = size
    case .spacer(let height):
        intrinsic = CGSize(width: measurementWidth, height: height)
    }

    guard frame.isSpecified else {
        return LeafGeometryResolution(
            slotSize: intrinsic,
            contentFrame: CGRect(origin: .zero, size: intrinsic)
        )
    }

    let slot = CGSize(
        width: frame.width ?? intrinsic.width,
        height: frame.height ?? intrinsic.height
    )
    let fillsSlot: Bool = {
        guard case .image(let descriptor) = presentation else { return false }
        return descriptor.contentMode == VContentMode.fill.rawValue
    }()
    let content = fillsSlot
        ? slot
        : CGSize(width: min(intrinsic.width, slot.width), height: min(intrinsic.height, slot.height))
    let dx = slot.width - content.width
    let dy = slot.height - content.height

    let x: CGFloat
    switch frame.alignment {
    case .topLeading, .leading, .bottomLeading: x = 0
    case .top, .center, .bottom: x = dx / 2
    case .topTrailing, .trailing, .bottomTrailing: x = dx
    }

    let y: CGFloat
    switch frame.alignment {
    case .topLeading, .top, .topTrailing: y = 0
    case .leading, .center, .trailing: y = dy / 2
    case .bottomLeading, .bottom, .bottomTrailing: y = dy
    }

    return LeafGeometryResolution(
        slotSize: slot,
        contentFrame: CGRect(origin: CGPoint(x: x, y: y), size: content)
    )
}

/// Paint input a block contributes after its frame is resolved.
public enum BlockPresentationPolicy: Sendable {
    case text(TextDescriptor)
    case image(ImageDescriptor)
    case codeBlockBackground(CodeBlockBackgroundDescriptor)
    case table(TableRasterDescriptor)
    case mathBlock(MathBlockRasterDescriptor)
    case geometry

    public var fragmentContent: FragmentContent {
        switch self {
        case .text(let descriptor): .text(descriptor)
        case .image(let descriptor): .image(descriptor)
        case .codeBlockBackground(let descriptor): .codeBlockBackground(descriptor)
        case .table(let descriptor): .table(descriptor)
        case .mathBlock(let descriptor): .mathBlock(descriptor)
        case .geometry: .geometry
        }
    }
}

/// A value-only request for work owned by `RenderEnvironment` collaborators.
public struct BlockContentRequest: Sendable {
    public enum Kind: Sendable {
        case image(ImageDescriptor)
        case gif(GIFDescriptor)
        case video(VideoDescriptor)
    }

    public let key: BlockKey
    public let generation: Int
    public let kind: Kind

    public init(key: BlockKey, generation: Int, kind: Kind) {
        self.key = key
        self.generation = generation
        self.kind = kind
    }
}

/// Async content paired with the block identity and generation that requested it.
public struct BlockContentDelivery<Value: Sendable>: Sendable {
    public let key: BlockKey
    public let generation: Int
    public let value: Value

    public init(key: BlockKey, generation: Int, value: Value) {
        self.key = key
        self.generation = generation
        self.value = value
    }
}

/// Data-only description consumed by the generic block pipeline.
public struct BlockRenderContract: Sendable {
    public let key: BlockKey
    public let lifecycle: BlockLifecycle
    public let geometry: BlockGeometryPolicy
    public let presentation: BlockPresentationPolicy
    public let geometryHash: Int
    public let appearanceHash: Int
    public let contentRequest: BlockContentRequest?

    public init(
        key: BlockKey,
        lifecycle: BlockLifecycle,
        geometry: BlockGeometryPolicy,
        presentation: BlockPresentationPolicy,
        geometryHash: Int,
        appearanceHash: Int,
        contentRequest: BlockContentRequest? = nil
    ) {
        self.key = key
        self.lifecycle = lifecycle
        self.geometry = geometry
        self.presentation = presentation
        self.geometryHash = geometryHash
        self.appearanceHash = appearanceHash
        self.contentRequest = contentRequest
    }
}

/// One block of an item's ordered content. An item is just `[Block]`.
public struct Block: Sendable {
    public let key: BlockKey
    public let blockID: BlockID?
    public let fragment: Fragment
    public let layout: ResolvedLayout
    public let lifecycle: BlockLifecycle

    /// Cheap fingerprint used by `diff(previous:new:)` to detect content changes.
    /// `.geometry` blocks have no content to hash, so they always fingerprint the same —
    /// only their frame can change, which is a layout concern, not a content one.
    public let contentHash: Int

    public let contract: BlockRenderContract

    public init(
        key: BlockKey,
        fragment: Fragment,
        layout: ResolvedLayout,
        lifecycle: BlockLifecycle = .positional
    ) {
        self.key = key
        self.blockID = fragment.blockID
        self.fragment = fragment
        self.layout = layout
        self.lifecycle = lifecycle
        switch fragment.content {
        case .text(let descriptor):
            self.contentHash = Block.combineHash(descriptor.layoutHash, descriptor.appearanceHash)
        case .image(let descriptor):
            self.contentHash = Block.combineHash(descriptor.layoutHash, descriptor.appearanceHash)
        case .table(let descriptor):
            self.contentHash = Block.combineHash(descriptor.layoutHash, descriptor.appearanceHash)
        case .mathBlock(let descriptor):
            self.contentHash = Block.combineHash(descriptor.layoutHash, descriptor.appearanceHash)
        case .codeBlockBackground, .geometry:
            self.contentHash = 0
        }
        self.contract = BlockRenderContract(
            key: key,
            lifecycle: lifecycle,
            geometry: .measured,
            presentation: Block.presentation(for: fragment.content),
            geometryHash: contentHash,
            appearanceHash: 0
        )
    }

    public init(contract: BlockRenderContract, id: Int, frame: CGRect) {
        self.key = contract.key
        self.blockID = contract.key.blockID
        self.fragment = Fragment(id: id, blockID: contract.key.blockID, content: contract.presentation.fragmentContent, frame: frame)
        self.layout = ResolvedLayout(totalFrame: frame)
        self.lifecycle = contract.lifecycle
        self.contentHash = Block.combineHash(contract.geometryHash, contract.appearanceHash)
        self.contract = contract
    }

    /// The block's available width for measurement — the fragment's resolved frame width.
    public var width: CGFloat { fragment.frame.width }

    private static func combineHash(_ a: Int, _ b: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(a)
        hasher.combine(b)
        return hasher.finalize()
    }

    private static func presentation(for content: FragmentContent) -> BlockPresentationPolicy {
        switch content {
        case .text(let descriptor): .text(descriptor)
        case .image(let descriptor): .image(descriptor)
        case .codeBlockBackground(let descriptor): .codeBlockBackground(descriptor)
        case .table(let descriptor): .table(descriptor)
        case .mathBlock(let descriptor): .mathBlock(descriptor)
        case .geometry: .geometry
        }
    }
}

extension Block {
    static func hash<T: Hashable>(_ value: T) -> Int {
        var hasher = Hasher()
        hasher.combine(value)
        return hasher.finalize()
    }

    static func hash<A: Hashable, B: Hashable>(_ first: A, _ second: B) -> Int {
        var hasher = Hasher()
        hasher.combine(first)
        hasher.combine(second)
        return hasher.finalize()
    }
}

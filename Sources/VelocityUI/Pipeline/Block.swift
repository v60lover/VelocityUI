// Block.swift

import Foundation
import CoreGraphics

// MARK: - BlockKey

/// Stable, caller-supplied identity for a render block.
///
/// `BlockID` is separate from node indices: indices continue routing layout and layers, while
/// this value lets a block retain its cache identity when siblings move.
public struct BlockID: Hashable, Sendable {
    nonisolated(unsafe) public let rawValue: AnyHashable

    public init<ID: Hashable & Sendable>(_ rawValue: ID) {
        self.rawValue = AnyHashable(rawValue)
    }
}

/// Stable identity for one block within one item's ordered block list — item id + position.
///
/// `itemID` is `AnyHashable` behind `nonisolated(unsafe)` (mirrors `NodeTable.itemID`): not
/// stdlib-`Sendable`, but the generic `Hashable & Sendable` init is the only place boxing
/// happens, so the payload is always `Sendable` in practice.
///
/// Identifies WHICH block this is, not what it contains — the key persists across a block's
/// lifetime from `.hot` (growing) to `.frozen` (measured). Content equality for diffing is
/// `Block.contentHash`, not part of this key.
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

    /// Uses an explicit stable identity while retaining the positional initializer above for
    /// existing callers. Equal stable IDs within the same item intentionally share a key.
    public init<ID: Hashable & Sendable>(itemID: ID, blockID: BlockID) {
        self.itemID = AnyHashable(itemID)
        self.index = 0
        self.blockID = blockID
    }

    /// Reuses the Sendable payload already validated and boxed by `NodeTable.init`.
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

/// Rendering residency declared by the block producer.
///
/// `.positional` preserves the legacy fallback: only the trailing block is treated as hot.
/// Producers with stable identities should emit `.sealed` or `.hot` directly so moving a block
/// never changes its residency merely because its array index changed.
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

/// Paint input a block contributes after its frame is resolved.
public enum BlockPresentationPolicy: Sendable {
    case text(TextDescriptor)
    case image(ImageDescriptor)
    case geometry

    public var fragmentContent: FragmentContent {
        switch self {
        case .text(let descriptor): .text(descriptor)
        case .image(let descriptor): .image(descriptor)
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

/// One block of an item's ordered content, wrapping existing render vocabulary — no parallel
/// content enum. A bound item is an ordered `[Block]`; lifecycle is declared per block rather
/// than inferred from its position when the producer supports it.
public struct Block: Sendable {
    public let key: BlockKey
    public let blockID: BlockID?
    public let fragment: Fragment
    public let layout: ResolvedLayout
    public let lifecycle: BlockLifecycle

    /// Cheap content-equality fingerprint for `diff(previous:new:)`. Reuses the layout/appearance
    /// hashes the Flattener already computes on `TextDescriptor`/`ImageDescriptor` (the same
    /// hash-first vocabulary `RenderDiffer.classify` uses) instead of inventing a new hashing
    /// scheme. `.geometry` fragments carry no descriptor to hash, so they fingerprint to a fixed
    /// constant — two `.geometry` blocks are always diff-equivalent (their frame, not their
    /// content, is what can change, and frame changes are a layout-provider concern, not this
    /// block-level content diff).
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
        case .geometry:
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
        case .geometry: .geometry
        }
    }
}

public extension NodeTable {
    /// Converts one flattened leaf into the value contract used by block consumers.
    func blockRenderContract<ID: Hashable & Sendable>(
        at index: Int,
        itemID: ID,
        positionalIndex: Int? = nil
    ) -> BlockRenderContract? {
        guard index >= 0, index < nodes.count else { return nil }
        let key = blockID(at: index).map { BlockKey(itemID: itemID, blockID: $0) }
            ?? BlockKey(itemID: itemID, index: positionalIndex ?? index)
        let lifecycle = blockLifecycle(at: index)

        switch nodes[index] {
        case .text(let descriptor):
            return BlockRenderContract(
                key: key, lifecycle: lifecycle, geometry: .measured, presentation: .text(descriptor),
                geometryHash: descriptor.layoutHash, appearanceHash: descriptor.appearanceHash
            )
        case .image(let descriptor):
            let generation = Block.hash(descriptor.layoutHash, descriptor.appearanceHash)
            let request = descriptor.url.map { _ in
                BlockContentRequest(key: key, generation: generation, kind: .image(descriptor))
            }
            return BlockRenderContract(
                key: key,
                lifecycle: lifecycle,
                geometry: descriptor.aspectRatio.map(BlockGeometryPolicy.aspectRatio) ?? .measured,
                presentation: .image(descriptor),
                geometryHash: descriptor.layoutHash, appearanceHash: descriptor.appearanceHash,
                contentRequest: request
            )
        case .spacer(let length):
            return BlockRenderContract(
                key: key, lifecycle: lifecycle, geometry: .spacer(length), presentation: .geometry,
                geometryHash: Block.hash(length), appearanceHash: 0
            )
        case .hosting(let descriptor):
            return BlockRenderContract(
                key: key, lifecycle: lifecycle, geometry: .fixed(descriptor.size), presentation: .geometry,
                geometryHash: descriptor.layoutHash, appearanceHash: descriptor.appearanceHash
            )
        case .gif(let descriptor):
            let generation = Block.hash(descriptor.layoutHash, descriptor.appearanceHash)
            let request = descriptor.url.map { _ in
                BlockContentRequest(key: key, generation: generation, kind: .gif(descriptor))
            }
            return BlockRenderContract(
                key: key, lifecycle: lifecycle, geometry: .measured, presentation: .geometry,
                geometryHash: descriptor.layoutHash, appearanceHash: descriptor.appearanceHash,
                contentRequest: request
            )
        case .video(let descriptor):
            let generation = Block.hash(descriptor.layoutHash, descriptor.appearanceHash)
            let request = descriptor.url.map { _ in
                BlockContentRequest(key: key, generation: generation, kind: .video(descriptor))
            }
            return BlockRenderContract(
                key: key, lifecycle: lifecycle, geometry: .measured, presentation: .geometry,
                geometryHash: descriptor.layoutHash, appearanceHash: descriptor.appearanceHash,
                contentRequest: request
            )
        case .customLayer(let size):
            return BlockRenderContract(
                key: key, lifecycle: lifecycle, geometry: .fixed(size), presentation: .geometry,
                geometryHash: Block.hash(size.width, size.height), appearanceHash: 0
            )
        case .vstack, .hstack, .zstack:
            return nil
        }
    }

    func isBlockLeaf(at index: Int) -> Bool {
        guard index >= 0, index < nodes.count else { return false }
        return switch nodes[index] {
        case .text, .image, .spacer, .hosting, .gif, .video, .customLayer: true
        case .vstack, .hstack, .zstack: false
        }
    }
}

private extension Block {
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

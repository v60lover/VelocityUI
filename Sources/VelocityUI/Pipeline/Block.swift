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

/// One block of an item's ordered content, wrapping existing render vocabulary — no parallel
/// content enum. A bound item is an ordered `[Block]`; while streaming, every block except the
/// last is complete and frozen, and the last (`hot`) block may still grow.
public struct Block: Sendable {
    public let key: BlockKey
    public let blockID: BlockID?
    public let fragment: Fragment
    public let layout: ResolvedLayout

    /// Cheap content-equality fingerprint for `diff(previous:new:)`. Reuses the layout/appearance
    /// hashes the Flattener already computes on `TextDescriptor`/`ImageDescriptor` (the same
    /// hash-first vocabulary `RenderDiffer.classify` uses) instead of inventing a new hashing
    /// scheme. `.geometry` fragments carry no descriptor to hash, so they fingerprint to a fixed
    /// constant — two `.geometry` blocks are always diff-equivalent (their frame, not their
    /// content, is what can change, and frame changes are a layout-provider concern, not this
    /// block-level content diff).
    public let contentHash: Int

    public init(key: BlockKey, fragment: Fragment, layout: ResolvedLayout) {
        self.key = key
        self.blockID = fragment.blockID
        self.fragment = fragment
        self.layout = layout
        switch fragment.content {
        case .text(let descriptor):
            self.contentHash = Block.combineHash(descriptor.layoutHash, descriptor.appearanceHash)
        case .image(let descriptor):
            self.contentHash = Block.combineHash(descriptor.layoutHash, descriptor.appearanceHash)
        case .geometry:
            self.contentHash = 0
        }
    }

    /// The block's available width for measurement — the fragment's resolved frame width.
    public var width: CGFloat { fragment.frame.width }

    private static func combineHash(_ a: Int, _ b: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(a)
        hasher.combine(b)
        return hasher.finalize()
    }
}

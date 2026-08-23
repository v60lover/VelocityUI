// BlockDiff.swift

import Foundation

/// One surviving block's old and new positions.
public struct BlockMatch: Sendable, Equatable {
    public let previousIndex: Int
    public let newIndex: Int

    public init(previousIndex: Int, newIndex: Int) {
        self.previousIndex = previousIndex
        self.newIndex = newIndex
    }
}

/// Minimal-update description of how one item's block list changed.
/// With unique `BlockID`s, blocks are matched by identity (so moves/reuse are detected).
/// If IDs are missing or duplicated, falls back to a conservative positional comparison.
public struct BlockDiff: Sendable, Equatable {
    public let reused: [BlockMatch]
    public let moved: [BlockMatch]
    public let updated: [Int]
    public let inserted: [Int]
    public let removed: [BlockKey]
    /// Exact hot indices from explicit lifecycle metadata.
    public let hot: Set<Int>
    /// Legacy contiguous envelope of `hot`; new consumers must use `hot`.
    public let volatile: Range<Int>

    public init(
        reused: [BlockMatch],
        moved: [BlockMatch],
        updated: [Int],
        inserted: [Int],
        removed: [BlockKey],
        hot: Set<Int>,
        volatile: Range<Int>
    ) {
        self.reused = reused
        self.moved = moved
        self.updated = updated
        self.inserted = inserted
        self.removed = removed
        self.hot = hot
        self.volatile = volatile
    }

    /// Compatibility projection for callers that only distinguish same-position reuse.
    public var unchanged: [Int] { reused.map(\.newIndex) }

    /// Compatibility projection for sealed updates and inserts.
    public var sealedChanged: [Int] {
        (updated + inserted).filter { !hot.contains($0) }
    }
}

/// Pure identity-aware diff. It never measures, rasterizes, or mutates caches.
public nonisolated func diff(previous: [Block], new: [Block]) -> BlockDiff {
    diff(previous: previous, new: new, positionalFrontier: nil)
}

/// Compatibility entry point for producers that still expose a sealed-prefix frontier.
public nonisolated func diff(previous: [Block], new: [Block], frontier: Int) -> BlockDiff {
    diff(previous: previous, new: new, positionalFrontier: frontier)
}

private nonisolated func diff(
    previous: [Block], new: [Block], positionalFrontier: Int?
) -> BlockDiff {
    let hot = hotIndices(in: new, positionalFrontier: positionalFrontier)
    let volatile = volatileEnvelope(for: hot, count: new.count)
    guard let previousByID = uniqueBlocksByID(previous), uniqueBlocksByID(new) != nil else {
        // An explicit hot set still wins even without full identity. Otherwise fall back
        // to treating the trailing block as hot.
        let fallbackHot = positionalFrontier == nil && hot.isEmpty && !new.isEmpty
            ? Set([new.count - 1])
            : hot
        return positionalDiff(previous: previous, new: new, hot: fallbackHot)
    }

    var reused: [BlockMatch] = []
    var moved: [BlockMatch] = []
    var updated: [Int] = []
    var inserted: [Int] = []
    var retainedIDs = Set<BlockID>()
    reused.reserveCapacity(new.count)

    for (newIndex, block) in new.enumerated() {
        let id = block.blockID!
        guard let previousMatch = previousByID[id] else {
            inserted.append(newIndex)
            continue
        }
        retainedIDs.insert(id)
        if previousMatch.block.contentHash == block.contentHash {
            let match = BlockMatch(previousIndex: previousMatch.index, newIndex: newIndex)
            if previousMatch.index == newIndex {
                reused.append(match)
            } else {
                moved.append(match)
            }
        } else {
            updated.append(newIndex)
        }
    }

    let removed = previousByID.compactMap { id, match in retainedIDs.contains(id) ? nil : match.block.key }
    return BlockDiff(
        reused: reused, moved: moved, updated: updated, inserted: inserted, removed: removed,
        hot: hot, volatile: volatile
    )
}

private nonisolated func uniqueBlocksByID(_ blocks: [Block]) -> [BlockID: (index: Int, block: Block)]? {
    var result: [BlockID: (index: Int, block: Block)] = [:]
    result.reserveCapacity(blocks.count)
    for (index, block) in blocks.enumerated() {
        guard let id = block.blockID, result[id] == nil else { return nil }
        result[id] = (index, block)
    }
    return result
}

private nonisolated func hotIndices(in blocks: [Block], positionalFrontier: Int?) -> Set<Int> {
    if let positionalFrontier {
        let end = max(0, min(positionalFrontier, blocks.count))
        return Set(end..<blocks.count)
    }
    let explicitHot = Set(blocks.indices.filter { blocks[$0].lifecycle == .hot })
    if !explicitHot.isEmpty { return explicitHot }
    guard blocks.allSatisfy({ $0.lifecycle != .sealed }), !blocks.isEmpty else {
        return []
    }
    return [blocks.count - 1]
}

private nonisolated func volatileEnvelope(for hot: Set<Int>, count: Int) -> Range<Int> {
    guard let first = hot.min(), let last = hot.max() else { return count..<count }
    return first..<(last + 1)
}

private nonisolated func positionalDiff(previous: [Block], new: [Block], hot: Set<Int>) -> BlockDiff {
    let volatile = volatileEnvelope(for: hot, count: new.count)
    var reused: [BlockMatch] = []
    var changed: [Int] = []
    for index in new.indices where !hot.contains(index) {
        if index < previous.count,
           previous[index].key == new[index].key,
           previous[index].contentHash == new[index].contentHash {
            reused.append(BlockMatch(previousIndex: index, newIndex: index))
        } else {
            changed.append(index)
        }
    }
    return BlockDiff(
        reused: reused, moved: [], updated: changed, inserted: [], removed: [],
        hot: Set(volatile), volatile: volatile
    )
}

// NodeTable+Streaming.swift

import Foundation

extension NodeTable {
    /// Replaces a flat root's changed suffix. The old prefix's descriptors and hashes are
    /// copied as values; only the supplied suffix crosses the DSL flattening boundary.
    @MainActor
    func replacingStreamingSuffix<ID: Hashable & Sendable>(
        revision: UInt64,
        startBlock: Int,
        blocks: [any RenderNode],
        itemID: ID,
        contentSizeCategory: VContentSizeCategory
    ) -> NodeTable? {
        guard !nodes.isEmpty, case .vstack(let root) = nodes[0] else { return nil }
        let children = children(of: 0)
        guard children.count == nodes.count - 1,
              startBlock >= 0, startBlock <= children.count,
              children.allSatisfy({ isBlockLeaf(at: $0) }) else { return nil }

        let suffix = flatten(
            VStackNode(alignment: .leading, spacing: root.spacing) { blocks },
            itemID: itemID, contentSizeCategory: contentSizeCategory
        )
        guard case .vstack = suffix.nodes[0],
              suffix.children(of: 0).count == suffix.nodes.count - 1 else { return nil }

        let keep = startBlock + 1
        var hash = Hasher()
        hash.combine(layoutHash)
        hash.combine(revision)
        let nextHash = hash.finalize()
        let nextRoot = VStackDescriptor(
            alignment: root.alignment, spacing: root.spacing,
            layoutHash: nextHash, appearanceHash: root.appearanceHash
        )
        let nextNodes = [.vstack(nextRoot)] + nodes[1..<keep] + suffix.nodes.dropFirst()
        let nextParents = [-1] + parentIndices[1..<keep] + suffix.parentIndices.dropFirst()
        let nextBlockIDs = [blockIDs[0]] + blockIDs[1..<keep] + suffix.blockIDs.dropFirst()
        let nextLifecycles = [blockLifecycles[0]] + blockLifecycles[1..<keep] + suffix.blockLifecycles.dropFirst()
        let nextActionIDs = [actionIDs[0]] + actionIDs[1..<keep] + suffix.actionIDs.dropFirst()
        let nextFrames: [FrameSpec]?
        if let oldFrames = frames ?? (suffix.frames == nil ? nil : [FrameSpec](repeating: .unspecified, count: nodes.count)) {
            let addedFrames = suffix.frames ?? [FrameSpec](repeating: .unspecified, count: suffix.nodes.count)
            nextFrames = Array(oldFrames[..<keep]) + addedFrames.dropFirst()
        } else {
            nextFrames = nil
        }
        return NodeTable(
            itemID: itemID, nodes: nextNodes, parentIndices: nextParents,
            layoutHash: nextHash, appearanceHash: appearanceHash,
            frames: nextFrames, blockIDs: nextBlockIDs,
            blockLifecycles: nextLifecycles, actionIDs: nextActionIDs
        )
    }
}

// FeedScrollView+Document.swift

#if canImport(UIKit)
import UIKit

extension FeedScrollView {
    func evictChangedDocumentRasters(
        previousTable: NodeTable, newTable: NodeTable, itemID: Item.ID, startBlock: Int
    ) -> Bool {
        guard startBlock >= 0,
              case .vstack = previousTable.nodes.first,
              case .vstack = newTable.nodes.first,
              previousTable.children(of: 0).count == previousTable.nodes.count - 1,
              newTable.children(of: 0).count == newTable.nodes.count - 1 else { return false }

        let firstNode = startBlock + 1
        guard firstNode <= previousTable.nodes.count,
              firstNode <= newTable.nodes.count else { return false }
        var newHashes: [BlockKey: Int] = [:]
        for index in firstNode..<newTable.nodes.count {
            guard let contract = newTable.blockRenderContract(
                at: index, itemID: itemID, logicalOrdinal: index - 1
            ) else { return false }
            let block = Block(
                contract: contract, id: index,
                frame: CGRect(x: 0, y: 0, width: 0, height: 0)
            )
            newHashes[block.key] = block.contentHash
        }
        var stale: Set<BlockKey> = []
        for index in firstNode..<previousTable.nodes.count {
            guard let contract = previousTable.blockRenderContract(
                at: index, itemID: itemID, logicalOrdinal: index - 1
            ) else { return false }
            if case .table = previousTable.nodes[index] { continue }
            let block = Block(
                contract: contract, id: index,
                frame: CGRect(x: 0, y: 0, width: 0, height: 0)
            )
            if newHashes[block.key] != block.contentHash {
                stale.insert(block.key)
                if case .codeBlock = previousTable.nodes[index] {
                    stale.insert(BlockKey(
                        itemID: itemID,
                        blockID: codePartID(owner: block.blockID, nodeIndex: index, part: .codeHeader)
                    ))
                    stale.insert(BlockKey(
                        itemID: itemID,
                        blockID: codePartID(owner: block.blockID, nodeIndex: index, part: .codeBody)
                    ))
                }
            }
        }
        if !stale.isEmpty { environment.visibleBlockStore.evict(stale) }
        return true
    }
}
#endif

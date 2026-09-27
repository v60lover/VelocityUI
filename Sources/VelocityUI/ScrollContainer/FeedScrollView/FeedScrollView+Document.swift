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

    func applyRetainedHotTableTail<ID: Hashable & Sendable>(
        previousTable: NodeTable, previousFragments: [Fragment],
        newTable: NodeTable, itemID: ID, changedStart: Int,
        width: CGFloat, scale: CGFloat,
        onDelivery: @MainActor @escaping (HotTableRenderResult, Bool) -> Void
    ) -> (height: CGFloat, fragments: [Fragment], textBitmaps: [Int: CGImage], codeBodyContents: [Int: CodeBodyLayerContent])? {
        guard previousTable.nodes.count == newTable.nodes.count,
              newTable.nodes.count > 1,
              changedStart == newTable.nodes.count - 2,
              case .vstack = previousTable.nodes[0], case .vstack = newTable.nodes[0],
              previousTable.children(of: 0).count == previousTable.nodes.count - 1,
              newTable.children(of: 0).count == newTable.nodes.count - 1 else { return nil }

        let nodeIndex = newTable.nodes.count - 1
        guard case .table = previousTable.nodes[nodeIndex],
              case .table(let descriptor) = newTable.nodes[nodeIndex],
              newTable.blockLifecycle(at: nodeIndex) == .hot,
              previousTable.blockID(at: nodeIndex) == newTable.blockID(at: nodeIndex),
              let prior = previousFragments.last, prior.id == nodeIndex,
              let contract = newTable.blockRenderContract(
                  at: nodeIndex, itemID: itemID, logicalOrdinal: nodeIndex - 1
              ) else { return nil }

        environment.hotTableRasterizerStore.submit(
            HotTableRenderSnapshot(
                key: contract.key, generation: 0, descriptor: descriptor,
                width: width, scale: scale, isFinal: false
            ),
            renderer: { [formulaCache = environment.formulaCache, fontProvider = environment.mathFontProvider] snapshot, state in
                rasterizeHotTable(snapshot, state: state, formulaCache: formulaCache, fontProvider: fontProvider)
            },
            onDelivery: onDelivery,
            observer: environment.rasterDiagnosticsObserver
        )
        return (prior.frame.maxY, previousFragments, [:], [:])
    }

    func applyRetainedHotTextTail<ID: Hashable & Sendable>(
        previousTable: NodeTable, previousFragments: [Fragment],
        newTable: NodeTable, itemID: ID, changedStart: Int,
        width: CGFloat, scale: CGFloat
    ) -> (height: CGFloat, fragments: [Fragment], textBitmaps: [Int: CGImage], codeBodyContents: [Int: CodeBodyLayerContent])? {
        guard environment.hotBlockRasterizeEnabled,
              previousTable.nodes.count == newTable.nodes.count,
              newTable.nodes.count > 1,
              changedStart == newTable.nodes.count - 2,
              case .vstack = previousTable.nodes[0], case .vstack = newTable.nodes[0],
              previousTable.children(of: 0).count == previousTable.nodes.count - 1,
              newTable.children(of: 0).count == newTable.nodes.count - 1,
              !newTable.frame(at: 0).isSpecified else { return nil }

        let nodeIndex = newTable.nodes.count - 1
        guard case .text = previousTable.nodes[nodeIndex],
              case .text(let descriptor) = newTable.nodes[nodeIndex],
              descriptor.codeBlockRole == nil,
              newTable.blockLifecycle(at: nodeIndex) == .hot,
              previousTable.blockID(at: nodeIndex) == newTable.blockID(at: nodeIndex),
              !newTable.frame(at: nodeIndex).isSpecified,
              let prior = previousFragments.last,
              prior.id == nodeIndex,
              let contract = newTable.blockRenderContract(
                  at: nodeIndex, itemID: itemID, logicalOrdinal: nodeIndex - 1
              ) else { return nil }

        let block = Block(
            contract: contract, id: nodeIndex,
            frame: CGRect(x: 0, y: 0, width: width, height: 0)
        )
        let result = environment.hotBlockRasterizerStore.append(
            descriptor, width: width, scale: scale, contentHash: block.contentHash,
            for: block.key, formulaCache: environment.formulaCache,
            fontProvider: environment.mathFontProvider,
            observer: environment.rasterDiagnosticsObserver
        )
        if let image = result.image {
            environment.visibleBlockStore.store(
                image, size: CGSize(width: width, height: result.height), for: block.key
            )
        }
        let frameWidth = result.image.map { CGFloat($0.width) / scale } ?? width
        let frame = CGRect(
            x: prior.frame.minX, y: prior.frame.minY,
            width: frameWidth, height: result.height
        )
        var fragments = previousFragments
        fragments[fragments.count - 1] = Fragment(
            id: nodeIndex, blockID: block.blockID, content: .text(descriptor), frame: frame
        )
        let height = prior.frame.minY + result.height
        let bitmaps = result.image.map { [nodeIndex: $0] } ?? [:]
        return (height, fragments, bitmaps, [:])
    }
}
#endif

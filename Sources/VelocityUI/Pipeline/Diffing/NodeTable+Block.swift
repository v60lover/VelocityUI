// NodeTable+Block.swift

import Foundation

public extension NodeTable {
    func blockRenderContract<ID: Hashable & Sendable>(at index: Int, itemID: ID, positionalIndex: Int? = nil) -> BlockRenderContract? {
        guard index >= 0, index < nodes.count else { return nil }
        let key = blockID(at: index).map { BlockKey(itemID: itemID, blockID: $0) } ?? BlockKey(itemID: itemID, index: positionalIndex ?? index)
        let lifecycle = blockLifecycle(at: index)
        switch nodes[index] {
        case .text(let d): return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .measured, presentation: .text(d), geometryHash: d.layoutHash, appearanceHash: d.appearanceHash)
        case .codeBlock(let d): return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .measured, presentation: .text(d.bodyText), geometryHash: d.layoutHash, appearanceHash: d.appearanceHash)
        case .image(let d):
            let generation = Block.hash(d.layoutHash, d.appearanceHash)
            return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: d.aspectRatio.map(BlockGeometryPolicy.aspectRatio) ?? .measured, presentation: .image(d), geometryHash: d.layoutHash, appearanceHash: d.appearanceHash, contentRequest: d.url.map { _ in BlockContentRequest(key: key, generation: generation, kind: .image(d)) })
        case .spacer(let length): return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .spacer(length), presentation: .geometry, geometryHash: Block.hash(length), appearanceHash: 0)
        case .hosting(let d): return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .fixed(d.size), presentation: .geometry, geometryHash: d.layoutHash, appearanceHash: d.appearanceHash)
        case .gif(let d):
            let generation = Block.hash(d.layoutHash, d.appearanceHash)
            return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .measured, presentation: .geometry, geometryHash: d.layoutHash, appearanceHash: d.appearanceHash, contentRequest: d.url.map { _ in BlockContentRequest(key: key, generation: generation, kind: .gif(d)) })
        case .video(let d):
            let generation = Block.hash(d.layoutHash, d.appearanceHash)
            return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .measured, presentation: .geometry, geometryHash: d.layoutHash, appearanceHash: d.appearanceHash, contentRequest: d.url.map { _ in BlockContentRequest(key: key, generation: generation, kind: .video(d)) })
        case .customLayer(let size): return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .fixed(size), presentation: .geometry, geometryHash: Block.hash(size.width, size.height), appearanceHash: 0)
        // Rasterization/mounting (VelocityUI-8ge8.6) isn't wired in yet — same geometry-only
        // placeholder presentation as .gif/.video before their content pipelines land.
        case .table(let d): return BlockRenderContract(key: key, lifecycle: lifecycle, geometry: .measured, presentation: .geometry, geometryHash: d.layoutHash, appearanceHash: d.appearanceHash)
        case .vstack, .hstack, .zstack: return nil
        }
    }

    func isBlockLeaf(at index: Int) -> Bool {
        guard index >= 0, index < nodes.count else { return false }
        switch nodes[index] {
        case .text, .codeBlock, .image, .spacer, .hosting, .gif, .video, .customLayer, .table: return true
        case .vstack, .hstack, .zstack: return false
        }
    }
}

/// Stable invalidation fingerprint for one code-card paint part.
func codeBlockRenderPartHash(_ descriptor: CodeBlockDescriptor, part: RenderPartKind) -> Int {
    var hasher = Hasher()
    hasher.combine(part)
    switch part {
    case .codeBackground:
        hasher.combine(descriptor.chrome.cornerRadius)
        hasher.combine(descriptor.chrome.backgroundColor)
    case .codeHeader:
        hasher.combine(descriptor.language)
        hasher.combine(descriptor.headerFont)
    case .codeBody:
        hasher.combine(descriptor.rawCode)
        hasher.combine(descriptor.font)
        hasher.combine(descriptor.language)
    }
    return hasher.finalize()
}

// StreamingDeliveryCoordinator.swift

#if canImport(UIKit)
import UIKit

/// Owns per-feed streaming document revisions and, as dependent beads land, the measurement
/// and raster scheduling `FeedScrollView` used to perform inline (VelocityUI-ln1g.5).
///
/// `@MainActor final class`, not `Sendable` -- same shape as `HotTableRasterizerStore` and
/// `HotBlockRasterizerStore`: touched only from `FeedScrollView`'s synchronous MainActor path.
///
/// Does not store a `RenderEnvironment` -- `RenderEnvironment` owns this coordinator via
/// `let streamingDeliveryCoordinator`, so holding one back would be a retain cycle. Methods that
/// need collaborators (raster stores, caches, observers) take `environment` as a parameter.
@MainActor
public final class StreamingDeliveryCoordinator {
    private var revisions: [AnyHashable: UInt64] = [:]

    public init() {}

    /// Records the latest known document revision for an item. Pure observation for now --
    /// dependent beads will use this to decide what to schedule and what to reject as stale.
    public func noteDocumentRevision<ID: Hashable & Sendable>(itemID: ID, revision: UInt64) {
        revisions[AnyHashable(itemID)] = revision
    }

    /// Relocated from `FeedScrollView.applyRetainedHotTableTail` (VelocityUI-ln1g.5.2) --
    /// behavior, guards, and call sites are unchanged, only the host type moved.
    func applyRetainedHotTableTail<ID: Hashable & Sendable>(
        environment: RenderEnvironment,
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

    /// Relocated from `FeedScrollView.applyRetainedHotTextTail` (VelocityUI-ln1g.5.2) --
    /// behavior, guards, and call sites are unchanged, only the host type moved.
    func applyRetainedHotTextTail<ID: Hashable & Sendable>(
        environment: RenderEnvironment,
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

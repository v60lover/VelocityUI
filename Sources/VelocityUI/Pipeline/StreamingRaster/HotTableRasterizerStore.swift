// HotTableRasterizerStore.swift

#if canImport(UIKit)
import CoreGraphics
import UIKit
import SwaTex
import SwaTexRender

/// One complete table-render request. A table needs a full solve because each new row can alter
/// every column width; the store bounds how many such requests can be live for one block key.
struct HotTableRenderSnapshot: Sendable {
    let key: BlockKey
    let generation: Int
    let descriptor: MarkdownTableDescriptor
    let width: CGFloat
    let scale: CGFloat
    let isFinal: Bool
}

/// Immutable pixels and natural geometry produced for a hot table snapshot.
struct HotTableRenderResult: @unchecked Sendable {
    let key: BlockKey
    let generation: Int
    let image: CGImage
    let size: CGSize
}

/// Performs the same solve/layout/raster sequence as the cold table path, off MainActor.
nonisolated func rasterizeHotTable(_ snapshot: HotTableRenderSnapshot,
                                   formulaCache: FormulaCache?,
                                   fontProvider: KaTeXFontProvider?) -> HotTableRenderResult? {
    let measure: TextMeasure = { descriptor, width in
        TextMeasurementContext().measure(descriptor, width: width, formulaCache: formulaCache)
    }
    let padding = TableCellPadding.default
    let solution = solveColumnWidths(
        cells: snapshot.descriptor.cells, availableWidth: snapshot.width, measure: measure, padding: padding
    )
    let layout = layoutTableCells(
        cells: snapshot.descriptor.cells, columnWidths: solution.widths,
        alignments: snapshot.descriptor.alignments, measure: measure, padding: padding
    )
    let raster = rasterizeTable(
        layout: layout, gridColor: .tableGridLine, backgroundColor: .codeBlockBackground,
        padding: padding, scale: snapshot.scale, formulaCache: formulaCache, fontProvider: fontProvider
    )
    guard let image = raster.image else { return nil }
    return HotTableRenderResult(
        key: snapshot.key, generation: snapshot.generation, image: image, size: raster.size
    )
}

/// Per-feed, per-`BlockKey` scheduler for a growing table. It permits one active full render and
/// one replaceable pending snapshot, so stream updates cannot cancel every CPU-bound table solve.
@MainActor
public final class HotTableRasterizerStore {
    typealias Renderer = @Sendable (HotTableRenderSnapshot) async -> HotTableRenderResult?
    typealias Delivery = @MainActor @Sendable (HotTableRenderResult, Bool) -> Void

    private struct Request: Sendable {
        let snapshot: HotTableRenderSnapshot
        let renderer: Renderer
        let delivery: Delivery
    }

    private struct Entry {
        var activeTask: Task<Void, Never>?
        var activeTicket: Int?
        var pending: Request?
        var lastDeliveredGeneration = Int.min
        var nextGeneration = 0
    }

    private var entries: [BlockKey: Entry] = [:]
    private var nextTicket = 0

    public init() {}

    /// Replaces only pending work. The active render is intentionally allowed to finish, which
    /// guarantees a progressive paint even when a token stream never pauses between versions.
    func submit(_ snapshot: HotTableRenderSnapshot, renderer: @escaping Renderer,
                onDelivery: @escaping Delivery) {
        var entry = entries[snapshot.key] ?? Entry()
        entry.nextGeneration += 1
        let snapshot = HotTableRenderSnapshot(
            key: snapshot.key, generation: entry.nextGeneration, descriptor: snapshot.descriptor,
            width: snapshot.width, scale: snapshot.scale, isFinal: snapshot.isFinal
        )
        let request = Request(snapshot: snapshot, renderer: renderer, delivery: onDelivery)
        if entry.activeTask != nil {
            entry.pending = request
            entries[snapshot.key] = entry
            return
        }
        entries[snapshot.key] = entry
        start(request)
    }

    /// Cancels active work and releases the replaceable pending snapshot and retained closures.
    func evict(_ keys: Set<BlockKey>) {
        for key in keys {
            entries.removeValue(forKey: key)?.activeTask?.cancel()
        }
    }

    private func start(_ request: Request) {
        nextTicket += 1
        let ticket = nextTicket
        var entry = entries[request.snapshot.key] ?? Entry()
        entry.activeTicket = ticket
        entry.activeTask = Task.detached { [weak self, renderer = request.renderer, snapshot = request.snapshot] in
            let result = await renderer(snapshot)
            guard !Task.isCancelled else { return }
            await self?.complete(result, for: request, ticket: ticket)
        }
        entries[request.snapshot.key] = entry
    }

    private func complete(_ result: HotTableRenderResult?, for request: Request, ticket: Int) {
        let key = request.snapshot.key
        guard var entry = entries[key], entry.activeTicket == ticket else { return }
        entry.activeTask = nil
        entry.activeTicket = nil

        if let result, result.generation > entry.lastDeliveredGeneration {
            entry.lastDeliveredGeneration = result.generation
            request.delivery(result, request.snapshot.isFinal)
        }

        if let pending = entry.pending {
            entry.pending = nil
            entries[key] = entry
            start(pending)
        } else if request.snapshot.isFinal {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
    }
}
#endif

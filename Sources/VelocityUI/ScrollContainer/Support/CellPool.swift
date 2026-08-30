// CellPool.swift

#if canImport(UIKit)
import UIKit

/// Owns cell recycling for `FeedScrollView`: dequeues a pooled `RenderCell` or allocates a new
/// one, and returns cells to their kind's pool on recycle. `@MainActor`, no locking — touched
/// only from the synchronous scroll path, same as `HotBlockRasterizerStore`/`VisibleBlockStore`.
@MainActor
final class CellPool {
    private let placeholderRenderer: any PlaceholderRenderer
    private var pools: [CellKind: [RenderCell]] = [:]

    /// Counts `dequeue(kind:)` calls that fell through to `RenderCell(kind:)` (a pool miss, the
    /// sole alloc site). Verifies the cell pool converges after warm-up instead of missing on
    /// most dequeues every frame.
    private(set) var dequeueAllocCount = 0

    /// Counts `dequeue(kind:)` calls served from `pools` (a pool hit — no allocation).
    private(set) var dequeueHitCount = 0

    /// Counts `returnToPool(_:)` calls — a cell's shell handed back to `pools` rather than kept
    /// bound in `visibleCells`. A same-id streaming update must NOT increment this (the
    /// `.inPlace` branch keeps the shell); a different-id replacement or scroll eviction does.
    private(set) var returnToPoolCount = 0

    init(placeholderRenderer: any PlaceholderRenderer) {
        self.placeholderRenderer = placeholderRenderer
    }

    /// Returns a cell from the pool, or allocates a new one.
    ///
    /// `pools[kind]?.popLast()` mutates the array in place via the dictionary's `_modify`
    /// accessor — the key is never removed, so a hit never touches the hash table.
    func dequeue(kind: CellKind) -> RenderCell {
        guard let cell = pools[kind]?.popLast() else {
            dequeueAllocCount += 1
            return RenderCell(kind: kind, placeholderRenderer: placeholderRenderer)
        }
        dequeueHitCount += 1
        return cell
    }

    /// Returns a cell to its kind's pool. `subscript(_:default:)` mutates the array in place
    /// via `_modify`, without ever removing/reinserting the key — same shape as `dequeue(kind:)`.
    func returnToPool(_ cell: RenderCell) {
        cell.cancelPendingMedia()
        pools[cell.kind, default: []].append(cell)
        returnToPoolCount += 1
    }
}
#endif

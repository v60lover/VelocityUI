// FeedScrollView+CellPool.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - Cell pool helpers

    /// Returns a cell from the pool, or allocates a new one.
    ///
    /// `cellPools[kind]?.popLast()` mutates the array in place via the dictionary's `_modify`
    /// accessor — the key is never removed, so a hit never touches the hash table.
    func dequeue(kind: CellKind) -> RenderCell {
        guard let cell = cellPools[kind]?.popLast() else {
            _testHooks.dequeueAllocCount += 1
            return RenderCell(kind: kind, placeholderRenderer: environment.placeholderRenderer)
        }
        _testHooks.dequeueHitCount += 1
        return cell
    }

    /// Returns a cell to its kind's pool. `subscript(_:default:)` mutates the array in place
    /// via `_modify`, without ever removing/reinserting the key — same shape as `dequeue(kind:)`.
    func returnToPool(_ cell: RenderCell) {
        cell.cancelPendingMedia()
        cellPools[cell.kind, default: []].append(cell)
        _testHooks.returnToPoolCount += 1
    }
}
#endif

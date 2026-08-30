// FeedScrollView+CellPool.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - Cell pool helpers

    /// Forwards to the owned `cellPool` — see `CellPool.dequeue(kind:)`.
    func dequeue(kind: CellKind) -> RenderCell {
        cellPool.dequeue(kind: kind)
    }

    /// Forwards to the owned `cellPool` — see `CellPool.returnToPool(_:)`.
    func returnToPool(_ cell: RenderCell) {
        cellPool.returnToPool(cell)
    }
}
#endif

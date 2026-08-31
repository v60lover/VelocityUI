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

    /// Forwards to the owned `cellPool` — see `CellPool.returnToPool(_:)`. Every recycle call
    /// site routes through here, so this is also the single choke point for stopping a running
    /// `codeBodyScrollAnimator` animation whose target cell is leaving.
    func returnToPool(_ cell: RenderCell) {
        if codeBodyScrollAnimator.isTarget(cell) {
            codeBodyScrollAnimator.cancelInFlightWork()
        }
        cellPool.returnToPool(cell)
    }
}
#endif

// AsyncSemaphore+TestHooks.swift

#if canImport(UIKit)
import Foundation

#if canImport(XCTest)
extension AsyncSemaphore {
    /// Test-only: number of waiters queued in the given tier — a deterministic anchor tests can poll
    /// on instead of sleeping a fixed duration.
    func _waiterCount(priority: DecodePriority) -> Int {
        waiterTiers[priority.rawValue].count
    }
}
#endif
#endif

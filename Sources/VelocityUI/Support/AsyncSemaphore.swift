// AsyncSemaphore.swift

#if canImport(UIKit)
import Foundation

/// Priority-lane bounded semaphore for Swift concurrency.
///
/// `wait()` acquires a slot; `signal()` releases one.
/// Contended waiters queue into a per-`DecodePriority` FIFO tier; `signal()` wakes the
/// highest-priority (lowest `rawValue`) non-empty tier, FIFO within that tier. Tiers only
/// affect admission ORDER — a slot already held is never preempted or cancelled.
/// Cancellation-safe: `wait()` throws `CancellationError` if the task is cancelled
/// while blocked; the slot is never consumed for a cancelled caller.
public actor AsyncSemaphore {
    private var count: Int
    // Indexed by DecodePriority.rawValue. One FIFO queue per tier; signal() scans tiers
    // low-to-high (visible before ahead before behind) and pops the first non-empty one.
    private var waiterTiers: [[(id: UUID, cont: CheckedContinuation<Void, any Error>)]] =
        Array(repeating: [], count: DecodePriority.allCases.count)
    // Mirrors the total count across all tiers so signal()'s no-waiter branch stays a
    // single Int comparison — no per-tier array probing — matching the pre-priority
    // fast path's cost exactly. An uncontended-round-trip microbenchmark guards this.
    private var totalWaiterCount = 0

    public init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore value must be non-negative")
        self.count = value
    }

    /// Acquire a slot. Returns immediately when count > 0 (fast path — identical cost to a
    /// single-lane semaphore regardless of `priority`; the tiered queue is only touched on
    /// the contended path below).
    /// Blocks in FIFO-within-tier order when count == 0, admitted by tier per `DecodePriority`
    /// ordering. Throws `CancellationError` on cancellation — the slot is not consumed, and
    /// the caller must NOT call `signal()`.
    public func wait(priority: DecodePriority = .visible) async throws {
        try Task.checkCancellation()
        if count > 0 { count -= 1; return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    // Cancellation raced the continuation registration — resolve immediately.
                    cont.resume(throwing: CancellationError())
                } else {
                    waiterTiers[priority.rawValue].append((id: id, cont: cont))
                    totalWaiterCount += 1
                }
            }
        } onCancel: {
            // onCancel fires on an arbitrary thread; hop to the actor to remove safely.
            Task { [id, priority] in await self.cancelWaiter(id: id, priority: priority) }
        }
    }

    /// Release a slot. Wakes the oldest waiter in the highest-priority non-empty tier
    /// (FIFO within that tier), or increments count when no waiters are queued at all
    /// (fast path — single Int comparison, same cost as the pre-priority no-waiter branch).
    public func signal() {
        guard totalWaiterCount > 0 else { count += 1; return }
        for tier in waiterTiers.indices {
            guard let waiter = waiterTiers[tier].first else { continue }
            waiterTiers[tier].removeFirst()
            totalWaiterCount -= 1
            waiter.cont.resume()
            return
        }
    }

    // MARK: - Private

    private func cancelWaiter(id: UUID, priority: DecodePriority) {
        // If signal() already dequeued this waiter, the id is gone — nothing to do.
        guard let idx = waiterTiers[priority.rawValue].firstIndex(where: { $0.id == id }) else { return }
        waiterTiers[priority.rawValue].remove(at: idx).cont.resume(throwing: CancellationError())
        totalWaiterCount -= 1
        // Slot is NOT consumed — the cancelled caller must not signal().
    }

    #if canImport(XCTest)
    /// Test-only: number of waiters currently queued in the given tier. Gives concurrent
    /// tests a deterministic happens-before anchor ("this waiter has reached the queue")
    /// to poll on instead of sleeping a fixed duration.
    func _waiterCount(priority: DecodePriority) -> Int {
        waiterTiers[priority.rawValue].count
    }
    #endif
}

#endif

// AsyncSemaphore.swift

#if canImport(UIKit)
import Foundation

/// Priority-lane bounded semaphore for Swift concurrency. `wait()` acquires a slot,
/// `signal()` releases one.
///
/// Contended waiters queue into a per-`DecodePriority` FIFO tier; `signal()` wakes the
/// highest-priority (lowest `rawValue`) non-empty tier, FIFO within that tier — tiers only
/// affect admission order, a held slot is never preempted. Cancellation-safe: `wait()` throws
/// `CancellationError` if cancelled while blocked, without consuming a slot.
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

    /// Acquires a slot. Returns immediately when count > 0 (fast path — same cost as a
    /// single-lane semaphore regardless of `priority`; the tiered queue is touched only on the
    /// contended path). Blocks in FIFO-within-tier order when count == 0, admitted by
    /// `DecodePriority` tier. Throws `CancellationError` on cancellation — slot not consumed,
    /// caller must NOT call `signal()`.
    ///
    /// - Parameter id: Identity for `elevate(id:to:)` to target this waiter. Defaults to `nil`,
    ///   generating a fresh `UUID()` only on the contended path (the uncontended fast path never
    ///   allocates one). Pass a stable id if a later caller may need to elevate this wait — e.g.
    ///   `ImageActor` tracking a decode's admission record before it reaches this call.
    public func wait(id: UUID? = nil, priority: DecodePriority = .visible) async throws {
        try Task.checkCancellation()
        if count > 0 { count -= 1; return }

        let waiterID = id ?? UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    // Cancellation raced the continuation registration — resolve immediately.
                    cont.resume(throwing: CancellationError())
                } else {
                    waiterTiers[priority.rawValue].append((id: waiterID, cont: cont))
                    totalWaiterCount += 1
                }
            }
        } onCancel: {
            // onCancel fires on an arbitrary thread; hop to the actor to remove safely.
            // Scans all tiers by id (not just `priority`'s) — `elevate(id:to:)` can have moved
            // this waiter to a different tier since it was enqueued above.
            Task { [waiterID] in await self.cancelWaiter(id: waiterID) }
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

    /// Moves a still-queued waiter to a higher-priority tier — used when a later, more urgent
    /// caller joins work an earlier, lower-priority caller already started (e.g. a `.visible`
    /// `image()` call coalescing onto an in-flight `.behind` prefetch).
    ///
    /// Scans only tiers strictly lower-priority than `newPriority`; if `id` is found there, it's
    /// removed and appended to the back of `newPriority`'s FIFO queue. `totalWaiterCount` is
    /// unchanged — this moves between tiers, it doesn't add or remove.
    ///
    /// No-op — safe to call unconditionally — when `id` isn't queued in any lower tier: already
    /// acquired its slot, already completed/cancelled, not yet enqueued (race window noted at
    /// `ImageActor._decode`'s admission read), or already at/above `newPriority`. Never touches
    /// `count` or resumes a continuation — only reorders queued waiters, never admits one.
    public func elevate(id: UUID, to newPriority: DecodePriority) {
        for tier in waiterTiers.indices where tier > newPriority.rawValue {
            guard let idx = waiterTiers[tier].firstIndex(where: { $0.id == id }) else { continue }
            let waiter = waiterTiers[tier].remove(at: idx)
            waiterTiers[newPriority.rawValue].append(waiter)
            return
        }
    }

    // MARK: - Private

    /// Scans every tier by `id` — not just the tier `wait()` originally enqueued into —
    /// because `elevate(id:to:)` may have moved this waiter to a different tier since then.
    /// A tier-hinted lookup would silently miss an elevated waiter's cancellation, leaving it
    /// neither removed nor resumed, in violation of `wait()`'s cancellation contract.
    private func cancelWaiter(id: UUID) {
        for tier in waiterTiers.indices {
            // If signal() already dequeued this waiter, the id is gone from every tier —
            // nothing to do.
            guard let idx = waiterTiers[tier].firstIndex(where: { $0.id == id }) else { continue }
            waiterTiers[tier].remove(at: idx).cont.resume(throwing: CancellationError())
            totalWaiterCount -= 1
            // Slot is NOT consumed — the cancelled caller must not signal().
            return
        }
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

// AsyncSemaphore.swift

#if canImport(UIKit)

/// FIFO bounded semaphore for Swift concurrency.
///
/// `wait()` acquires a slot; `signal()` releases one.
/// Callers are queued in FIFO order — starvation-free under bounded concurrency.
/// Cancellation-safe: `wait()` throws `CancellationError` if the task is cancelled
/// while blocked; the slot is never consumed for a cancelled caller.
public actor AsyncSemaphore {
    private var count: Int
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, any Error>)] = []

    public init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore value must be non-negative")
        self.count = value
    }

    /// Acquire a slot. Returns immediately when count > 0 (fast path).
    /// Blocks in FIFO order when count == 0. Throws `CancellationError` on cancellation —
    /// the slot is not consumed, and the caller must NOT call `signal()`.
    public func wait() async throws {
        try Task.checkCancellation()
        if count > 0 { count -= 1; return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    // Cancellation raced the continuation registration — resolve immediately.
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append((id: id, cont: cont))
                }
            }
        } onCancel: {
            // onCancel fires on an arbitrary thread; hop to the actor to remove safely.
            Task { [id] in await self.cancelWaiter(id: id) }
        }
    }

    /// Release a slot. Wakes the oldest waiting caller (FIFO) or increments count.
    public func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.cont.resume()
        } else {
            count += 1
        }
    }

    // MARK: - Private

    private func cancelWaiter(id: UUID) {
        // If signal() already dequeued this waiter, the id is gone — nothing to do.
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: idx).cont.resume(throwing: CancellationError())
        // Slot is NOT consumed — the cancelled caller must not signal().
    }
}

#endif

// TextMeasurementPool.swift

#if canImport(UIKit)
import Foundation

/// Bounded pool of TextMeasurementContext objects.
/// Capacity = processor count: amortises expensive NSTextLayoutManager alloc
/// while bounding concurrency to avoid memory pressure.
///
/// withContext is nonisolated async: checkout/checkin enter the actor briefly;
/// the body itself runs off-actor so multiple tasks can measure concurrently.
public actor TextMeasurementPool {
    public static let shared = TextMeasurementPool()

    private var available: [TextMeasurementContext]
    private var waiters: [CheckedContinuation<TextMeasurementContext, Never>] = []

    /// Exposed for Test 4 only — do not use in production code.
    public var availableCount: Int { available.count }

    public init(capacity: Int = ProcessInfo.processInfo.processorCount) {
        available = (0..<max(1, capacity)).map { _ in TextMeasurementContext() }
    }

    private func checkout() async -> TextMeasurementContext {
        if let ctx = available.popLast() {
            return ctx
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func checkin(_ context: TextMeasurementContext) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: context)
        } else {
            available.append(context)
        }
    }
}

extension TextMeasurementPool {
    /// Check out a context, run body off-actor, check back in.
    /// body must be @Sendable because it crosses actor boundaries via Task.detached.
    public nonisolated func withContext<T: Sendable>(
        _ body: @escaping @Sendable (TextMeasurementContext) -> T
    ) async -> T {
        let ctx = await checkout()
        // Run body off the pool actor so other tasks can checkout/checkin concurrently.
        let result = await Task.detached { body(ctx) }.value
        await checkin(ctx)
        return result
    }
}
#endif

// AsyncDrain.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

extension XCTestCase {

    /// Cancels `feed`'s in-flight per-cell media Tasks and pipeline prefetch Task via the
    /// existing `cancelInFlightWork()` teardown hook, then busy-yields for up to `timeout`
    /// so those now-cancelled Tasks get real wall-clock time to observe cancellation and
    /// unwind before this test method returns.
    ///
    /// Swift's cooperative thread pool is process-wide — shared by every XCTestCase in the
    /// process — so a Task that is merely *marked* cancelled but hasn't yet reached its next
    /// `Task.isCancelled` checkpoint keeps consuming pool threads after the test that spawned
    /// it has returned, competing with whichever test runs next. Call this at the end of any
    /// test that mounts real (non-nil-URL) image fragments, so straggler work doesn't bleed
    /// into the next test's timeout budget.
    @MainActor
    func drainFeedWork<Item>(_ feed: FeedScrollView<Item>, timeout: Duration = .milliseconds(500)) async {
        feed.cancelInFlightWork()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
}
#endif

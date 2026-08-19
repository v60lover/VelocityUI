// AsyncDrain.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

extension XCTestCase {

    /// Cancels `feed`'s in-flight per-cell media Tasks and pipeline prefetch Task via
    /// `cancelInFlightWork()`, then busy-yields up to `timeout` so those cancelled Tasks get
    /// real wall-clock time to unwind before this method returns.
    ///
    /// Swift's cooperative thread pool is process-wide: a Task merely *marked* cancelled but not
    /// yet at its next `Task.isCancelled` checkpoint keeps consuming pool threads after its test
    /// returns, competing with whatever runs next. Call at the end of any test that mounts real
    /// (non-nil-URL) image fragments, so straggler work doesn't bleed into the next test's
    /// timeout budget.
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

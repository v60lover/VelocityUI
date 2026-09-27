// StreamingMarkdownText+TestHooks.swift

/// Stored test-only observability state for `StreamingMarkdownController`. A plain (non-generic)
/// class rather than an `extension StreamingMarkdownController` member — extensions forbid
/// stored instance properties, but a fresh type declared in this file can hold them, and
/// `StreamingMarkdownController` then holds exactly one reference to it (`_testHooks`).
///
/// Not `#if`-gated: `StreamingMarkdownController`'s production code (the `renderNodes` style-cache
/// miss) references this type directly with no `#if canImport(XCTest)` guard, so the declaration
/// must always compile. The only XCTest-gated part of this test-hook pair is the `extension
/// StreamingMarkdownController` below, which re-exposes this field under its historical
/// `_`-prefixed test-facing name.
final class StreamingMarkdownControllerTestHooks {
    /// Counts `style()` calls from `renderNodes` — a cache hit must not increment it.
    var styleCount = 0
    var handoffBytesCopiedTotal = 0
    /// Raw slice flatten plus the styled content assembled from runs for open blocks.
    var renderBoundaryBytesCopiedTotal = 0
}

#if canImport(XCTest)
extension StreamingMarkdownController {
    var _styleCallCount: Int { _testHooks.styleCount }
    var _handoffBytesCopiedTotal: Int { _testHooks.handoffBytesCopiedTotal }
    var _renderBoundaryBytesCopiedTotal: Int { _testHooks.renderBoundaryBytesCopiedTotal }
}
#endif

// HotBlockRasterizer+TestHooks.swift

#if canImport(UIKit)
import UIKit

/// Stored test-only observability state for `HotBlockRasterizer`. A plain (non-generic) class
/// rather than an `extension HotBlockRasterizer` member — extensions forbid stored instance
/// properties, but a fresh type declared in this file can hold them, and `HotBlockRasterizer`
/// then holds exactly one reference to it (`_testHooks`).
///
/// Not `#if`-gated: `HotBlockRasterizer`'s production code (`append(_:width:scale:)`'s three
/// write sites) references this type directly with no `#if canImport(XCTest)` guard, so the
/// declaration must always compile. The only XCTest-gated part of this test-hook pair is the
/// `extension HotBlockRasterizer` below, which re-exposes this field under its historical
/// `_`-prefixed test-facing name.
final class HotBlockRasterizerTestHooks {
    /// Fragments redrawn by the most recent `append(_:width:scale:)` call. Lets a flatness test
    /// assert this stays constant per token-kind as the block grows.
    var lastRedrawnFragmentCount = 0
}

#if canImport(XCTest)
extension HotBlockRasterizer {
    var _debugLastRedrawnFragmentCount: Int { _testHooks.lastRedrawnFragmentCount }
}
#endif
#endif

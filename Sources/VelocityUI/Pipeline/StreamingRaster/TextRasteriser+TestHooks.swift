// TextRasteriser+TestHooks.swift

#if canImport(UIKit)
import os

/// Bumps once per `rasterizeText` call, from whichever thread calls it -- `rasterizeText` is
/// `nonisolated` and documented thread-safe, so this can't be a plain `nonisolated(unsafe)` var
/// like `RenderCell._debugApplyContentCount` (that one is safe unlocked only because every
/// increment/read is MainActor-serialized; this one isn't). `OSAllocatedUnfairLock` matches the
/// pattern already used by `FrozenBitmapStore`/`VisibleBlockStore` for state touched off the
/// MainActor scroll path. Test-only — production code (`rasterizeText`) increments it
/// unconditionally, with no `#if` at the call site, so the declaration must always compile.
enum TextRasterizeDebugCounter {
    private static let state = OSAllocatedUnfairLock(initialState: 0)

    static var callCount: Int { state.withLock { $0 } }

    static func increment() {
        state.withLock { $0 += 1 }
    }

    static func reset() {
        state.withLock { $0 = 0 }
    }
}
#endif

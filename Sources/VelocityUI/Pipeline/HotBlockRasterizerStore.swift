// HotBlockRasterizerStore.swift

#if canImport(UIKit)
import UIKit

/// Per-`BlockKey` lifecycle owner for `HotBlockRasterizer` (VelocityUI-x4q0).
///
/// Invariant: `FeedScrollView.applyInPlaceBlockDiff` always calls `diff(previous:new:frontier:)`
/// with `frontier == newBlocks.count - 1`, so `volatile` is always the singleton `{trailingIndex}`
/// — at most one live `HotBlockRasterizer` per hot `BlockKey`, safe to build a dictionary-keyed
/// store around instead of a general multi-hot-block design.
///
/// `@MainActor final class`, no `Sendable` — mirrors `VideoController`, not `FrozenBitmapStore`'s
/// lock-guarded pattern: touched ONLY from `FeedScrollView`'s synchronous MainActor scroll-path
/// methods, so `@MainActor` isolation is enough and a lock would be pure overhead. No in-flight
/// coalescing either (unlike `DimensionCache`) — a single synchronous caller has nothing to coalesce.
@MainActor
public final class HotBlockRasterizerStore {
    private struct Entry {
        let rasterizer: HotBlockRasterizer
        var contentHash: Int
    }

    private var entries: [BlockKey: Entry] = [:]

    public init() {}

    /// Appends `descriptor`'s current content to the hot rasterizer owned by `key`, creating one
    /// on first call for that key. Returns the extended height and composited/rasterized image
    /// (see `HotBlockRasterizer.append(_:width:scale:)`).
    func append(_ descriptor: TextDescriptor, width: CGFloat, scale: CGFloat, contentHash: Int, for key: BlockKey) -> (height: CGFloat, image: CGImage?) {
        let rasterizer = entries[key]?.rasterizer ?? HotBlockRasterizer()
        let result = rasterizer.append(descriptor, width: width, scale: scale)
        entries[key] = Entry(rasterizer: rasterizer, contentHash: contentHash)
        return result
    }

    /// Seals `key`'s hot rasterizer: ALWAYS removes the entry, so a stale/mismatched entry never
    /// lingers. Returns the final bitmap only when `expectedContentHash` matches the content last
    /// appended — a mismatch means the block grew further within the same round it closed, and the
    /// caller must fall back to a full re-measure. Once returned, ARC drops the `HotBlockRasterizer`
    /// (and its `HotBlockMeasurer`'s live `NSTextLayoutManager`) — no incremental state leaks into
    /// the sealed cache.
    func finalize(_ key: BlockKey, expectedContentHash: Int) -> (size: CGSize, image: CGImage)? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        guard entry.contentHash == expectedContentHash else { return nil }
        return entry.rasterizer.finish()
    }

    /// Catches the live hot rasterizer for `key` up to `descriptor`'s current content, then seals it
    /// — closes the gap in `finalize`'s doc ("block grew further within the same round it closed"):
    /// once `key` stops being `trailingIndex`, that growth never reaches a separate `append` call.
    /// `append` unconditionally overwrites `contentHash`, so `finalize` below always matches —
    /// reuses the composited bitmap (cheap incremental blit of the new tail) instead of a full
    /// `freeze()`-based re-measure.
    ///
    /// Returns `nil` without appending when `key` has no live entry — nothing hot to catch up, and
    /// spinning up a rasterizer just to tear it down would cost more than falling through to the
    /// caller's full `freeze()`.
    func catchUpAndFinalize(
        _ key: BlockKey, descriptor: TextDescriptor, width: CGFloat, scale: CGFloat, contentHash: Int
    ) -> (size: CGSize, image: CGImage)? {
        guard entries[key] != nil else { return nil }
        _ = append(descriptor, width: width, scale: scale, contentHash: contentHash, for: key)
        return finalize(key, expectedContentHash: contentHash)
    }

    /// Tears down every hot rasterizer for a key that scrolled out of the working range — mirrors
    /// `FrozenBitmapStore.evict(_ keysThatLeft:)`, called at the same sweep site.
    func evict(_ keys: Set<BlockKey>) {
        for key in keys {
            entries.removeValue(forKey: key)
        }
    }
}
#endif

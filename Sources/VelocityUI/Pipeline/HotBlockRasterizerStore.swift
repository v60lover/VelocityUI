// HotBlockRasterizerStore.swift

#if canImport(UIKit)
import UIKit

/// Per-`BlockKey` lifecycle owner for `HotBlockRasterizer` (VelocityUI-x4q0).
///
/// The analytical invariant this store is built around: `FeedScrollView.applyInPlaceBlockDiff`
/// always calls `diff(previous:new:frontier:)` with `frontier == newBlocks.count - 1`, so the
/// `volatile` range is always the singleton `{trailingIndex}` — never more than one hot index
/// per call. That makes "at most one live `HotBlockRasterizer` per hot `BlockKey`" a safe
/// invariant to build a dictionary-keyed store around, rather than a general multi-hot-block
/// design.
///
/// `@MainActor final class`, no `Sendable` conformance — mirrors `VideoController`'s treatment,
/// not `FrozenBitmapStore`'s lock-guarded `Sendable` pattern: this store is touched ONLY from
/// `FeedScrollView`'s synchronous MainActor scroll-path methods (`applyInPlaceBlockDiff`,
/// `updateVisibleCells`), never from a background pipeline path, so `@MainActor` isolation is
/// sufficient and a lock would be pure overhead.
///
/// No in-flight coalescing (unlike `DimensionCache`): there is no concurrency here at all — a
/// single MainActor caller making synchronous calls — so there is nothing to coalesce.
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

    /// Seals `key`'s hot rasterizer: ALWAYS removes the entry (match or mismatch alike), so a
    /// stale/mismatched entry never lingers. Returns the final bitmap only when `expectedContentHash`
    /// matches the content last appended for this key — a mismatch means the block grew further
    /// within the same round it closed, and the caller must fall back to a full re-measure.
    ///
    /// Once this returns, ARC drops the `HotBlockRasterizer` (and its owned `HotBlockMeasurer`'s
    /// live `NSTextLayoutManager`) as soon as no other reference exists — no incremental state
    /// leaks into the sealed cache.
    func finalize(_ key: BlockKey, expectedContentHash: Int) -> (size: CGSize, image: CGImage)? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        guard entry.contentHash == expectedContentHash else { return nil }
        return entry.rasterizer.finish()
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

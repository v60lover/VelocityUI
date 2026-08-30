// HotBlockRasterizerStore.swift

#if canImport(UIKit)
import UIKit

/// Per-`BlockKey` lifecycle owner for `HotBlockRasterizer`. At most one live rasterizer
/// per hot key — only the trailing block is ever hot — so a dictionary-keyed store is
/// enough. `@MainActor`, no locking: touched only from the synchronous scroll path.
@MainActor
public final class HotBlockRasterizerStore {
    private struct Entry {
        let rasterizer: HotBlockRasterizer
        var contentHash: Int
    }

    private var entries: [BlockKey: Entry] = [:]

    public init() {}

    /// Appends `descriptor`'s current content to the hot rasterizer owned by `key`,
    /// creating one on first call for that key.
    func append(_ descriptor: TextDescriptor, width: CGFloat, scale: CGFloat, contentHash: Int, for key: BlockKey) -> (height: CGFloat, image: CGImage?) {
        let rasterizer = entries[key]?.rasterizer ?? HotBlockRasterizer()
        let result = rasterizer.append(descriptor, width: width, scale: scale)
        entries[key] = Entry(rasterizer: rasterizer, contentHash: contentHash)
        return result
    }

    /// Seals `key`'s hot rasterizer: always removes the entry. Returns the final bitmap
    /// only if `expectedContentHash` matches the content last appended — a mismatch means
    /// the block grew further after this round closed, and the caller must fall back to
    /// a full re-measure.
    func finalize(_ key: BlockKey, expectedContentHash: Int) -> (size: CGSize, image: CGImage)? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        guard entry.contentHash == expectedContentHash else { return nil }
        return entry.rasterizer.finish()
    }

    /// Catches the live hot rasterizer for `key` up to `descriptor`'s current content,
    /// then seals it — an incremental blit instead of a full `freeze()` re-measure.
    /// Returns `nil` without appending when `key` has no live entry.
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

import CoreGraphics
import Foundation
import os

/// Per-feed resident storage for blocks currently mounted by `FeedScrollView`.
///
/// Unlike `FrozenBitmapStore`, this store never applies LRU eviction: a visible bitmap may
/// temporarily exceed `targetByteBudget` rather than being dropped and rasterized again on the
/// next streaming token. Leaving blocks are demoted to the evictable frozen cache.
public final class VisibleBlockStore: Sendable {
    private struct Entry: @unchecked Sendable {
        let bitmap: CGImage
        let size: CGSize
        let cost: Int
        let codeBodyIdentity: CodeBodyRasterIdentity?
    }

    private struct State {
        var entries: [BlockKey: Entry] = [:]
        var currentByteTotal = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A tuning signal for diagnostics, not a hard cap. Visible content is allowed to exceed it.
    public let targetByteBudget: Int

    public init(targetByteBudget: Int = 16 * 1024 * 1024) {
        self.targetByteBudget = max(0, targetByteBudget)
    }

    public var currentByteTotal: Int { state.withLock { $0.currentByteTotal } }

    public func bitmap(for key: BlockKey) -> CGImage? { state.withLock { $0.entries[key]?.bitmap } }

    public func size(for key: BlockKey) -> CGSize? { state.withLock { $0.entries[key]?.size } }

    func codeBodyRaster(
        for key: BlockKey,
        identity: CodeBodyRasterIdentity
    ) -> (image: CGImage, size: CGSize)? {
        state.withLock { st in
            guard let entry = st.entries[key], entry.codeBodyIdentity == identity else { return nil }
            return (entry.bitmap, entry.size)
        }
    }

    /// Retains an active artifact. Cost comes from the real bitmap layout, including row padding.
    public func store(_ bitmap: CGImage, size: CGSize, for key: BlockKey) {
        store(bitmap, size: size, for: key, codeBodyIdentity: nil)
    }

    func store(
        _ bitmap: CGImage,
        size: CGSize,
        for key: BlockKey,
        codeBodyIdentity: CodeBodyRasterIdentity?
    ) {
        let entry = Entry(
            bitmap: bitmap,
            size: size,
            cost: Self.cost(of: bitmap),
            codeBodyIdentity: codeBodyIdentity
        )
        state.withLock { st in
            if let old = st.entries.updateValue(entry, forKey: key) {
                st.currentByteTotal -= old.cost
            }
            st.currentByteTotal += entry.cost
        }
    }

    /// Promotes cached artifacts when their blocks enter the mounted range, then removes their
    /// cache copies so only the resident tier owns them.
    public func promote(_ keys: Set<BlockKey>, from cache: FrozenBitmapStore) {
        guard !keys.isEmpty else { return }
        var promoted: Set<BlockKey> = []
        for key in keys {
            guard let artifact = cache.artifact(for: key) else { continue }
            store(
                artifact.image,
                size: artifact.size,
                for: key,
                codeBodyIdentity: artifact.codeBodyIdentity
            )
            promoted.insert(key)
        }
        cache.evict(promoted)
    }

    /// Demotes leaving artifacts to the ordinary LRU cache without rasterizing them again.
    public func demote(_ keys: Set<BlockKey>, to cache: FrozenBitmapStore) {
        guard !keys.isEmpty else { return }
        let entries = state.withLock { st -> [(BlockKey, Entry)] in
            keys.compactMap { key in
                guard let entry = st.entries.removeValue(forKey: key) else { return nil }
                st.currentByteTotal -= entry.cost
                return (key, entry)
            }
        }
        for (key, entry) in entries {
            cache.store(
                entry.bitmap,
                size: entry.size,
                cost: entry.cost,
                for: key,
                codeBodyIdentity: entry.codeBodyIdentity
            )
        }
    }

    public func evict(_ keys: Set<BlockKey>) {
        guard !keys.isEmpty else { return }
        state.withLock { st in
            for key in keys {
                if let entry = st.entries.removeValue(forKey: key) {
                    st.currentByteTotal -= entry.cost
                }
            }
        }
    }

    private static func cost(of bitmap: CGImage) -> Int {
        bitmap.bytesPerRow * bitmap.height
    }
}

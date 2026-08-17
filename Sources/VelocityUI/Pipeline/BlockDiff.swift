// BlockDiff.swift

import Foundation

/// The minimum-update description for a same-item block-list change, split at a caller-supplied
/// frontier `F` (VelocityUI-k8qe generalizes this from the original single-hot-tail model — see
/// `diff(previous:new:frontier:)`'s doc for the sealed/hot contract this encodes):
///
/// - `unchanged` — indices in `new`'s sealed prefix `[0, F)` whose key+contentHash match `previous`
///   at the same index: reuse the cached frozen size+bitmap verbatim, zero recompute.
/// - `sealedChanged` — indices in `[0, F)` that differ from `previous` at that index, or have no
///   `previous` counterpart at all (newly sealed this update): re-measure and freeze/persist
///   exactly once. After that, the SAME index reports `unchanged` on every later diff, because a
///   sealed block's content never changes again (parser contract) — the only legitimate reason an
///   already-sealed index still appears here on a LATER diff is an out-of-model edit to already-
///   frozen content (VelocityUI-socg design note #4, "edit-invalidation"), which this still
///   correctly re-freezes rather than silently serving a stale bitmap.
/// - `volatile` — indices in `[F, new.count)`, the hot region: always fully re-measured this
///   update, NEVER frozen/persisted — freezing content that can still move is the exact hazard the
///   sealed/hot contract exists to prevent.
public struct BlockDiff: Sendable, Equatable {
    public let unchanged: [Int]
    public let sealedChanged: [Int]
    public let volatile: Range<Int>

    public init(unchanged: [Int], sealedChanged: [Int], volatile: Range<Int>) {
        self.unchanged = unchanged
        self.sealedChanged = sealedChanged
        self.volatile = volatile
    }
}

/// Diffs `previous` against `new` for the SAME item id — the in-place path's per-block diff.
/// Pure: performs no measurement or rasterization, only compares `BlockKey`/`contentHash`.
///
/// `frontier` is the count of blocks in `new` that are SEALED — guaranteed (by whichever producer
/// built `new`) to never change boundary, type, or content again. VelocityUI-qc7.1's spike proved
/// this two-tier sealed/hot split is what an incremental markdown parser can promise; a pre-split
/// DSL block list (no parser involved) gets the same guarantee for everything except its own
/// still-growing trailing block, by passing `frontier: new.count - 1`. This reproduces the
/// original single-hot-tail model for every index EXCEPT the trailing one: under the old model a
/// trailing block that happened to match `previous` verbatim fell into `unchanged` and reused the
/// frozen store's cached bitmap; under this split it always lands in `volatile` and is
/// unconditionally re-measured instead. The divergence is safe-direction (never serves a stale
/// bitmap, heights stay correct) but real — an extra re-rasterize in the case where a shrink makes
/// a previously-sealed block the new trailing block (`FeedScrollView.applyInPlaceBlockDiff` does
/// this for its NodeTable-derived block lists).
///
/// Blocks at/after `frontier` are never compared against `previous` — the caller (`volatile`) is
/// expected to always re-render them, so a stale/moved boundary there is harmless by construction.
/// Sealed blocks `[0, frontier)` ARE compared, so an out-of-model edit to already-sealed content
/// (see `BlockDiff.sealedChanged`'s doc) is still caught rather than silently trusted.
public nonisolated func diff(previous: [Block], new: [Block], frontier: Int) -> BlockDiff {
    let sealedEnd = max(0, min(frontier, new.count))
    var unchanged: [Int] = []
    var sealedChanged: [Int] = []
    unchanged.reserveCapacity(sealedEnd)

    for i in 0..<sealedEnd {
        if i < previous.count, previous[i].key == new[i].key, previous[i].contentHash == new[i].contentHash {
            unchanged.append(i)
        } else {
            sealedChanged.append(i)
        }
    }

    return BlockDiff(unchanged: unchanged, sealedChanged: sealedChanged, volatile: sealedEnd..<new.count)
}

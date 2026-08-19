// BlockDiff.swift

import Foundation

/// Minimum-update description for a same-item block-list change, split at a caller-supplied
/// frontier `F` (VelocityUI-k8qe; see `diff(previous:new:frontier:)` for the sealed/hot contract):
///
/// - `unchanged` — indices in `[0, F)` whose key+contentHash match `previous` at the same index:
///   reuse the cached frozen size+bitmap, zero recompute.
/// - `sealedChanged` — indices in `[0, F)` that differ or have no `previous` counterpart:
///   re-measure and freeze once. A sealed index reappearing here on a LATER diff means an
///   out-of-model edit to already-frozen content (VelocityUI-socg #4) — correctly re-freezes
///   rather than serving a stale bitmap.
/// - `volatile` — indices in `[F, new.count)`, the hot region: always re-measured, NEVER frozen —
///   freezing still-moving content is the exact hazard sealed/hot exists to prevent.
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
/// Pure: no measurement or rasterization, only compares `BlockKey`/`contentHash`.
///
/// `frontier` is the count of SEALED blocks in `new` — guaranteed to never change boundary, type,
/// or content again (VelocityUI-qc7.1). A pre-split DSL block list (no parser) gets the same
/// guarantee except for its own growing trailing block, via `frontier: new.count - 1` —
/// reproduces the old single-hot-tail model except the trailing index, which now always lands in
/// `volatile` and re-measures unconditionally instead of possibly reusing a cached bitmap.
/// Divergence is safe-direction (never stale) but real: an extra re-rasterize when a shrink makes
/// a previously-sealed block the new trailing one (`FeedScrollView.applyInPlaceBlockDiff`).
///
/// Blocks at/after `frontier` are never compared — the caller always re-renders them (`volatile`),
/// so a stale/moved boundary there is harmless. Sealed blocks `[0, frontier)` ARE compared, so an
/// out-of-model edit to sealed content is still caught.
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

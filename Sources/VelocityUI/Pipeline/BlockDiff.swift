// BlockDiff.swift

import Foundation

/// The minimum-update description for a same-item block-list change: which blocks are
/// untouched (reuse the cached frozen size+bitmap verbatim, zero recompute), which single
/// block may have grown (`hotTail`, re-measure/re-rasterize), and which blocks are brand new
/// (`appended`, measured once).
public struct BlockDiff: Sendable, Equatable {
    public let unchanged: [Int]
    public let hotTail: Int?
    public let appended: [Int]

    public init(unchanged: [Int], hotTail: Int?, appended: [Int]) {
        self.unchanged = unchanged
        self.hotTail = hotTail
        self.appended = appended
    }
}

/// Diffs `previous` against `new` for the SAME item id — the in-place path's per-block diff.
/// Pure: performs no measurement or rasterization, only compares `BlockKey`/`contentHash`.
///
/// Streaming model (VelocityUI-6qd): only the LAST block of `previous` may still be growing —
/// every earlier block is already frozen and, once frozen, is never touched again. `diff`
/// encodes that invariant directly: within the overlap window `0..<min(previous.count,
/// new.count)`, index `previous.count - 1` (the trailing block) is the only index eligible to
/// become `hotTail`. An earlier index differing is outside the streaming model — no real
/// streaming update produces that shape — and is intentionally left out of both `unchanged`
/// and `hotTail` rather than silently miscounted as either.
public nonisolated func diff(previous: [Block], new: [Block]) -> BlockDiff {
    var unchanged: [Int] = []
    unchanged.reserveCapacity(previous.count)
    var hotTail: Int?

    let overlap = min(previous.count, new.count)
    for i in 0..<overlap {
        let same = previous[i].key == new[i].key && previous[i].contentHash == new[i].contentHash
        if same {
            unchanged.append(i)
        } else if i == previous.count - 1 {
            hotTail = i
        }
    }

    let appended = new.count > previous.count ? Array(previous.count..<new.count) : []
    return BlockDiff(unchanged: unchanged, hotTail: hotTail, appended: appended)
}

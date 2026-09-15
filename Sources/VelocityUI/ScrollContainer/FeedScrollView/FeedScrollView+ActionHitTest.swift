// FeedScrollView+ActionHitTest.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// One action-tagged node's hit rect for `resolveTappedAction`, in scroll-content coordinates
/// (same convention `frameMap` uses). `depth` is the node's distance from the `NodeTable` root —
/// resolves an ancestor/descendant rect overlap (e.g. a tappable icon inside a tappable card) to
/// the innermost tagged node.
struct TaggedFragmentHit {
    let rect: CGRect
    let actionID: ActionID
    let depth: Int
}

extension FeedScrollView {

    // MARK: - actionFrameMap bookkeeping (mount/unmount only, mirrors frameMap)

    /// Rebuilds `index`'s tagged-node hit rects from whatever `WorkingRange` currently knows,
    /// converting each `Fragment.frame` (cell-local) into `cellFrame`'s content-space coordinate.
    /// Called from `mountAccessibilityElement` — every mount/reposition site already has both
    /// `index` and `cellFrame` in hand, so no new call sites are needed in the scroll path — plus
    /// once more from `refineKnownFrames`, the one place real fragments are delivered to a cell
    /// that was mounted as an empty `WorkingRange`-miss placeholder without a fresh
    /// `mountAccessibilityElement` call. Empty array (not a missing key) for a mounted index with
    /// no tagged nodes — cheap, common case, no allocation beyond the empty-array literal.
    func syncActionFrames(for index: Int, cellFrame: CGRect) {
        guard index < tables.count, let fragments = workingRange.entry(at: index)?.fragments else {
            actionFrameMap[index] = []
            return
        }
        let table = tables[index]
        var hits: [TaggedFragmentHit] = []
        for fragment in fragments {
            guard let actionID = fragment.actionID else { continue }
            hits.append(TaggedFragmentHit(
                rect: fragment.frame.offsetBy(dx: cellFrame.minX, dy: cellFrame.minY),
                actionID: actionID,
                depth: nodeDepth(of: fragment.id, in: table)
            ))
        }
        actionFrameMap[index] = hits
    }

    /// Drops `index`'s tagged-node hit rects, paired with `unmountAccessibilityElement`.
    func removeActionFrames(for index: Int) {
        actionFrameMap.removeValue(forKey: index)
    }

    /// Number of ancestors between `nodeIndex` and the `NodeTable` root — a tagged container
    /// (e.g. a whole card) has a smaller depth than a tagged leaf nested inside it.
    private func nodeDepth(of nodeIndex: Int, in table: NodeTable) -> Int {
        var depth = 0
        var i = nodeIndex
        while table.parentIndices.indices.contains(i) {
            let parent = table.parentIndices[i]
            guard parent >= 0 else { break }
            i = parent
            depth += 1
        }
        return depth
    }

    // MARK: - Tap resolution

    /// Deepest tagged node under `contentPoint` within `index`'s mounted rects — "innermost
    /// wins" for a tappable icon nested inside a tappable card. `nil` when the point lands only
    /// in untagged space, or `index` has no tagged nodes at all — the caller falls through to
    /// the existing item-level `onTap` in that case.
    func resolveTappedAction(at contentPoint: CGPoint, in index: Int) -> TaggedFragmentHit? {
        guard let hits = actionFrameMap[index] else { return nil }
        var best: TaggedFragmentHit?
        for hit in hits where hit.rect.contains(contentPoint) {
            if best == nil || hit.depth > best!.depth { best = hit }
        }
        return best
    }
}
#endif

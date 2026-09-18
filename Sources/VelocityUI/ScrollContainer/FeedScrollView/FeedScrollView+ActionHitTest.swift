// FeedScrollView+ActionHitTest.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// One resolved tap-target: the tagged node's action id and its rect in content coordinates.
struct TappedActionHit {
    let actionID: ActionID
    let rect: CGRect
}

extension FeedScrollView {

    /// Resolves a tap to the deepest action-tagged node under `contentPoint`, or `nil` if the tap
    /// only lands on untagged space. Walks `workingRange.entry(at:)?.layout` (the `ResolvedLayout`
    /// tree) directly, not the fragment list — a tagged container synthesizes no `Fragment` of its
    /// own (see `Fragment.swift`), so resolving from fragments alone misses taps in a container's
    /// padding/gaps and reports a child leaf's rect instead of the container's own. The layout
    /// tree has a real frame for every node, tagged or not, so both are fixed by construction.
    /// No bookkeeping mirrors this on the scroll path — taps are rare, renders are constant.
    ///
    /// Innermost wins: when the point lands under a tagged leaf nested inside a tagged container,
    /// each candidate is scored by its depth from the tree root, and the deepest one is returned.
    func resolveTappedAction(at contentPoint: CGPoint, in index: Int) -> TappedActionHit? {
        guard index < tables.count, let cellFrame = frameMap[index],
              let layout = workingRange.entry(at: index)?.layout else { return nil }
        let table = tables[index]
        var best: (actionID: ActionID, rect: CGRect, depth: Int)?

        // Mirrors collectFragments' coordinate math (Fragment.swift): totalFrame is local to
        // the parent, so each level's absoluteFrame.origin becomes the next level's parentOrigin.
        func walk(_ node: ResolvedLayout, parentOrigin: CGPoint, depth: Int) {
            let absoluteFrame = node.totalFrame.offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)
            if node.nodeIndex >= 0, let actionID = table.actionID(at: node.nodeIndex) {
                let contentFrame = absoluteFrame.offsetBy(dx: cellFrame.minX, dy: cellFrame.minY)
                if contentFrame.contains(contentPoint), best == nil || depth > best!.depth {
                    best = (actionID, contentFrame, depth)
                }
            }
            for child in node.children {
                walk(child, parentOrigin: absoluteFrame.origin, depth: depth + 1)
            }
        }
        walk(layout, parentOrigin: .zero, depth: 0)
        return best.map { TappedActionHit(actionID: $0.actionID, rect: $0.rect) }
    }
}
#endif

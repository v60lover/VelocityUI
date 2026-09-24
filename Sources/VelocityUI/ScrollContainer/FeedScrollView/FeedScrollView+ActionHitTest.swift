// FeedScrollView+ActionHitTest.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// One resolved tap-target: the tagged node's action id and its rect in content coordinates.
struct TappedActionHit {
    let actionID: ActionID
    let rect: CGRect
}

/// A long-press target: the text node's index in its item's table, its descriptor, and its rect
/// in content coordinates.
struct TextNodeHit {
    let nodeIndex: Int
    let descriptor: TextDescriptor
    let rect: CGRect
    /// Where the text bitmap is drawn (inside bubble padding), in content coordinates.
    let drawRect: CGRect
}

extension FeedScrollView {

    /// Resolves a tap to the deepest action-tagged node under `contentPoint`, or `nil` if the tap
    /// only lands on untagged space. Walks the `ResolvedLayout` tree, not the fragment list — a
    /// tagged container synthesizes no `Fragment` of its own (see `Fragment.swift`), so fragments
    /// alone miss taps in a container's padding/gaps. Taps are rare, so no scroll-path bookkeeping.
    func resolveTappedAction(at contentPoint: CGPoint, in index: Int) -> TappedActionHit? {
        deepestNode(at: contentPoint, in: index) { table, nodeIndex in
            table.actionID(at: nodeIndex)
        }.map { TappedActionHit(actionID: $0.value, rect: $0.rect) }
    }

    /// Resolves a long-press to the deepest `.text` node under `contentPoint`. `.hot` blocks
    /// count too (a finished answer's last block stays hot); a selection on one is dropped by
    /// `revalidateTextSelection` as soon as its layout hash changes.
    func resolveTextNode(at contentPoint: CGPoint, in index: Int) -> TextNodeHit? {
        deepestNode(at: contentPoint, in: index) { (table, nodeIndex) -> (Int, TextDescriptor)? in
            guard case .text(let descriptor) = table.nodes[nodeIndex] else { return nil }
            return (nodeIndex, descriptor)
        }.map { TextNodeHit(nodeIndex: $0.value.0, descriptor: $0.value.1, rect: $0.rect, drawRect: $0.drawRect) }
    }

    /// Shared tree walk: the deepest node whose `match` is non-nil and whose frame contains the
    /// point wins. One walk for every resolver, so they cannot drift on coordinate math.
    private func deepestNode<T>(
        at contentPoint: CGPoint, in index: Int, match: (NodeTable, Int) -> T?
    ) -> (value: T, rect: CGRect, drawRect: CGRect)? {
        guard index < tables.count, let cellFrame = frameMap[index],
              let layout = workingRange.entry(at: index)?.layout else { return nil }
        let table = tables[index]
        var best: (value: T, rect: CGRect, drawRect: CGRect, depth: Int)?

        // Mirrors collectFragments' coordinate math (Fragment.swift): totalFrame is local to
        // the parent, so each level's absoluteFrame.origin becomes the next level's parentOrigin.
        func walk(
            _ node: ResolvedLayout, parentOrigin: CGPoint, depth: Int,
            best: inout (value: T, rect: CGRect, drawRect: CGRect, depth: Int)?
        ) {
            let absoluteFrame = node.totalFrame.offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)
            if node.nodeIndex >= 0, let value = match(table, node.nodeIndex) {
                let contentFrame = absoluteFrame.offsetBy(dx: cellFrame.minX, dy: cellFrame.minY)
                if contentFrame.contains(contentPoint), best == nil || depth > best!.depth {
                    let drawFrame = (node.contentFrame ?? node.totalFrame)
                        .offsetBy(dx: parentOrigin.x + cellFrame.minX, dy: parentOrigin.y + cellFrame.minY)
                    best = (value, contentFrame, drawFrame, depth)
                }
            }
            for child in node.children {
                walk(child, parentOrigin: absoluteFrame.origin, depth: depth + 1, best: &best)
            }
        }
        walk(layout, parentOrigin: .zero, depth: 0, best: &best)
        return best.map { ($0.value, $0.rect, $0.drawRect) }
    }
}
#endif

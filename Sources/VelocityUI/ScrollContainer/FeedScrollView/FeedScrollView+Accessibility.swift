// FeedScrollView+Accessibility.swift

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension FeedScrollView {

    // MARK: - frameMap / accessibility element bookkeeping (mount/unmount only)

    /// Snapshots `frame` (content coordinates) for `index` and creates/updates its
    /// `UIAccessibilityElement`. Called from every mount/reposition site in
    /// `updateVisibleCells()` — idempotent, so re-mounting an already-tracked index just
    /// refreshes its label/frame instead of allocating a second element.
    func mountAccessibilityElement(for index: Int, frame: CGRect, item: Item) {
        frameMap[index] = frame
        if let element = accessibilityElementsByIndex[index] {
            element.accessibilityLabel = accessibilityLabelText(for: item)
        } else {
            let element = UIAccessibilityElement(accessibilityContainer: interactionOverlay)
            element.accessibilityLabel = accessibilityLabelText(for: item)
            accessibilityElementsByIndex[index] = element
            _accessibilityElementsDirty = true
        }
    }

    /// Drops `index`'s frameMap entry and accessibility element, paired with
    /// `updateVisibleCells()`'s cell-recycle loop.
    func unmountAccessibilityElement(for index: Int) {
        frameMap.removeValue(forKey: index)
        if accessibilityElementsByIndex.removeValue(forKey: index) != nil {
            _accessibilityElementsDirty = true
        }
    }

    /// Rebuilds `interactionOverlay.accessibilityElements` once, only if the mounted SET
    /// changed this pass. Called at the end of `updateVisibleCells()`.
    func flushAccessibilityElementsIfNeeded() {
        guard _accessibilityElementsDirty else { return }
        interactionOverlay.accessibilityElements = Array(accessibilityElementsByIndex.values)
        _accessibilityElementsDirty = false
    }

    // MARK: - Per-frame sync (cheap, allocation-free — runs even when the visible set didn't change)

    /// Pins `interactionOverlay` over the current viewport and refreshes each existing
    /// element's `accessibilityFrameInContainerSpace` in place. No new elements, no array
    /// reallocation — only existing objects' stored frame is mutated, same allocation budget
    /// as the scroll path's other per-frame loops.
    func syncInteractionOverlayFrame() {
        interactionOverlay.frame = bounds
        let origin = interactionOverlay.frame.origin
        for (index, contentFrame) in frameMap {
            guard let element = accessibilityElementsByIndex[index] else { continue }
            element.accessibilityFrameInContainerSpace = CGRect(
                x: contentFrame.minX - origin.x,
                y: contentFrame.minY - origin.y,
                width: contentFrame.width,
                height: contentFrame.height
            )
        }
    }

    /// Phase 1 VoiceOver label: the closure if set, else `String(describing:)`. Full node-level
    /// labeling is out of scope here (see VelocityUI-ye8a.2 for per-fragment action ids).
    func accessibilityLabelText(for item: Item) -> String {
        cellAccessibilityLabel?(item) ?? String(describing: item)
    }

    // MARK: - Tap resolution

    /// Hit-tests `contentPoint` against `frameMap` — the geometry snapshotted at mount time,
    /// not live `resolvedFrames`, so a tap resolves against what's actually on screen even if
    /// a frame shifts between paint and tap delivery. `nil` for a tap on spacing/gaps.
    func resolveTappedIndex(at contentPoint: CGPoint) -> Int? {
        for (index, frame) in frameMap where frame.contains(contentPoint) {
            return index
        }
        return nil
    }
}
#endif

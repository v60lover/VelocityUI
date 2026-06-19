// RenderCell.swift

#if canImport(UIKit)
import UIKit

// MARK: - CellKind

public enum CellKind: Hashable, Sendable {
    case standard
}

// MARK: - MediaHandle

/// Cancellable token wrapping the Task fetching one fragment's image.
public final class MediaHandle: Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    public func cancel() {
        task.cancel()
    }

    public var isCancelled: Bool { task.isCancelled }
}

// MARK: - RenderCell

/// CALayer-backed cell with two-phase commit:
/// • geometry: applyLayout(_:)  — synchronous, hot path, never awaits
/// • media:    applyContent(id:image:) — called async when image is decoded
///
/// Layer tree:
///   layer (root, frame owned by scroll container)
///   ├── placeholderLayer  (CAGradientLayer, systemGray5→6, opacity 1 until all media loads)
///   └── contentLayer      (opacity 0 until all media loads)
///       └── sublayers keyed by fragment.id  [Int: CALayer]
@MainActor
public final class RenderCell {
    public let layer = CALayer()
    private let placeholderLayer: CAGradientLayer
    private let contentLayer = CALayer()

    /// Set at init; stored as let so future per-kind pools can dispatch on this value.
    public let kind: CellKind

    private var sublayers: [Int: CALayer] = [:]
    private var mediaFragmentIDs: Set<Int> = []
    private var mediaHandles: [MediaHandle] = []
    /// Sticky true once all media has loaded for the current item; cleared on cross-item recycle.
    private var allMediaLoaded = false
    private(set) var currentItemID: AnyHashable?

    public init(kind: CellKind = .standard) {
        self.kind = kind
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor.systemGray5.cgColor, UIColor.systemGray6.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        placeholderLayer = gradient

        layer.masksToBounds = false
        contentLayer.masksToBounds = false
        contentLayer.opacity = 0

        layer.addSublayer(placeholderLayer)
        layer.addSublayer(contentLayer)
    }

    // MARK: - Lifecycle

    /// Compares newItemID against currentItemID to pick the correct recycle mode, then rebinds.
    ///
    /// Same item  → cancel pending fetches only; contents stay (stale-until-replaced).
    /// Cross item → cancel fetches + remove sublayers + reset opacities. Stale content from
    ///              another item is a UX and privacy bug — always hard-cut on cross-item recycle.
    public func prepareForReuse(for newItemID: AnyHashable) {
        let isSameItem = (currentItemID == newItemID)

        mediaHandles.forEach { $0.cancel() }
        mediaHandles.removeAll(keepingCapacity: true)

        if !isSameItem {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sub in sublayers.values { sub.removeFromSuperlayer() }
            sublayers.removeAll(keepingCapacity: true)
            mediaFragmentIDs.removeAll(keepingCapacity: true)
            placeholderLayer.opacity = 1
            contentLayer.opacity = 0
            CATransaction.commit()
            allMediaLoaded = false
        }

        currentItemID = newItemID
    }

    // MARK: - Layout (synchronous — must never await)

    /// Geometry phase. Hot-path contract: zero allocation in steady-state recycling (sublayer reuse).
    /// Prunes sublayers for fragments no longer present so Phase 2+ re-measures don't leave orphans.
    public func applyLayout(_ fragments: [Fragment]) {
        let cellBounds = CGRect(origin: .zero, size: layer.bounds.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Guard: skip CA needsLayout pipeline when bounds are unchanged
        if placeholderLayer.bounds.size != cellBounds.size {
            placeholderLayer.frame = cellBounds
            contentLayer.frame = cellBounds
        }

        // Prune sublayers no longer in the fragment set. Fast path: skip if count matches
        // (stable Phase-1 layouts never shrink per item). Full check done when count diverges.
        if sublayers.count > fragments.count {
            let incomingIDs = Set(fragments.map { $0.id })
            for id in sublayers.keys.filter({ !incomingIDs.contains($0) }) {
                sublayers[id]?.removeFromSuperlayer()
                sublayers.removeValue(forKey: id)
                mediaFragmentIDs.remove(id)
            }
        }

        for fragment in fragments {
            let sub: CALayer
            if let existing = sublayers[fragment.id] {
                sub = existing
            } else {
                let l = CALayer()
                l.masksToBounds = false
                l.cornerRadius = 0
                contentLayer.addSublayer(l)
                sublayers[fragment.id] = l
                sub = l
            }

            // Classify on EVERY iteration — handles id-reuse across content types so
            // mediaFragmentIDs never becomes stale relative to the current fragment set.
            if case .image = fragment.content {
                // Gray placeholder tint only while no content is loaded
                if sub.contents == nil { sub.backgroundColor = UIColor.systemGray5.cgColor }
                mediaFragmentIDs.insert(fragment.id)
            } else {
                sub.backgroundColor = nil
                sub.contents = nil  // image→geometry reclassification must not leave stale image visible
                mediaFragmentIDs.remove(fragment.id)
            }

            sub.frame = fragment.frame

            #if DEBUG
            assertLayerInvariants(sub)
            #endif
        }

        // If a re-layout added new image fragments without content, reopen the wait gate.
        // New unloaded fragments get per-sublayer gray tint (above); we intentionally do NOT
        // re-show the full placeholder gradient — hiding already-loaded content would be worse
        // UX than the per-sublayer tint for the new arrival.
        if allMediaLoaded && mediaFragmentIDs.contains(where: { sublayers[$0]?.contents == nil }) {
            allMediaLoaded = false
        }

        CATransaction.commit()
    }

    // MARK: - Content

    /// Apply a pre-decoded BGRA8888-normalised image. Crossfades contents over 0.2 s via
    /// CATransition (CALayer.contents has no default CA action; setAnimationDuration alone
    /// would produce an instant swap). Fades out the placeholder once ALL image fragments arrive.
    ///
    /// `itemID` must match `currentItemID`. Passing the ID captured at fetch-start lets
    /// RenderCell self-defend against stale callbacks that race a cross-item recycle — a
    /// privacy guarantee: another item's image must never paint on this cell's sublayers.
    public func applyContent(id: Int, image: CGImage, for itemID: AnyHashable) {
        // Privacy guard: reject stale callbacks from a previous item's fetch.
        // nil currentItemID means the cell is fresh/unbound — any delivery is accepted.
        if let currentID = currentItemID, currentID != itemID { return }
        guard let sub = sublayers[id] else { return }

        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        sub.add(fade, forKey: "contents-fade")
        sub.contents = image  // explicit animation is unaffected by setDisableActions

        // Clear placeholder tint without animating it
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sub.backgroundColor = nil
        CATransaction.commit()

        fadeOutPlaceholderIfAllReady()
    }

    // MARK: - Media Handles

    /// Register a Task token for a pending image fetch.
    /// The Task's body MUST NOT strongly capture this cell — use `[weak self]` to avoid a
    /// retain cycle that outlives cancellation. Cycle risk: cell → handles → task closure → cell.
    func addMediaHandle(_ handle: MediaHandle) {
        mediaHandles.append(handle)
    }

    /// Cancel all pending media fetch Tasks without clearing sublayer contents.
    /// Symmetric counterpart to `addMediaHandle`. Call at recycle time to release decode
    /// slots immediately — sublayers stay intact for pool reuse; `prepareForReuse` clears
    /// them on the next cross-item bind.
    func cancelPendingMedia() {
        mediaHandles.forEach { $0.cancel() }
        mediaHandles.removeAll(keepingCapacity: true)
    }

    // MARK: - Private

    private func fadeOutPlaceholderIfAllReady() {
        guard !allMediaLoaded else { return }  // already revealed — skip O(N) check
        guard !mediaFragmentIDs.isEmpty else { return }
        guard mediaFragmentIDs.allSatisfy({ sublayers[$0]?.contents != nil }) else { return }

        allMediaLoaded = true

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        placeholderLayer.opacity = 0
        contentLayer.opacity = 1
        CATransaction.commit()
    }

    #if DEBUG
    private func assertLayerInvariants(_ l: CALayer) {
        assert(!l.masksToBounds, "masksToBounds forbidden — round at decode time via CGContext")
        assert(l.cornerRadius == 0, "cornerRadius forbidden — round at decode time via CGContext")
        assert(!(l is CATextLayer), "CATextLayer forbidden — use NSTextLayoutManager → CGImage → plain CALayer")
    }
    #endif
}
#endif

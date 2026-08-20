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
    private enum LayerIdentity: Hashable {
        case block(BlockID)
        case positional(Int)
    }

    public let layer = CALayer()
    private let placeholderLayer: CAGradientLayer
    private let contentLayer = CALayer()

    /// Set at init; stored as let so future per-kind pools can dispatch on this value.
    public let kind: CellKind

    /// Produces each image fragment's first-paint placeholder. Defaults to
    /// `DefaultPlaceholderRenderer` (this cell's original thumbnail/BlurHash behavior).
    /// Callers that own a `RenderEnvironment` should pass `environment.placeholderRenderer`
    /// so cell and environment agree on first-paint strategy.
    private let placeholderRenderer: any PlaceholderRenderer

    /// Layers follow an explicit block identity through insertions; positional fragments retain
    /// the legacy node-index identity.
    private var sublayers: [LayerIdentity: CALayer] = [:]
    private var layerIdentityByFragmentID: [Int: LayerIdentity] = [:]
    /// Ordered frame metadata survives while offscreen block layers are released.
    /// It lets the scroll path find the next resident span without recreating the full cell.
    private var blockFragments: [Fragment] = []
    private var blockFrames: [CGRect] = []
    private var activeBlockFragmentIDs: Set<Int> = []
    private var mediaFragmentIDs: Set<Int> = []
    /// Fragment ids whose sublayer currently shows a decode-guaranteed thumbnail/BlurHash
    /// placeholder (as opposed to real content or the systemGray5 tint). Consulted by
    /// applyContent to report which physics-fallback path a real-image delivery replaced.
    private var placeholderPaintedFragmentIDs: Set<Int> = []
    private var mediaHandles: [MediaHandle] = []
    private var mediaHandlesByFragmentID: [Int: [MediaHandle]] = [:]
    /// Sticky true once all media has loaded for the current item; cleared on cross-item recycle.
    private var allMediaLoaded = false
    private(set) var currentItemID: AnyHashable?
    /// Set by `prepareForReuse`'s cross-item branch; consumed by the next `applyLayout` call.
    /// `fragment.id` is positional (== nodeIndex), so a cross-item recycle where the new item's
    /// id SET differs from the retained one (not just count) can't be caught by the cheap
    /// `sublayers.count > fragments.count` check — e.g. an image-only cell (ids {0}) recycled
    /// into a VStack{image,text} cell (ids {1,2}): count 1→2 passes the guard, but id 0 orphans
    /// forever. When true, `applyLayout` runs the full id-diff prune unconditionally, then clears
    /// the flag. See VelocityUI-ksh.
    private var needsSublayerReconcile = false

    public init(kind: CellKind = .standard, placeholderRenderer: any PlaceholderRenderer = DefaultPlaceholderRenderer()) {
        self.kind = kind
        self.placeholderRenderer = placeholderRenderer
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

        layer.actions = [
            "position":  NSNull(),
            "bounds":    NSNull(),
            "opacity":   NSNull(),
            "sublayers": NSNull(),
        ]

        #if DEBUG
        assert(layer.actions?["position"] is NSNull,
            "cell.layer must suppress 'position' implicit animation — do not remove from layer.actions")
        assert(layer.actions?["bounds"] is NSNull,
            "cell.layer must suppress 'bounds' implicit animation — do not remove from layer.actions")
        assert(layer.actions?["opacity"] is NSNull,
            "cell.layer must suppress 'opacity' implicit animation — do not remove from layer.actions")
        assert(layer.actions?["sublayers"] is NSNull,
            "cell.layer must suppress 'sublayers' implicit animation — do not remove from layer.actions")
        #endif
    }

    // MARK: - Lifecycle

    /// Compares newItemID against currentItemID to pick the correct recycle mode, then rebinds.
    ///
    /// Same item  → cancel pending fetches only; contents stay (stale-until-replaced).
    /// Cross item → cancel fetches + hard-cut contents/background + reset opacities. Stale
    ///              content from another item is a UX and privacy bug — always hard-cut on
    ///              cross-item recycle.
    ///
    /// Cross-item recycle keeps the existing sublayer CALayer instances (and the `sublayers`
    /// map) instead of removing them — only `contents`/`backgroundColor` are cleared, inside
    /// the same disabled-actions transaction that resets the placeholder/content opacities, so
    /// the hard privacy cut still lands atomically. `applyLayout`'s `if let existing =
    /// sublayers[fragment.id]` path then reuses these cleared layers for the next item's
    /// fragments instead of forcing a fresh `CALayer()` alloc on every cross-item mount — the
    /// "20/37 CALayer" allocation smell from VelocityUI-ksh. Safe against stale PIXELS because
    /// every fragment whose `sub.contents == nil` unconditionally re-derives its content in
    /// `applyLayout` (sync paint, decode placeholder, or gray tint). It is NOT by itself safe
    /// against stale/orphaned LAYERS when the new item's fragment id set differs from the
    /// retained one (not just its count) — `needsSublayerReconcile` is set here so the next
    /// `applyLayout` call runs the full id-diff prune unconditionally and reconciles the
    /// `sublayers` map to the new item's exact id set.
    public func prepareForReuse(for newItemID: AnyHashable) {
        let isSameItem = (currentItemID == newItemID)

        mediaHandles.forEach { $0.cancel() }
        mediaHandles.removeAll(keepingCapacity: true)
        for handles in mediaHandlesByFragmentID.values { handles.forEach { $0.cancel() } }
        mediaHandlesByFragmentID.removeAll(keepingCapacity: true)

        if !isSameItem {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sub in sublayers.values {
                sub.contents = nil
                sub.backgroundColor = nil
            }
            mediaFragmentIDs.removeAll(keepingCapacity: true)
            placeholderPaintedFragmentIDs.removeAll(keepingCapacity: true)
            blockFragments.removeAll(keepingCapacity: true)
            blockFrames.removeAll(keepingCapacity: true)
            activeBlockFragmentIDs.removeAll(keepingCapacity: true)
            placeholderLayer.opacity = 1
            contentLayer.opacity = 0
            CATransaction.commit()
            allMediaLoaded = false
            needsSublayerReconcile = true
        }

        currentItemID = newItemID
    }

    // MARK: - Layout (synchronous — must never await)

    /// Geometry phase. Hot-path contract: zero allocation in steady-state recycling (sublayer reuse).
    /// Prunes sublayers for fragments no longer present so Phase 2+ re-measures don't leave orphans.
    public func applyLayout(_ fragments: [Fragment]) {
        applyLayout(fragments, synchronousContent: [:])
    }

    /// Geometry phase with optional synchronous content paint.
    ///
    /// For image fragments whose id is in `synchronousContent`, the decoded CGImage is applied
    /// inline — no Task spawn, no fade, no gray tint. If the map covers every image fragment,
    /// `contentLayer` is revealed and `placeholderLayer` hidden in the same CATransaction (sync
    /// paint = image is part of the first rendered frame).
    ///
    /// Callers must obtain `synchronousContent` via `ImageActor.cachedImage` (nonisolated) — on a
    /// scale mismatch it returns nil and the fragment falls back to the async `spawnMediaFetches`
    /// path. Extra keys not matching any fragment id are silently ignored.
    public func applyLayout(_ fragments: [Fragment], synchronousContent: [Int: CGImage]) {
        let cellBounds = CGRect(origin: .zero, size: layer.bounds.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Guard: skip CA needsLayout pipeline when bounds are unchanged
        if placeholderLayer.bounds.size != cellBounds.size {
            placeholderLayer.frame = cellBounds
            contentLayer.frame = cellBounds
        }

        // Prune sublayers no longer in the fragment set.
        //
        // `needsSublayerReconcile` forces the id-diff unconditionally on a cross-item recycle
        // whose fragment id SET differs from the retained one (see the property's doc for why
        // count alone can't catch this) — the one `Set` alloc lands only on cross-item mounts.
        // Same-item relayout (flag false): skip the id-diff unless count strictly shrinks.
        if needsSublayerReconcile || sublayers.count > fragments.count {
            let incomingIdentities = Set(fragments.map(layerIdentity(for:)))
            let incomingIDs = Set(fragments.map(\.id))
            for identity in sublayers.keys.filter({ !incomingIdentities.contains($0) }) {
                sublayers[identity]?.removeFromSuperlayer()
                sublayers.removeValue(forKey: identity)
                let removedIDs = layerIdentityByFragmentID.keys.filter { layerIdentityByFragmentID[$0] == identity }
                for id in removedIDs {
                    layerIdentityByFragmentID.removeValue(forKey: id)
                    mediaFragmentIDs.remove(id)
                    placeholderPaintedFragmentIDs.remove(id)
                }
            }
            let inactiveIDs = layerIdentityByFragmentID.keys.filter { !incomingIDs.contains($0) }
            for id in inactiveIDs {
                layerIdentityByFragmentID.removeValue(forKey: id)
                mediaFragmentIDs.remove(id)
                placeholderPaintedFragmentIDs.remove(id)
            }
            needsSublayerReconcile = false
        }

        for fragment in fragments {
            let identity = layerIdentity(for: fragment)
            layerIdentityByFragmentID[fragment.id] = identity
            let sub: CALayer
            if let existing = sublayers[identity] {
                sub = existing
            } else {
                let l = CALayer()
                l.masksToBounds = false
                l.cornerRadius = 0
                contentLayer.addSublayer(l)
                sublayers[identity] = l
                sub = l
            }

            // Classify on EVERY iteration — handles id-reuse across content types so
            // mediaFragmentIDs never becomes stale relative to the current fragment set.
            if case .image(let descriptor) = fragment.content {
                if let image = synchronousContent[fragment.id] {
                    // Sync paint: image is already decoded — set contents inline.
                    // No gray tint (image is present), no CATransition (no delay to mask).
                    sub.contents = image
                    sub.backgroundColor = nil
                    placeholderPaintedFragmentIDs.remove(fragment.id)
                } else if sub.contents == nil {
                    if let placeholder = decodePlaceholder(descriptor, targetSize: fragment.frame.size) {
                        // Decode-guaranteed first paint: thumbnail/BlurHash decoded synchronously.
                        // No gray tint — a real applyContent delivery later crossfades over this.
                        sub.contents = placeholder
                        sub.backgroundColor = nil
                        placeholderPaintedFragmentIDs.insert(fragment.id)
                    } else {
                        // Gray placeholder tint only while no content is loaded
                        sub.backgroundColor = UIColor.systemGray5.cgColor
                    }
                }
                mediaFragmentIDs.insert(fragment.id)
            } else if case .text = fragment.content {
                // Text has no async delivery path (unlike images, no applyContent/fade-in) —
                // the rasterized bitmap is either available now via synchronousContent (the
                // VelocityUI-socg C3 in-place path, which always freezes+rasterizes before
                // calling applyLayout) or it isn't produced yet (no general first-mount
                // rasterizer wired — VelocityUI-3z4s). Set unconditionally (nil when absent) so
                // a sublayer reused across a text->other->text reclassification within the same
                // item never shows a stale bitmap from a previous fragment at this id.
                sub.contents = synchronousContent[fragment.id]
                sub.backgroundColor = nil
                mediaFragmentIDs.remove(fragment.id)
                placeholderPaintedFragmentIDs.remove(fragment.id)
            } else {
                sub.backgroundColor = nil
                sub.contents = nil  // image→geometry reclassification must not leave stale image visible
                mediaFragmentIDs.remove(fragment.id)
                placeholderPaintedFragmentIDs.remove(fragment.id)
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
        if allMediaLoaded && mediaFragmentIDs.contains(where: { layer(for: $0)?.contents == nil }) {
            allMediaLoaded = false
        }

        // Fast-path reveal: when the sync map covers every image fragment, the image is part
        // of the first rendered frame — no delay to mask, so no fade animation needed.
        // Must run inside setDisableActions(true) so the opacity changes are instant.
        if !allMediaLoaded && !mediaFragmentIDs.isEmpty
            && mediaFragmentIDs.allSatisfy({ layer(for: $0)?.contents != nil }) {
            allMediaLoaded = true
            placeholderLayer.opacity = 0
            contentLayer.opacity = 1
        }

        CATransaction.commit()
    }

    /// Reconciles only the ordered blocks intersecting `viewportInCell`.
    /// Returns blocks that became active and may need an async image request.
    @discardableResult
    public func updateBlockViewport(
        fragments: [Fragment],
        viewportInCell: CGRect,
        synchronousContent: [Int: CGImage]
    ) -> [Fragment] {
        blockFragments = fragments
        blockFrames = fragments.map(\.frame)
        activeBlockFragmentIDs.removeAll(keepingCapacity: true)
        return updateBlockViewport(viewportInCell: viewportInCell, synchronousContent: synchronousContent)
    }

    /// Updates residency from already-recorded layout metadata. This is the scroll-path entry
    /// point: binary search plus the newly active blocks, with no full-fragment scan.
    @discardableResult
    public func updateBlockViewport(
        viewportInCell: CGRect,
        synchronousContent: [Int: CGImage]
    ) -> [Fragment] {
        guard !blockFragments.isEmpty else { return [] }

        let range = BlockViewportRange.activeRange(in: blockFrames, window: viewportInCell)
        let active = Array(blockFragments[range])
        let nextIDs = Set(active.map(\.id))
        guard nextIDs != activeBlockFragmentIDs else { return [] }

        let enteringIDs = nextIDs.subtracting(activeBlockFragmentIDs)
        let leavingIDs = activeBlockFragmentIDs.subtracting(nextIDs)
        cancelPendingMedia(for: leavingIDs)
        activeBlockFragmentIDs = nextIDs

        // The active set can change without changing its count, so force the exact id diff.
        needsSublayerReconcile = true
        applyLayout(active, synchronousContent: synchronousContent)
        return active.filter { enteringIDs.contains($0.id) }
    }

    // MARK: - Content

    /// Which physics-fallback path a real-image `applyContent` delivery replaced.
    /// Reported so callers (FeedScrollView) can distinguish a true gray→image transition
    /// (prefetch never landed a placeholder either) from a thumbnail/BlurHash→image
    /// transition (the decode-guaranteed placeholder engaged before the real image arrived).
    public enum ContentTransitionKind: Sendable, Equatable {
        case fromGrayPlaceholder
        case fromThumbnailPlaceholder
    }

    #if canImport(XCTest)
    /// Counts applyContent privacy-guard rejections (stale itemID deliveries).
    /// In normal fast-scroll operation this should be zero — cancelled Tasks return nil before
    /// reaching applyContent. Non-zero counts indicate a cancellation-propagation gap.
    /// Serial-access invariant: reads/writes happen on @MainActor only (RenderCell is @MainActor);
    /// the nonisolated(unsafe) annotation is a formality for @testable cross-module access.
    nonisolated(unsafe) static var _privacyGuardFiredCount: Int = 0

    /// True once every image fragment for the current item has non-nil sublayer contents —
    /// i.e. `contentLayer` has been revealed. Path-independent: set by both the synchronous
    /// `applyLayout(_:synchronousContent:)` fast path (image already cache-resident at mount
    /// time) and the async `applyContent` path. Tests that need to observe "this cell is
    /// showing real image content" must poll this, not `_debugApplyContentCount` or
    /// `RenderEnvironment.contentDeliveryObserver` — either of those only fires on the async
    /// path and misses mount-time synchronous delivery entirely.
    var _debugIsContentRevealed: Bool { allMediaLoaded }

    /// Every fragment id currently painting a `CGImage` (image or text), mapped to that exact
    /// instance. Test-only — lets tests assert PIXEL identity (the same `CGImage` reference is
    /// still on screen = zero re-rasterize/re-decode) instead of only frame height, without the
    /// test needing to know `Fragment.id`'s `NodeTable` nodeIndex mapping ahead of time (VelocityUI
    /// -socg C3 activation's "re-validate by pixels, not just frame height" checklist item).
    var _debugPaintedBitmaps: [Int: CGImage] {
        var result: [Int: CGImage] = [:]
        for (id, identity) in layerIdentityByFragmentID {
            guard let layer = sublayers[identity] else { continue }
            // `contents as? CGImage` always "succeeds" for any CF-bridged Any (compiler warning
            // treated as an error in the Xcode-project test target) — CFGetTypeID is the correct
            // way to check a CF type identity before the cast.
            guard let contents = layer.contents else { continue }
            let cf = contents as CFTypeRef
            guard CFGetTypeID(cf) == CGImage.typeID else { continue }
            result[id] = (cf as! CGImage)
        }
        return result
    }

    /// Total count of successful `applyContent` deliveries across all cells. Test-only — no
    /// BenchmarkHost consumer (that instrumentation routes through
    /// `RenderEnvironment.contentDeliveryObserver` instead). Used by RenderCellTests/
    /// FeedScrollViewTests to assert the sync mount-time paint path bypasses `applyContent`
    /// entirely.
    /// nonisolated(unsafe): writes occur only on @MainActor; reads are test-only.
    nonisolated(unsafe) static var _debugApplyContentCount: Int = 0
    nonisolated static func _debugResetApplyContentCount() { _debugApplyContentCount = 0 }
    #endif

    /// Apply a pre-decoded BGRA8888-normalised image. Crossfades over 0.2s via CATransition
    /// (`CALayer.contents` has no default CA action, so `setAnimationDuration` alone would be
    /// an instant swap). Fades out the placeholder once ALL image fragments arrive.
    ///
    /// `itemID` must match `currentItemID` — passing the ID captured at fetch-start lets the
    /// cell self-defend against stale callbacks racing a cross-item recycle (privacy guarantee:
    /// another item's image must never paint on this cell's sublayers).
    ///
    /// Returns the `ContentTransitionKind` replaced, or nil if rejected (privacy guard) or the
    /// fragment id has no sublayer. Callers that don't need gray-vs-thumbnail distinction may
    /// ignore it.
    @discardableResult
    public func applyContent(id: Int, image: CGImage, for itemID: AnyHashable) -> ContentTransitionKind? {
        // Privacy guard: reject stale callbacks from a previous item's fetch.
        // nil currentItemID means the cell is fresh/unbound — any delivery is accepted.
        if let currentID = currentItemID, currentID != itemID {
            #if canImport(XCTest)
            RenderCell._privacyGuardFiredCount += 1
            #endif
            return nil
        }
        guard let sub = layer(for: id) else { return nil }

        let transitionKind: ContentTransitionKind = placeholderPaintedFragmentIDs.remove(id) != nil
            ? .fromThumbnailPlaceholder
            : .fromGrayPlaceholder

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

        #if canImport(XCTest)
        RenderCell._debugApplyContentCount += 1
        #endif

        return transitionKind
    }

    // MARK: - Media Handles

    /// Register a Task token for a pending image fetch.
    /// The Task's body MUST NOT strongly capture this cell — use `[weak self]` to avoid a
    /// retain cycle that outlives cancellation. Cycle risk: cell → handles → task closure → cell.
    func addMediaHandle(_ handle: MediaHandle) {
        mediaHandles.append(handle)
    }

    /// Registers a fetch owned by one resident block so leaving that block cancels it eagerly.
    func addMediaHandle(_ handle: MediaHandle, for fragmentID: Int) {
        mediaHandlesByFragmentID[fragmentID, default: []].append(handle)
    }

    /// Cancel all pending media fetch Tasks without clearing sublayer contents.
    /// Symmetric counterpart to `addMediaHandle`. Call at recycle time to release decode
    /// slots immediately — sublayers stay intact for pool reuse; `prepareForReuse` clears
    /// them on the next cross-item bind.
    func cancelPendingMedia() {
        mediaHandles.forEach { $0.cancel() }
        mediaHandles.removeAll(keepingCapacity: true)
        for handles in mediaHandlesByFragmentID.values { handles.forEach { $0.cancel() } }
        mediaHandlesByFragmentID.removeAll(keepingCapacity: true)
    }

    private func cancelPendingMedia(for fragmentIDs: Set<Int>) {
        for id in fragmentIDs {
            mediaHandlesByFragmentID.removeValue(forKey: id)?.forEach { $0.cancel() }
        }
    }

    // MARK: - Private

    /// Renders a fragment's first-paint placeholder via `placeholderRenderer`, trying
    /// thumbnail, then BlurHash, then a consumer's custom payload, in that order — thumbnail
    /// takes precedence over BlurHash over custom when more than one is set. Runs
    /// synchronously on MainActor — callers must only invoke this when `sub.contents == nil`
    /// (the gate in applyLayout already enforces a decode-once-per-fragment-lifetime budget).
    /// See `PlaceholderRenderer`'s docstring for the frame-budget contract every renderer
    /// (including the default) must honor.
    private func decodePlaceholder(_ descriptor: ImageDescriptor, targetSize: CGSize) -> CGImage? {
        if let data = descriptor.thumbnailData,
           let image = placeholderRenderer.render(
               .thumbnail(data), targetSize: targetSize, cornerRadius: descriptor.cornerRadius
           ) {
            return image
        }
        if let hash = descriptor.blurHash,
           let image = placeholderRenderer.render(
               .blurHash(hash), targetSize: targetSize, cornerRadius: descriptor.cornerRadius
           ) {
            return image
        }
        if let payload = descriptor.customPlaceholderPayload,
           let image = placeholderRenderer.render(
               .custom(payload), targetSize: targetSize, cornerRadius: descriptor.cornerRadius
           ) {
            return image
        }
        return nil
    }

    private func fadeOutPlaceholderIfAllReady() {
        guard !allMediaLoaded else { return }  // already revealed — skip O(N) check
        guard !mediaFragmentIDs.isEmpty else { return }
        guard mediaFragmentIDs.allSatisfy({ layer(for: $0)?.contents != nil }) else { return }

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

    private func layerIdentity(for fragment: Fragment) -> LayerIdentity {
        fragment.blockID.map(LayerIdentity.block) ?? .positional(fragment.id)
    }

    private func layer(for fragmentID: Int) -> CALayer? {
        guard let identity = layerIdentityByFragmentID[fragmentID] else { return nil }
        return sublayers[identity]
    }
}
#endif

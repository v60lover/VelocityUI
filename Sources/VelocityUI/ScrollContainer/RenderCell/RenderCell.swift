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

/// CALayer-backed cell with two-phase commit: `applyLayout` sets geometry synchronously on the
/// hot path, `applyContent` paints media asynchronously once decoded. Layer tree: a
/// placeholder gradient and a content layer (fragment sublayers keyed by id), opacity-swapped
/// once all media loads.
@MainActor
public final class RenderCell {
    enum LayerIdentity: Hashable {
        case block(BlockID)
        case positional(Int)
    }

    public let layer = CALayer()
    private let placeholderLayer: CAGradientLayer
    let contentLayer = CALayer()

    /// Set at init; stored as let so future per-kind pools can dispatch on this value.
    public let kind: CellKind

    /// Produces each image fragment's first-paint placeholder. Callers that own a
    /// `RenderEnvironment` should pass `environment.placeholderRenderer` to keep strategy in sync.
    private let placeholderRenderer: any PlaceholderRenderer

    /// Layers follow an explicit block identity through insertions; positional fragments retain
    /// the legacy node-index identity.
    var sublayers: [LayerIdentity: CALayer] = [:]
    private var codeTailSublayers: [LayerIdentity: CALayer] = [:]
    /// One stacked CALayer per frozen/hot chunk in a code body's current `CodeBodyLayerContent` --
    /// see `RenderCell+CodeChunks.swift`. Mounted whenever any part of the code card is resident
    /// (no sub-block viewport residency yet).
    var codeChunkSublayers: [LayerIdentity: [CALayer]] = [:]
    /// One clip container per code body -- `masksToBounds = true, cornerRadius = 0` (a plain
    /// rectangular clip, not corner rounding, so no offscreen render pass). Chunk/tail layers are
    /// sublayers of this at LOCAL coordinates (origin x=0); horizontal scroll is a single write to
    /// `bounds.origin.x`, which survives `.frame` reassignment (CALayer never touches
    /// `bounds.origin` when `.frame` is set) so vertical relayout never resets horizontal scroll.
    var codeBodyClipLayer: [LayerIdentity: CALayer] = [:]
    /// Full unclipped content width per code body, from `CodeBodyLayerContent.totalSize.width` --
    /// the clamp bound for horizontal scroll (`clip.bounds.size.width` is the viewport width).
    private var codeBodyContentWidth: [LayerIdentity: CGFloat] = [:]
    /// Identities `CodeBodyScrollAnimator` currently drives (drag/momentum/edge-spring in
    /// progress). While set, `reclampCodeBodyOffset` must not touch that identity's offset -- the
    /// animator is the ground-truth authority mid-animation (e.g. an intentional right-edge
    /// overdrag), and a layout/recolor pass clamping it back would yank the offset out from under
    /// the running spring. Set on `beginDrag`, cleared on `settle` -- see `setCodeBodyAnimating`.
    private var animatingCodeBodyIdentities: Set<LayerIdentity> = []
    private var codeBodyContentByFragmentID: [Int: CodeBodyLayerContent] = [:]
    /// Object identities are enough to detect a new immutable raster without retaining it twice.
    private var appliedRasterIdentityByFragmentID: [Int: ObjectIdentifier] = [:]
    var layerIdentityByFragmentID: [Int: LayerIdentity] = [:]
    /// Streaming-text reveal mask per hot block -- see `RenderCell+RevealMask.swift`. Removed
    /// once a reveal finishes so a sealed block's sublayer goes back to unmasked (no permanent
    /// offscreen-compositing cost on scroll).
    var revealMaskLayers: [LayerIdentity: CAGradientLayer] = [:]
    /// Bumped on every `applyRevealRegions` call for an identity so a stale animation-completion
    /// closure (from a reveal a later token already superseded) can no-op instead of nil-ing out
    /// a mask that a newer, still-running reveal owns.
    var revealGeneration: [LayerIdentity: Int] = [:]
    private var codeBackgroundByIdentity: [LayerIdentity: CodeBlockBackgroundDescriptor] = [:]
    /// Ordered frame metadata survives while offscreen block layers are released.
    /// It lets the scroll path find the next resident span without recreating the full cell.
    private var blockFragments: [Fragment] = []
    /// One non-overlapping search frame per logical block.
    private var blockFrames: [CGRect] = []
    /// `blockFragments` index range each `blockFrames` entry expands to.
    private var blockFragmentRanges: [Range<Int>] = []
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
    /// Set by `prepareForReuse`'s cross-item branch; forces `applyLayout`'s next call to run the
    /// full id-diff prune unconditionally, since a same-count id-set change (e.g. an image-only
    /// cell recycled into an image+text cell) can't be caught by a count comparison alone.
    private var needsSublayerReconcile = false

    enum ContentUpdatePolicy {
        case authoritative
        case incremental
    }

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

    /// Same item: cancel pending fetches only, contents stay. Cross item: also hard-cut
    /// contents/background and reset opacities (stale content from another item is a privacy
    /// bug). Cross-item recycle keeps the sublayer CALayer instances rather than reallocating
    /// them — `applyLayout` re-derives each cleared layer's content on the next call.
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
            for sub in codeTailSublayers.values { sub.contents = nil }
            for layers in codeChunkSublayers.values { layers.forEach { $0.contents = nil } }
            // A recycled cell must not inherit a different item's horizontal scroll position --
            // the clip layer instance survives recycle (like the sublayers above), only its offset resets.
            for clip in codeBodyClipLayer.values { clip.bounds.origin = .zero }
            mediaFragmentIDs.removeAll(keepingCapacity: true)
            placeholderPaintedFragmentIDs.removeAll(keepingCapacity: true)
            blockFragments.removeAll(keepingCapacity: true)
            blockFrames.removeAll(keepingCapacity: true)
            blockFragmentRanges.removeAll(keepingCapacity: true)
            activeBlockFragmentIDs.removeAll(keepingCapacity: true)
            codeBackgroundByIdentity.removeAll(keepingCapacity: true)
            codeBodyContentByFragmentID.removeAll(keepingCapacity: true)
            appliedRasterIdentityByFragmentID.removeAll(keepingCapacity: true)
            // Belt-and-suspenders: `returnToPool` already stops any animator targeting this cell
            // (via `cancelInFlightWork` -> `settle`) before it's dequeued for a new item, but a
            // stale flag here would silently disable reclamp for the new item's code body forever.
            animatingCodeBodyIdentities.removeAll(keepingCapacity: true)
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

    /// Geometry phase with optional synchronous content paint: image fragments whose id is in
    /// `synchronousContent` get their decoded CGImage applied inline (no Task, no fade, no gray
    /// tint), and if every image fragment is covered, contentLayer is revealed immediately.
    public func applyLayout(_ fragments: [Fragment], synchronousContent: [Int: CGImage]) {
        applyLayout(fragments, synchronousContent: synchronousContent, codeBodyContent: [:])
    }

    func missingRasterFragments(in fragments: [Fragment]) -> [Fragment] {
        fragments.filter { fragment in
            guard activeBlockFragmentIDs.contains(fragment.id) else { return false }
            switch fragment.content {
            case .text(let descriptor):
                guard case .none = descriptor.codeBlockRole else { return false }
            case .table, .mathBlock:
                break
            default:
                return false
            }
            return sublayers[layerIdentity(for: fragment)]?.contents == nil
        }
    }

    func applyLayout(
        _ fragments: [Fragment],
        synchronousContent: [Int: CGImage],
        codeBodyContent: [Int: CodeBodyLayerContent],
        contentUpdatePolicy: ContentUpdatePolicy = .authoritative
    ) {
        let cellBounds = CGRect(origin: .zero, size: layer.bounds.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Guard: skip CA needsLayout pipeline when bounds are unchanged
        if placeholderLayer.bounds.size != cellBounds.size {
            placeholderLayer.frame = cellBounds
            contentLayer.frame = cellBounds
        }

        // Prune sublayers no longer in the fragment set. Skip the id-diff (and its Set alloc)
        // unless forced by needsSublayerReconcile or the count strictly shrinks.
        if needsSublayerReconcile || sublayers.count > fragments.count {
            let incomingIdentities = Set(fragments.map(layerIdentity(for:)))
            let incomingIDs = Set(fragments.map(\.id))
            for identity in sublayers.keys.filter({ !incomingIdentities.contains($0) }) {
                sublayers[identity]?.removeFromSuperlayer()
                sublayers.removeValue(forKey: identity)
                codeTailSublayers.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeChunkSublayers.removeValue(forKey: identity)?.forEach { $0.removeFromSuperlayer() }
                codeBodyClipLayer.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeBodyContentWidth.removeValue(forKey: identity)
                codeBackgroundByIdentity.removeValue(forKey: identity)
                let removedIDs = layerIdentityByFragmentID.keys.filter { layerIdentityByFragmentID[$0] == identity }
                for id in removedIDs {
                    layerIdentityByFragmentID.removeValue(forKey: id)
                    mediaFragmentIDs.remove(id)
                    placeholderPaintedFragmentIDs.remove(id)
                    appliedRasterIdentityByFragmentID.removeValue(forKey: id)
                }
            }
            let inactiveIDs = layerIdentityByFragmentID.keys.filter { !incomingIDs.contains($0) }
            for id in inactiveIDs {
                layerIdentityByFragmentID.removeValue(forKey: id)
                mediaFragmentIDs.remove(id)
                placeholderPaintedFragmentIDs.remove(id)
                appliedRasterIdentityByFragmentID.removeValue(forKey: id)
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
                codeTailSublayers.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeChunkSublayers.removeValue(forKey: identity)?.forEach { $0.removeFromSuperlayer() }
                codeBodyClipLayer.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeBodyContentWidth.removeValue(forKey: identity)
                codeBodyContentByFragmentID.removeValue(forKey: fragment.id)
                if let image = synchronousContent[fragment.id] {
                    // Sync paint: image is already decoded — set contents inline.
                    // No gray tint (image is present), no CATransition (no delay to mask).
                    sub.contents = image
                    appliedRasterIdentityByFragmentID[fragment.id] = ObjectIdentifier(image)
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
            } else if case .codeBlockBackground(let descriptor) = fragment.content {
                codeTailSublayers.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeChunkSublayers.removeValue(forKey: identity)?.forEach { $0.removeFromSuperlayer() }
                codeBodyClipLayer.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeBodyContentWidth.removeValue(forKey: identity)
                codeBodyContentByFragmentID.removeValue(forKey: fragment.id)
                appliedRasterIdentityByFragmentID.removeValue(forKey: fragment.id)
                if codeBackgroundByIdentity[identity] != descriptor || sub.contents == nil {
                    sub.contents = rasterizeCodeBlockBackground(cornerRadius: descriptor.cornerRadius, color: descriptor.color)
                    sub.contentsCenter = codeBlockBackgroundContentsCenter(cornerRadius: descriptor.cornerRadius)
                    codeBackgroundByIdentity[identity] = descriptor
                }
                sub.backgroundColor = nil
                mediaFragmentIDs.remove(fragment.id)
                placeholderPaintedFragmentIDs.remove(fragment.id)
            } else if case .text(let descriptor) = fragment.content {
                if case .body = descriptor.codeBlockRole {
                    appliedRasterIdentityByFragmentID.removeValue(forKey: fragment.id)
                    if let incoming = codeBodyContent[fragment.id] {
                        codeBodyContentByFragmentID[fragment.id] = incoming
                    } else if contentUpdatePolicy == .authoritative {
                        codeBodyContentByFragmentID.removeValue(forKey: fragment.id)
                    }
                    let delivery = codeBodyContentByFragmentID[fragment.id]
                    let chunks = delivery?.chunks ?? []

                    // One clip container per code body, framed to the (now card-width-pinned)
                    // body fragment frame. `masksToBounds = true` here is a plain rectangular
                    // clip (cornerRadius stays 0) -- not corner rounding, so no offscreen render
                    // pass; the "no masksToBounds" invariant is about rounding, not this.
                    let clip: CALayer
                    if let existing = codeBodyClipLayer[identity] {
                        clip = existing
                    } else {
                        let l = CALayer()
                        l.masksToBounds = true
                        l.cornerRadius = 0
                        contentLayer.addSublayer(l)
                        codeBodyClipLayer[identity] = l
                        clip = l
                    }
                    // Setting `.frame` writes `bounds.size`/`position`, never `bounds.origin` --
                    // any horizontal scroll offset already on this layer survives this write.
                    if clip.frame != fragment.frame {
                        clip.frame = fragment.frame
                    }

                    // Chunk/tail layers are sublayers of `clip` at LOCAL coordinates (origin
                    // x=0) -- their own natural (possibly wide) size, never touched by scroll.
                    // Reconcile the chunk layers before creating the tail layer so a fresh
                    // mount's sublayer insertion order stacks chunk(s) then tail.
                    reconcileChunkLayers(identity: identity, chunks: chunks, into: clip, origin: .zero)
                    let tail: CALayer
                    if let existing = codeTailSublayers[identity] {
                        tail = existing
                    } else {
                        let layer = CALayer()
                        layer.masksToBounds = false
                        layer.cornerRadius = 0
                        clip.addSublayer(layer)
                        codeTailSublayers[identity] = layer
                        tail = layer
                    }
                    let sealedHeight = delivery?.sealedSize.height ?? 0
                    tail.contents = delivery?.tailImage
                    tail.frame = CGRect(
                        x: 0,
                        y: sealedHeight,
                        width: delivery?.tailSize.width ?? 0,
                        height: delivery?.tailSize.height ?? 0
                    )
                    let contentWidth = delivery?.totalSize.width ?? 0
                    codeBodyContentWidth[identity] = contentWidth
                    reclampCodeBodyOffset(identity: identity, clip: clip, contentWidth: contentWidth)
                    // `sub` is not painted for a code body -- the chunk layers carry the pixels --
                    // but it stays in `sublayers` so the generic prune/reconcile bookkeeping every
                    // fragment goes through keeps working unmodified.
                    sub.contents = nil
                    sub.frame = CGRect(origin: fragment.frame.origin, size: .zero)
                    sub.backgroundColor = nil
                    tail.backgroundColor = nil
                    mediaFragmentIDs.remove(fragment.id)
                    placeholderPaintedFragmentIDs.remove(fragment.id)
                    #if DEBUG
                    assertLayerInvariants(sub)
                    assertLayerInvariants(tail)
                    for chunkLayer in codeChunkSublayers[identity] ?? [] { assertLayerInvariants(chunkLayer) }
                    #endif
                    continue
                }
                codeTailSublayers.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeChunkSublayers.removeValue(forKey: identity)?.forEach { $0.removeFromSuperlayer() }
                codeBodyClipLayer.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeBodyContentWidth.removeValue(forKey: identity)
                codeBodyContentByFragmentID.removeValue(forKey: fragment.id)
                if let image = synchronousContent[fragment.id] {
                    sub.contents = image
                    appliedRasterIdentityByFragmentID[fragment.id] = ObjectIdentifier(image)
                } else if contentUpdatePolicy == .authoritative {
                    sub.contents = nil
                    appliedRasterIdentityByFragmentID.removeValue(forKey: fragment.id)
                }
                // An authoritative layout clears an absent bitmap after reclassification at the
                // same id; incremental viewport maps deliberately preserve absent entries.
                // INVARIANT: for text, `fragment.frame.size` MUST equal the bitmap's point size.
                // `contentsGravity` is unset → defaults to `.resize`, so any width/height mismatch
                // silently stretches the glyphs instead of failing (this was the "heading in a
                // stretched font" bug; producers keep them equal — see FeedScrollView.recordTextResult).
                // If a future mismatch slips in, set an explicit gravity or assert size-equality here.
                sub.backgroundColor = nil
                mediaFragmentIDs.remove(fragment.id)
                placeholderPaintedFragmentIDs.remove(fragment.id)
            } else if case .table(let descriptor) = fragment.content {
                codeChunkSublayers.removeValue(forKey: identity)?.forEach { $0.removeFromSuperlayer() }
                codeBodyContentByFragmentID.removeValue(forKey: fragment.id)

                // Same clip-layer-per-identity horizontal-scroll mechanism a code body's
                // `.codeBody` fragment mounts into (Variant B) -- generalized to any scrollable
                // content, not code-specific. A table has exactly one raster tile, so it reuses
                // `codeTailSublayers[identity]` as that single content layer instead of the
                // chunk-list machinery code bodies need for per-line streaming.
                let clip: CALayer
                if let existing = codeBodyClipLayer[identity] {
                    clip = existing
                } else {
                    let l = CALayer()
                    l.masksToBounds = true
                    l.cornerRadius = 0
                    contentLayer.addSublayer(l)
                    codeBodyClipLayer[identity] = l
                    clip = l
                }
                if clip.frame != fragment.frame {
                    clip.frame = fragment.frame
                }

                let content: CALayer
                if let existing = codeTailSublayers[identity] {
                    content = existing
                } else {
                    let l = CALayer()
                    l.masksToBounds = false
                    l.cornerRadius = 0
                    clip.addSublayer(l)
                    codeTailSublayers[identity] = l
                    content = l
                }
                content.frame = CGRect(origin: .zero, size: descriptor.naturalContentSize)
                if let image = synchronousContent[fragment.id] {
                    content.contents = image
                    appliedRasterIdentityByFragmentID[fragment.id] = ObjectIdentifier(image)
                } else if contentUpdatePolicy == .authoritative {
                    content.contents = nil
                    appliedRasterIdentityByFragmentID.removeValue(forKey: fragment.id)
                }
                content.backgroundColor = nil

                let contentWidth = descriptor.naturalContentSize.width
                codeBodyContentWidth[identity] = contentWidth
                reclampCodeBodyOffset(identity: identity, clip: clip, contentWidth: contentWidth)

                sub.contents = nil
                sub.frame = CGRect(origin: fragment.frame.origin, size: .zero)
                sub.backgroundColor = nil
                mediaFragmentIDs.remove(fragment.id)
                placeholderPaintedFragmentIDs.remove(fragment.id)
                #if DEBUG
                assertLayerInvariants(sub)
                assertLayerInvariants(content)
                #endif
                continue
            } else if case .mathBlock(let descriptor) = fragment.content {
                codeChunkSublayers.removeValue(forKey: identity)?.forEach { $0.removeFromSuperlayer() }
                codeBodyContentByFragmentID.removeValue(forKey: fragment.id)

                // Identical Variant B mechanism to the `.table` branch above -- a math block is
                // also exactly one raster tile, centered at raster time (see
                // MathBlockRasterizer.swift), so mounting needs no centering logic of its own.
                let clip: CALayer
                if let existing = codeBodyClipLayer[identity] {
                    clip = existing
                } else {
                    let l = CALayer()
                    l.masksToBounds = true
                    l.cornerRadius = 0
                    contentLayer.addSublayer(l)
                    codeBodyClipLayer[identity] = l
                    clip = l
                }
                if clip.frame != fragment.frame {
                    clip.frame = fragment.frame
                }

                let content: CALayer
                if let existing = codeTailSublayers[identity] {
                    content = existing
                } else {
                    let l = CALayer()
                    l.masksToBounds = false
                    l.cornerRadius = 0
                    clip.addSublayer(l)
                    codeTailSublayers[identity] = l
                    content = l
                }
                content.frame = CGRect(origin: .zero, size: descriptor.naturalContentSize)
                if let image = synchronousContent[fragment.id] {
                    content.contents = image
                    appliedRasterIdentityByFragmentID[fragment.id] = ObjectIdentifier(image)
                } else if contentUpdatePolicy == .authoritative {
                    content.contents = nil
                    appliedRasterIdentityByFragmentID.removeValue(forKey: fragment.id)
                }
                content.backgroundColor = nil

                let contentWidth = descriptor.naturalContentSize.width
                codeBodyContentWidth[identity] = contentWidth
                reclampCodeBodyOffset(identity: identity, clip: clip, contentWidth: contentWidth)

                sub.contents = nil
                sub.frame = CGRect(origin: fragment.frame.origin, size: .zero)
                sub.backgroundColor = nil
                mediaFragmentIDs.remove(fragment.id)
                placeholderPaintedFragmentIDs.remove(fragment.id)
                #if DEBUG
                assertLayerInvariants(sub)
                assertLayerInvariants(content)
                #endif
                continue
            } else {
                codeTailSublayers.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeChunkSublayers.removeValue(forKey: identity)?.forEach { $0.removeFromSuperlayer() }
                codeBodyClipLayer.removeValue(forKey: identity)?.removeFromSuperlayer()
                codeBodyContentWidth.removeValue(forKey: identity)
                codeBodyContentByFragmentID.removeValue(forKey: fragment.id)
                appliedRasterIdentityByFragmentID.removeValue(forKey: fragment.id)
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

        // Reveal any already-paintable text immediately. The full-cell gradient must not cover
        // it while an unrelated image is still loading; that image keeps its own gray tint.
        let hasPaintedText = fragments.contains { fragment in
            if case .text(let descriptor) = fragment.content {
                if case .body = descriptor.codeBlockRole { return codeBodyContent[fragment.id] != nil }
                return synchronousContent[fragment.id] != nil
            }
            return false
        }
        let allMediaReady = !mediaFragmentIDs.isEmpty
            && mediaFragmentIDs.allSatisfy({ layer(for: $0)?.contents != nil })

        // A fully synchronous image mount also reveals immediately, without a fade.
        // Must run inside setDisableActions(true) so the opacity changes are instant.
        if hasPaintedText || allMediaReady {
            if allMediaReady {
                allMediaLoaded = true
            }
            placeholderLayer.opacity = 0
            contentLayer.opacity = 1
        }

        CATransaction.commit()
    }

    /// Hides the full-cell gray gradient for an empty mount of a media-free item, so a brand-new
    /// text message (e.g. a streaming chat reply) doesn't flash gray for the one async gap before
    /// its first text raster lands. Only affects that empty window: the later real-content delivery
    /// drives placeholder/content opacity itself (see `applyLayout`), and a cross-item recycle
    /// re-raises the placeholder in `prepareForReuse`. Media items skip this — the gray box is their
    /// intended loading affordance.
    func suppressPlaceholderForEmptyMount() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderLayer.opacity = 0
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
        updateBlockViewport(
            fragments: fragments, viewportInCell: viewportInCell,
            synchronousContent: synchronousContent, codeBodyContent: [:]
        )
    }

    func updateBlockViewport(
        fragments: [Fragment],
        viewportInCell: CGRect,
        synchronousContent: [Int: CGImage],
        codeBodyContent: [Int: CodeBodyLayerContent]
    ) -> [Fragment] {
        blockFragments = fragments
        blockFrames = []
        blockFragmentRanges = []
        blockFrames.reserveCapacity(fragments.count)
        blockFragmentRanges.reserveCapacity(fragments.count)
        var index = 0
        while index < fragments.count {
            let fragment = fragments[index]
            if isCodeBlockTriple(fragments, startingAt: index) {
                blockFrames.append(fragment.frame)
                blockFragmentRanges.append(index..<(index + 3))
                index += 3
            } else {
                blockFrames.append(fragment.frame)
                blockFragmentRanges.append(index..<(index + 1))
                index += 1
            }
        }
        activeBlockFragmentIDs.removeAll(keepingCapacity: true)
        return updateBlockViewport(
            viewportInCell: viewportInCell,
            synchronousContent: synchronousContent,
            codeBodyContent: codeBodyContent,
            contentUpdatePolicy: .authoritative
        )
    }

    /// Updates residency from already-recorded layout metadata. This is the scroll-path entry
    /// point: binary search plus the newly active blocks, with no full-fragment scan.
    @discardableResult
    public func updateBlockViewport(
        viewportInCell: CGRect,
        synchronousContent: [Int: CGImage]
    ) -> [Fragment] {
        updateBlockViewport(
            viewportInCell: viewportInCell, synchronousContent: synchronousContent, codeBodyContent: [:]
        )
    }

    func updateBlockViewport(
        viewportInCell: CGRect,
        synchronousContent: [Int: CGImage],
        codeBodyContent: [Int: CodeBodyLayerContent]
    ) -> [Fragment] {
        updateBlockViewport(
            viewportInCell: viewportInCell,
            synchronousContent: synchronousContent,
            codeBodyContent: codeBodyContent,
            contentUpdatePolicy: .incremental
        )
    }

    private func updateBlockViewport(
        viewportInCell: CGRect,
        synchronousContent: [Int: CGImage],
        codeBodyContent: [Int: CodeBodyLayerContent],
        contentUpdatePolicy: ContentUpdatePolicy
    ) -> [Fragment] {
        guard !blockFragments.isEmpty else { return [] }

        let groupRange = BlockViewportRange.activeRange(in: blockFrames, window: viewportInCell)
        let range = groupRange.isEmpty
            ? 0..<0
            : blockFragmentRanges[groupRange.lowerBound].lowerBound..<blockFragmentRanges[groupRange.upperBound - 1].upperBound
        let active = Array(blockFragments[range])
        let nextIDs = Set(active.map(\.id))
        let idsChanged = nextIDs != activeBlockFragmentIDs
        let hasNewContent = hasUnappliedContent(
            activeIDs: nextIDs,
            synchronousContent: synchronousContent,
            codeBodyContent: codeBodyContent
        )
        guard idsChanged || hasNewContent else { return [] }

        let enteringIDs: Set<Int>
        if idsChanged {
            enteringIDs = nextIDs.subtracting(activeBlockFragmentIDs)
            let leavingIDs = activeBlockFragmentIDs.subtracting(nextIDs)
            cancelPendingMedia(for: leavingIDs)
            activeBlockFragmentIDs = nextIDs

            // The active set can change without changing its count, so force the exact id diff.
            needsSublayerReconcile = true
        } else {
            enteringIDs = []
        }
        applyLayout(
            active,
            synchronousContent: synchronousContent,
            codeBodyContent: codeBodyContent,
            contentUpdatePolicy: contentUpdatePolicy
        )
        return active.filter { enteringIDs.contains($0.id) }
    }

    private func hasUnappliedContent(
        activeIDs: Set<Int>,
        synchronousContent: [Int: CGImage],
        codeBodyContent: [Int: CodeBodyLayerContent]
    ) -> Bool {
        for (id, image) in synchronousContent where activeIDs.contains(id) {
            if appliedRasterIdentityByFragmentID[id] != ObjectIdentifier(image) {
                return true
            }
        }
        for (id, content) in codeBodyContent where activeIDs.contains(id) {
            guard let applied = codeBodyContentByFragmentID[id], codeBodyContentMatches(applied, content) else {
                return true
            }
        }
        return false
    }

    private func codeBodyContentMatches(_ lhs: CodeBodyLayerContent, _ rhs: CodeBodyLayerContent) -> Bool {
        guard lhs.chunks.count == rhs.chunks.count,
              lhs.tailSize == rhs.tailSize,
              lhs.sealedSize == rhs.sealedSize,
              sameImage(lhs.tailImage, rhs.tailImage)
        else { return false }
        for index in lhs.chunks.indices {
            let left = lhs.chunks[index]
            let right = rhs.chunks[index]
            if left.size != right.size || !sameImage(left.image, right.image) {
                return false
            }
        }
        return true
    }

    private func sameImage(_ lhs: CGImage?, _ rhs: CGImage?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return left === right
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    // MARK: - Content

    /// Which placeholder a real-image `applyContent` delivery replaced — lets callers
    /// distinguish a gray→image transition from a thumbnail/BlurHash→image one.
    public enum ContentTransitionKind: Sendable, Equatable {
        case fromGrayPlaceholder
        case fromThumbnailPlaceholder
    }

    /// Apply a pre-decoded BGRA8888-normalised image. Crossfades over 0.2s via CATransition
    /// (`CALayer.contents` has no default CA action, so an instant swap would otherwise occur),
    /// then fades out the placeholder once all image fragments have arrived.
    ///
    /// `itemID` must match `currentItemID` — this rejects stale callbacks racing a cross-item
    /// recycle so another item's image can never paint on this cell. Returns nil if rejected or
    /// the fragment id has no sublayer.
    @discardableResult
    public func applyContent(id: Int, image: CGImage, for itemID: AnyHashable) -> ContentTransitionKind? {
        // Privacy guard: reject stale callbacks from a previous item's fetch.
        // nil currentItemID means the cell is fresh/unbound — any delivery is accepted.
        if let currentID = currentItemID, currentID != itemID {
            RenderCell._privacyGuardFiredCount += 1
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
        appliedRasterIdentityByFragmentID[id] = ObjectIdentifier(image)

        // Clear placeholder tint without animating it
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sub.backgroundColor = nil
        CATransaction.commit()

        fadeOutPlaceholderIfAllReady()

        RenderCell._debugApplyContentCount += 1

        return transitionKind
    }

    /// Applies a late-arriving recolored composite for a still-hot code block's body tile.
    /// Colorizing never changes a line's measured size (same font, same text, only color), so
    /// Updates the sealed bitmap and positions the tail directly below it. No crossfade: recoloring
    /// already-visible text doesn't need one.
    ///
    /// `itemID` must match `currentItemID`, mirroring `applyContent`'s cross-item privacy guard
    /// against a stale callback racing a recycle.
    @discardableResult
    func applyCodeBodyTile(id: Int, content: CodeBodyLayerContent, for itemID: AnyHashable) -> Bool {
        if let currentID = currentItemID, currentID != itemID {
            RenderCell._privacyGuardFiredCount += 1
            return false
        }
        guard let identity = layerIdentityByFragmentID[id], let clip = codeBodyClipLayer[identity],
              let tail = codeTailSublayers[identity]
        else { return false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        codeBodyContentByFragmentID[id] = content
        // Chunk/tail layers live at LOCAL coordinates inside `clip` -- see the code-body branch
        // of `applyLayout`. `clip.bounds.origin.x` (the horizontal scroll offset) is untouched.
        reconcileChunkLayers(identity: identity, chunks: content.chunks, into: clip, origin: .zero)
        tail.contents = content.tailImage
        tail.frame = CGRect(origin: CGPoint(x: 0, y: content.sealedSize.height), size: content.tailSize)
        codeBodyContentWidth[identity] = content.totalSize.width
        reclampCodeBodyOffset(identity: identity, clip: clip, contentWidth: content.totalSize.width)
        CATransaction.commit()
        return true
    }

    // MARK: - Code Body Horizontal Scroll (hot path -- never awaits)
    //
    // Despite the "code body" naming (kept to avoid an unrelated rename churning this file),
    // every method/dictionary below is generic over `LayerIdentity` and is shared by a table's
    // `.table` fragment (see the `applyLayout` branch above) -- Variant B (clip-layer
    // `bounds.origin.x` shift) applies identically to both, per TABLE_RENDER_DESIGN.md
    // "Horizontal scroll": tables reuse the code-body scroll machinery rather than forking a
    // parallel one.

    /// Locates a scrollable code body's clip layer under `point` (cell-local coordinates,
    /// matching `Fragment.frame`'s space). Skips bodies whose content already fits the viewport
    /// -- nothing to scroll, so the touch falls through to vertical scroll instead. O(resident
    /// code bodies in this cell), no allocation.
    func codeBodyIdentity(at point: CGPoint) -> LayerIdentity? {
        for (identity, clip) in codeBodyClipLayer where clip.frame.contains(point) {
            let contentWidth = codeBodyContentWidth[identity] ?? clip.bounds.width
            guard contentWidth > clip.bounds.width + 0.5 else { continue }
            return identity
        }
        return nil
    }

    /// Snapshot of one code body's current horizontal scroll metrics, read by
    /// `CodeBodyScrollAnimator` once per gesture-begin and once per animation tick.
    struct ScrollBoundaryInfo: Equatable {
        let offset: CGFloat
        let contentWidth: CGFloat
        let viewportWidth: CGFloat
    }

    /// Current offset/content/viewport metrics for one resident code body, or `nil` if `identity`
    /// no longer names a mounted code body in this cell (fragment pruned, recycled away, or never
    /// a code body). The animator treats `nil` as "target invalidated, stop."
    func scrollBoundaryInfo(for identity: LayerIdentity) -> ScrollBoundaryInfo? {
        guard let clip = codeBodyClipLayer[identity] else { return nil }
        let contentWidth = codeBodyContentWidth[identity] ?? clip.bounds.width
        return ScrollBoundaryInfo(offset: clip.bounds.origin.x, contentWidth: contentWidth, viewportWidth: clip.bounds.width)
    }

    /// Writes an absolute presented offset for `identity`'s clip layer. Pure `bounds.origin.x`
    /// write under a disabled-action transaction -- no allocation, no await; the entire hot path
    /// for a code-body drag/momentum/spring tick.
    ///
    /// Rejects (returns `false`, no write) when `itemID` no longer matches `currentItemID` --
    /// the same privacy-guard shape as `applyContent`'s cross-item check, so a stale animator
    /// tick racing a recycle can never move a different item's code body -- or when `identity`
    /// no longer names a mounted code body (fragment pruned or recycled away).
    @discardableResult
    func setCodeBodyOffset(_ offset: CGFloat, identity: LayerIdentity, itemID: AnyHashable) -> Bool {
        if let currentID = currentItemID, currentID != itemID {
            RenderCell._privacyGuardFiredCount += 1
            return false
        }
        guard let clip = codeBodyClipLayer[identity] else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.bounds.origin.x = offset
        CATransaction.commit()
        return true
    }

    /// Marks whether `CodeBodyScrollAnimator` currently owns `identity`'s offset -- called from
    /// `beginDrag`/`settle`. `reclampCodeBodyOffset` reads this to stay out of the animator's way.
    func setCodeBodyAnimating(_ animating: Bool, identity: LayerIdentity) {
        if animating {
            animatingCodeBodyIdentities.insert(identity)
        } else {
            animatingCodeBodyIdentities.remove(identity)
        }
    }

    /// Re-clamps a code body's stored scroll offset to `[0, max(0, contentWidth - viewportWidth)]`
    /// after either shrinks (a re-tokenize shortening the widest line, or a viewport resize) --
    /// otherwise the offset could keep pointing past the new content edge. Call inside an
    /// already-open disabled-action transaction; this performs no transaction of its own.
    ///
    /// Skipped while `CodeBodyScrollAnimator` is driving this identity (see
    /// `animatingCodeBodyIdentities`) -- an active right-edge overdrag/spring is legitimately
    /// past `maxOffset`, and clamping it here mid-animation would yank the offset out from under
    /// the animator's next tick. The animator's own settle writes an in-range offset, so nothing
    /// is missed once it's done.
    private func reclampCodeBodyOffset(identity: LayerIdentity, clip: CALayer, contentWidth: CGFloat) {
        guard !animatingCodeBodyIdentities.contains(identity) else { return }
        let maxOffset = max(0, contentWidth - clip.bounds.width)
        if clip.bounds.origin.x > maxOffset {
            clip.bounds.origin.x = maxOffset
        }
    }

    // MARK: - Media Handles

    /// Register a Task token for a pending image fetch. The Task's body must capture this cell
    /// weakly to avoid a retain cycle that outlives cancellation.
    func addMediaHandle(_ handle: MediaHandle) {
        mediaHandles.append(handle)
    }

    /// Registers a fetch owned by one resident block so leaving that block cancels it eagerly.
    func addMediaHandle(_ handle: MediaHandle, for fragmentID: Int) {
        mediaHandlesByFragmentID[fragmentID, default: []].append(handle)
    }

    /// Cancel all pending media fetch Tasks without clearing sublayer contents — call at recycle
    /// time to release decode slots immediately; `prepareForReuse` clears content later.
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

    /// Renders a fragment's first-paint placeholder via `placeholderRenderer`, trying thumbnail,
    /// then BlurHash, then a custom payload, in that order. Runs synchronously on MainActor —
    /// only call when `sub.contents == nil`.
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
        fragment.blockID.map { .block($0) } ?? .positional(fragment.id)
    }

    private func isCodeBlockTriple(_ fragments: [Fragment], startingAt index: Int) -> Bool {
        guard index + 2 < fragments.count,
              case .codeBlockBackground = fragments[index].content,
              case .text(let header) = fragments[index + 1].content,
              case .header = header.codeBlockRole,
              case .text(let body) = fragments[index + 2].content,
              case .body = body.codeBlockRole
        else { return false }
        return true
    }

    private func layer(for fragmentID: Int) -> CALayer? {
        guard let identity = layerIdentityByFragmentID[fragmentID] else { return nil }
        return sublayers[identity]
    }
}
#endif

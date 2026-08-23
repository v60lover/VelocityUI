// RenderEnvironment.swift

#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Composition root for all long-lived VelocityUI collaborators.
///
/// One instance per AsyncFeed, constructed once and injected downstream by initializer.
/// No component should reach outside its own init parameters to obtain a collaborator.
///
/// DI contracts enforced by the designated init:
/// - `imageActor.dimensionCache === dimensionCache` (same instance)
/// - `videoController.videoPreparation === videoPreparation` (same instance)
public final class RenderEnvironment: Sendable {
    public let textPool: TextMeasurementPool
    public let layoutCache: LayoutCache
    public let dimensionCache: DimensionCache
    public let imageActor: ImageActor
    public let gifActor: GIFActor
    public let videoController: VideoController
    public let videoPreparation: VideoPreparationActor

    /// The working-range / LRU-bounded cache for frozen block bitmaps. A lock-guarded `final class`,
    /// not an actor — the MainActor bind/scroll path reads it synchronously, with zero `await`.
    public let frozenBitmapStore: FrozenBitmapStore

    /// Per-feed ownership for artifacts actively mounted by the scroll view. This deliberately
    /// has no hard eviction ceiling; `FrozenBitmapStore` owns only inactive, reusable entries.
    public let visibleBlockStore: VisibleBlockStore

    /// Per-`BlockKey` lifecycle owner for the incremental hot-tail text rasterizer. `@MainActor final
    /// class`, not `Sendable` — touched only from `FeedScrollView`'s synchronous MainActor scroll-path.
    public let hotBlockRasterizerStore: HotBlockRasterizerStore

    /// Gates the trailing hot block between the O(appended) incremental path
    /// (`hotBlockRasterizerStore.append`) and the O(block) fallback (a full `rasterizeText` pass
    /// every append). `true` in every production call site — exists so BenchmarkHost can compare
    /// ON-vs-OFF cost; not a runtime feature flag consumers are expected to toggle.
    public let hotBlockRasterizeEnabled: Bool

    /// Produces a fragment's first-paint image before its real image has decoded. Defaults to
    /// `DefaultPlaceholderRenderer` (thumbnail/BlurHash) — inject a different `PlaceholderRenderer`
    /// for a custom first-paint strategy.
    public let placeholderRenderer: any PlaceholderRenderer

    /// Fires after each successful async `RenderCell.applyContent` delivery, carrying which
    /// placeholder path it replaced. Routes benchmark/debug instrumentation through the composition
    /// root instead of `#if DEBUG` hooks on library types, which would compile into every consumer
    /// DEBUG build. `nil` in production. Never fires for the synchronous mount-time paint path.
    public let contentDeliveryObserver: (@Sendable (RenderCell.ContentTransitionKind) -> Void)?

    /// Fires once per pipeline `Task` spawned by `FeedScrollView.notifyPipelineIfNeeded`, called
    /// synchronously on `@MainActor` at the spawn site — before the `Task` body runs — so a
    /// BenchmarkHost observer can attribute the event to the frame it was triggered in. `nil` in
    /// production.
    public let pipelineTaskSpawnObserver: (@Sendable () -> Void)?

    /// Designated init — all collaborators supplied by the caller. `nonisolated`, callable from any
    /// context — tests substituting a fake `ImageActor`/`VideoController` must use this instead of
    /// the `@MainActor` convenience init.
    ///
    /// Enforces two identity DI contracts at runtime: `imageActor.dimensionCache === dimensionCache`
    /// (separate instances break `classify()`'s hit contract) and
    /// `videoController.videoPreparation === videoPreparation` (must share one actor).
    public init(
        textPool: TextMeasurementPool,
        layoutCache: LayoutCache,
        dimensionCache: DimensionCache,
        imageActor: ImageActor,
        gifActor: GIFActor,
        videoController: VideoController,
        videoPreparation: VideoPreparationActor,
        frozenBitmapStore: FrozenBitmapStore,
        visibleBlockStore: VisibleBlockStore = .init(),
        hotBlockRasterizerStore: HotBlockRasterizerStore,
        hotBlockRasterizeEnabled: Bool = true,
        placeholderRenderer: any PlaceholderRenderer = DefaultPlaceholderRenderer(),
        contentDeliveryObserver: (@Sendable (RenderCell.ContentTransitionKind) -> Void)? = nil,
        pipelineTaskSpawnObserver: (@Sendable () -> Void)? = nil
    ) {
        precondition(
            imageActor.dimensionCache === dimensionCache,
            "RenderEnvironment: imageActor.dimensionCache must be the same instance as dimensionCache — separate instances break the classify() hit contract"
        )
        precondition(
            videoController.videoPreparation === videoPreparation,
            "RenderEnvironment: videoController.videoPreparation must be the same instance as videoPreparation"
        )
        self.textPool = textPool
        self.layoutCache = layoutCache
        self.dimensionCache = dimensionCache
        self.imageActor = imageActor
        self.gifActor = gifActor
        self.videoController = videoController
        self.videoPreparation = videoPreparation
        self.frozenBitmapStore = frozenBitmapStore
        self.visibleBlockStore = visibleBlockStore
        self.hotBlockRasterizerStore = hotBlockRasterizerStore
        self.hotBlockRasterizeEnabled = hotBlockRasterizeEnabled
        self.placeholderRenderer = placeholderRenderer
        self.contentDeliveryObserver = contentDeliveryObserver
        self.pipelineTaskSpawnObserver = pipelineTaskSpawnObserver
    }

    /// Convenience init for app use. `@MainActor` because `VideoController.init` is `@MainActor`
    /// — tests substituting a `FakeImageActor`/`FakeVideoController` must use the nonisolated
    /// designated init instead.
    ///
    /// Auto-wires: `session` into both `DimensionCache` and `ImageActor` (shared HTTP/2 connection
    /// pool); the same `DimensionCache` into `imageActor`; the same `VideoPreparationActor` into both
    /// `videoController` and `videoPreparation`; a fresh `FrozenBitmapStore`/`HotBlockRasterizerStore`
    /// at default budget — pass either explicitly to share one across a caller-managed graph.
    @MainActor
    public convenience init(
        textPool: TextMeasurementPool = .init(),
        layoutCache: LayoutCache = .init(),
        session: URLSession = .shared,
        gifActor: GIFActor = .init(),
        maxAttached: Int = 3,
        decodeScaleCeiling: CGFloat = 2.0,
        frozenBitmapStore: FrozenBitmapStore = .init(),
        visibleBlockStore: VisibleBlockStore = .init(),
        hotBlockRasterizerStore: HotBlockRasterizerStore = .init(),
        hotBlockRasterizeEnabled: Bool = true,
        placeholderRenderer: any PlaceholderRenderer = DefaultPlaceholderRenderer(),
        contentDeliveryObserver: (@Sendable (RenderCell.ContentTransitionKind) -> Void)? = nil,
        pipelineTaskSpawnObserver: (@Sendable () -> Void)? = nil
    ) {
        let dc = DimensionCache(session: session)
        let videoPrep = VideoPreparationActor()
        self.init(
            textPool: textPool,
            layoutCache: layoutCache,
            dimensionCache: dc,
            imageActor: ImageActor(session: session, dimensionCache: dc, decodeScaleCeiling: decodeScaleCeiling),
            gifActor: gifActor,
            videoController: VideoController(videoPreparation: videoPrep, maxAttached: maxAttached),
            videoPreparation: videoPrep,
            frozenBitmapStore: frozenBitmapStore,
            visibleBlockStore: visibleBlockStore,
            hotBlockRasterizerStore: hotBlockRasterizerStore,
            hotBlockRasterizeEnabled: hotBlockRasterizeEnabled,
            placeholderRenderer: placeholderRenderer,
            contentDeliveryObserver: contentDeliveryObserver,
            pipelineTaskSpawnObserver: pipelineTaskSpawnObserver
        )
    }
}
#endif

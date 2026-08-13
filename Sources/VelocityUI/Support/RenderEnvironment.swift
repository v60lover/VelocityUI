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

    /// The working-range / LRU-bounded cache for frozen block bitmaps (VelocityUI-qc7 phase B).
    /// See `FrozenBitmapStore`'s doc for why it is a lock-guarded `final class`, not an actor —
    /// the MainActor bind/scroll path reads it synchronously, with zero `await`.
    public let frozenBitmapStore: FrozenBitmapStore

    /// Produces a fragment's first-paint image before its real image has decoded. Defaults
    /// to `DefaultPlaceholderRenderer` (thumbnail/BlurHash, VelocityUI's original behavior) —
    /// inject a different `PlaceholderRenderer` to plug in a custom first-paint strategy. See
    /// `PlaceholderRenderer`'s docstring for the synchronous MainActor contract every
    /// implementation must honor.
    public let placeholderRenderer: any PlaceholderRenderer

    /// Fires after each successful async `RenderCell.applyContent` delivery, carrying which
    /// placeholder path it replaced. Routes benchmark/debug instrumentation through the
    /// composition root instead of `#if DEBUG` hooks on library types — those compile into
    /// every consumer DEBUG build (QA, TestFlight), not just BenchmarkHost. `nil` in
    /// production; BenchmarkHost passes a closure that dispatches to its harness counters.
    /// Never fires for the synchronous mount-time paint path (cache-hit at mount bypasses
    /// `applyContent` entirely — see `RenderCell._debugIsContentRevealed`'s docstring).
    public let contentDeliveryObserver: (@Sendable (RenderCell.ContentTransitionKind) -> Void)?

    /// Fires once per pipeline `Task` spawned by `FeedScrollView.notifyPipelineIfNeeded`
    /// (one leading-index boundary crossing). Called synchronously, on `@MainActor`, at the
    /// spawn site — before the `Task` body runs — so a BenchmarkHost observer can attribute
    /// the event to the frame in which it was triggered. Routes instrumentation through the
    /// composition root for the same reason as `contentDeliveryObserver`: `#if DEBUG` hooks on
    /// library types would compile into every consumer DEBUG build, not just BenchmarkHost.
    /// `nil` in production.
    public let pipelineTaskSpawnObserver: (@Sendable () -> Void)?

    /// Designated init — all collaborators supplied by the caller.
    ///
    /// Enforces two identity DI contracts at runtime:
    /// - `imageActor.dimensionCache === dimensionCache`: ImageActor writes raw source
    ///   dimensions at decode time; classify() reads from the same store. Separate
    ///   instances break the cache-hit contract (DimensionCache.swift:11–17).
    /// - `videoController.videoPreparation === videoPreparation`: VideoController and
    ///   the preparation pipeline must share the same actor (Phase 4 invariant).
    ///
    /// Tests that need to substitute a fake `ImageActor` or `VideoController` must use
    /// this init — it is nonisolated and callable from any context, unlike the
    /// `@MainActor` convenience init.
    public init(
        textPool: TextMeasurementPool,
        layoutCache: LayoutCache,
        dimensionCache: DimensionCache,
        imageActor: ImageActor,
        gifActor: GIFActor,
        videoController: VideoController,
        videoPreparation: VideoPreparationActor,
        frozenBitmapStore: FrozenBitmapStore,
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
        self.placeholderRenderer = placeholderRenderer
        self.contentDeliveryObserver = contentDeliveryObserver
        self.pipelineTaskSpawnObserver = pipelineTaskSpawnObserver
    }

    /// Convenience init for app use.
    ///
    /// `@MainActor` because `VideoController.init` is `@MainActor`. Tests that need
    /// to substitute a `FakeImageActor` or `FakeVideoController` must use the
    /// designated init instead — it is nonisolated and callable from any context.
    ///
    /// Auto-wires:
    /// - `session` into both `DimensionCache` and `ImageActor`, satisfying the
    ///   shared HTTP/2 connection pool contract (DimensionCache.swift:15–17).
    /// - The same `DimensionCache` instance into `imageActor` (DI contract).
    /// - The same `VideoPreparationActor` into both `videoController` and `videoPreparation`.
    /// - `decodeScaleCeiling` into `imageActor` — see `ImageActor.decodeScaleCeiling`'s
    ///   docstring for why 2.0 is the default (VelocityUI-zgs).
    /// - A fresh `FrozenBitmapStore` at its own default byte budget — pass `frozenBitmapStore`
    ///   to inject a store with a custom budget or to share one across a caller-managed graph.
    @MainActor
    public convenience init(
        textPool: TextMeasurementPool = .init(),
        layoutCache: LayoutCache = .init(),
        session: URLSession = .shared,
        gifActor: GIFActor = .init(),
        maxAttached: Int = 3,
        decodeScaleCeiling: CGFloat = 2.0,
        frozenBitmapStore: FrozenBitmapStore = .init(),
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
            placeholderRenderer: placeholderRenderer,
            contentDeliveryObserver: contentDeliveryObserver,
            pipelineTaskSpawnObserver: pipelineTaskSpawnObserver
        )
    }
}
#endif

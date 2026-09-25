// RasterDiagnostics.swift

import Foundation

/// The raster content category used by `RasterDiagnosticsEvent`.
public enum RasterDiagnosticFragmentKind: String, Sendable {
    case text
    case table
    case mathBlock
}

/// A feed-scoped diagnostic emitted while raster artifacts are looked up, restored, evicted, or
/// fail to paint. Repair `candidateKeys` are every raster-required fragment in scheduled items,
/// not a per-key miss set. Events contain only cache identity and accounting data, never node text.
public enum RasterDiagnosticsEvent: Sendable {
    case rasterMiss(
        key: BlockKey,
        kind: RasterDiagnosticFragmentKind,
        inVisibleStore: Bool,
        inFrozenStore: Bool
    )
    case repairStarted(indices: [Int], candidateKeys: [BlockKey])
    case repairFinished(
        indices: [Int],
        candidateKeys: [BlockKey],
        storedKeys: [BlockKey],
        missingKeys: [BlockKey]
    )
    case frozenBitmapEvicted(
        key: BlockKey,
        cost: Int,
        currentByteTotal: Int,
        byteBudget: Int
    )
    case repaintMissing(key: BlockKey, kind: RasterDiagnosticFragmentKind)
    /// A raster lookup on the mount path found the bitmap; `fromFrozenStore` means it was promoted
    /// out of `FrozenBitmapStore` rather than already being resident.
    case rasterHit(key: BlockKey, kind: RasterDiagnosticFragmentKind, fromFrozenStore: Bool)
    /// A cell mounted with no layout entry. `placeholderVisible` is false for media-free items,
    /// whose gray gradient is suppressed.
    case emptyLayoutMount(index: Int, placeholderVisible: Bool)
    /// Once per mount pass: how many mounted cells currently show the full-cell gray gradient.
    case placeholderExposure(visibleCellCount: Int)
    /// The pipeline resolved an item's layout: `recomputed` is true when `LayoutCache` missed and
    /// the item was measured from scratch.
    case layoutResolved(index: Int, recomputed: Bool)
    /// One image request outcome inside `ImageActor`.
    case imageRequest(ImageRequestOutcome)
    /// A cold-archive lookup for a sealed raster. Emitted by the archive tier only.
    case coldArchiveLookup(key: BlockKey, hit: Bool)
    /// A hot-render request moved through the scheduler. `generation` is per key and only set for tables.
    case hotRenderPhase(HotRenderPhase, key: BlockKey, kind: RasterDiagnosticFragmentKind, generation: Int)
    /// Pixels produced by one hot raster pass. `copiedPixelArea` is the part blitted from the
    /// retained image instead of redrawn; the rest of `pixelWidth * pixelHeight` was redrawn.
    case rasterWork(
        key: BlockKey, kind: RasterDiagnosticFragmentKind,
        pixelWidth: Int, pixelHeight: Int, copiedPixelArea: Int
    )
    /// Text-measure calls one hot render made.
    case measureCalls(key: BlockKey, kind: RasterDiagnosticFragmentKind, count: Int)
}

/// Stages of a hot table render, in the order a request normally passes them.
public enum HotRenderPhase: Sendable {
    case submitted
    case replacedPending
    case started
    case delivered
    case droppedStale
}

/// Where an `ImageActor` request was satisfied. Carries no URL.
public enum ImageRequestOutcome: Sendable {
    case decodedHit
    case networkFetch
    case localFileRead
}

/// Receives optional feed-local raster diagnostics. Keep the callback short because selected
/// events originate on the synchronous scroll path.
public struct RasterDiagnosticsObserver: Sendable {
    private let receive: @Sendable (RasterDiagnosticsEvent) -> Void

    public init(_ receive: @escaping @Sendable (RasterDiagnosticsEvent) -> Void) {
        self.receive = receive
    }

    func emit(_ event: RasterDiagnosticsEvent) {
        receive(event)
    }
}

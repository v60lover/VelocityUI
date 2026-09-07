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

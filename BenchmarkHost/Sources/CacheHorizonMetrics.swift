// CacheHorizonMetrics.swift

import Foundation
import os
import VelocityUI

/// Accounting-only counters for the cache-horizon scenario. Holds no node text, URLs or bytes.
struct CacheHorizonCounters: Codable, Equatable, Sendable {
    var emptyLayoutMounts = 0
    var emptyLayoutMountsWithGradient = 0
    var rasterHitsResident = 0
    var rasterHitsFromFrozenStore = 0
    var visibleRasterMisses = 0
    var gradientFrames = 0
    var gradientCellFrames = 0
    var coldArchiveHits = 0
    var coldArchiveMisses = 0
    var layoutCacheHits = 0
    var layoutRecomputes = 0
    var imageDecodedHits = 0
    var imageNetworkRequests = 0
    var imageLocalReads = 0
    var rasterRepairs = 0
    var frozenEvictions = 0
}

enum CacheHorizonPhase: String, Codable, Sendable {
    case forward
    case reverse
}

struct CacheHorizonReport: Codable, Equatable, Sendable {
    var itemCount: Int
    var forward: CacheHorizonCounters
    var reverse: CacheHorizonCounters
    var peakFrozenStoreBytes: Int
    var peakPhysFootprintBytes: Int
    /// Empty-layout mounts plus visible raster misses seen while reverse-scrolling content that was
    /// already rendered once. Non-zero means the user saw a reload.
    var visibleReloadCount: Int
}

/// Folds `RasterDiagnosticsEvent`s into per-phase counters. Events arrive from the main actor,
/// pipeline tasks and the image actor, so state sits behind a lock.
final class CacheHorizonMetrics: Sendable {
    private struct State {
        var phase: CacheHorizonPhase = .forward
        var forward = CacheHorizonCounters()
        var reverse = CacheHorizonCounters()
        var peakFrozenStoreBytes = 0
        var peakPhysFootprintBytes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setPhase(_ phase: CacheHorizonPhase) {
        state.withLock { $0.phase = phase }
    }

    func record(_ event: RasterDiagnosticsEvent) {
        state.withLock { st in
            switch st.phase {
            case .forward: Self.fold(event, into: &st.forward, peak: &st.peakFrozenStoreBytes)
            case .reverse: Self.fold(event, into: &st.reverse, peak: &st.peakFrozenStoreBytes)
            }
        }
    }

    func sample(frozenStoreBytes: Int, physFootprintBytes: Int) {
        state.withLock {
            $0.peakFrozenStoreBytes = max($0.peakFrozenStoreBytes, frozenStoreBytes)
            $0.peakPhysFootprintBytes = max($0.peakPhysFootprintBytes, physFootprintBytes)
        }
    }

    func report(itemCount: Int) -> CacheHorizonReport {
        state.withLock { st in
            CacheHorizonReport(
                itemCount: itemCount,
                forward: st.forward,
                reverse: st.reverse,
                peakFrozenStoreBytes: st.peakFrozenStoreBytes,
                peakPhysFootprintBytes: st.peakPhysFootprintBytes,
                visibleReloadCount: st.reverse.emptyLayoutMounts + st.reverse.visibleRasterMisses
            )
        }
    }

    private static func fold(_ event: RasterDiagnosticsEvent, into c: inout CacheHorizonCounters, peak: inout Int) {
        switch event {
        case .rasterMiss:
            c.visibleRasterMisses += 1
        case .rasterHit(_, _, let fromFrozen):
            if fromFrozen { c.rasterHitsFromFrozenStore += 1 } else { c.rasterHitsResident += 1 }
        case .emptyLayoutMount(_, let placeholderVisible):
            c.emptyLayoutMounts += 1
            if placeholderVisible { c.emptyLayoutMountsWithGradient += 1 }
        case .placeholderExposure(let count):
            c.gradientFrames += 1
            c.gradientCellFrames += count
        case .layoutResolved(_, let recomputed):
            if recomputed { c.layoutRecomputes += 1 } else { c.layoutCacheHits += 1 }
        case .imageRequest(let outcome):
            switch outcome {
            case .decodedHit: c.imageDecodedHits += 1
            case .networkFetch: c.imageNetworkRequests += 1
            case .localFileRead: c.imageLocalReads += 1
            }
        case .coldArchiveLookup(_, let hit):
            if hit { c.coldArchiveHits += 1 } else { c.coldArchiveMisses += 1 }
        case .repairStarted:
            c.rasterRepairs += 1
        case .frozenBitmapEvicted(_, _, let bytes, _):
            c.frozenEvictions += 1
            peak = max(peak, bytes)
        case .repairFinished, .repaintMissing, .hotRenderPhase, .rasterWork, .measureCalls:
            break
        }
    }
}

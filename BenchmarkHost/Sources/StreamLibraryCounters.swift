// StreamLibraryCounters.swift

import Foundation
import os
import QuartzCore
import VelocityUI

/// Folds the library's hot-render events into totals for the streaming cost baseline
/// (VelocityUI-ln1g.1). Thread-safe: the observer callback is `@Sendable`.
final class StreamLibraryCounters: Sendable {

    struct Totals: Equatable {
        var submitted = 0
        var replacedPending = 0
        var started = 0
        var delivered = 0
        var droppedStale = 0
        var renderedPixelArea = 0
        var copiedPixelArea = 0
        var measureCalls = 0
        var renderMsMedian = 0.0
        var renderMsP99 = 0.0
    }

    private struct State {
        var totals = Totals()
        var startedAt: [String: CFTimeInterval] = [:]
        var renderMs: [Double] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ event: RasterDiagnosticsEvent) {
        let now = CACurrentMediaTime()
        switch event {
        case let .hotRenderPhase(phase, key, kind, generation):
            let id = "\(key)-\(kind.rawValue)-\(generation)"
            state.withLock { st in
                switch phase {
                case .submitted: st.totals.submitted += 1
                case .replacedPending: st.totals.replacedPending += 1
                case .started:
                    st.totals.started += 1
                    st.startedAt[id] = now
                case .delivered:
                    st.totals.delivered += 1
                    if let began = st.startedAt.removeValue(forKey: id) { st.renderMs.append((now - began) * 1000) }
                case .droppedStale:
                    st.totals.droppedStale += 1
                    st.startedAt.removeValue(forKey: id)
                }
            }
        case let .rasterWork(_, _, width, height, copied):
            state.withLock {
                $0.totals.renderedPixelArea += width * height - copied
                $0.totals.copiedPixelArea += copied
            }
        case let .measureCalls(_, _, count):
            state.withLock { $0.totals.measureCalls += count }
        default:
            break
        }
    }

    func totals() -> Totals {
        state.withLock { st in
            var t = st.totals
            t.renderMsMedian = streamCostPercentile(st.renderMs, 0.5)
            t.renderMsP99 = streamCostPercentile(st.renderMs, 0.99)
            return t
        }
    }
}

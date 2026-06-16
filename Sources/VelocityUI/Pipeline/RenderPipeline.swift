// RenderPipeline.swift

#if canImport(UIKit)
import Foundation
import CoreGraphics

/// Prefetch actor — runs off MainActor, writes back to WorkingRange via MainActor.run.
/// Called by the scroll container on leading-index boundary crossings (not every frame).
public actor RenderPipeline {
    private var lastLeadingIndex: Int = -1
    private(set) var prefetchTask: Task<Void, Never>?

    /// Incremented each time a new prefetch Task is spawned.
    /// Internal for testing only — not part of the production API.
    private(set) var taskStartCount: Int = 0

    private let textPool: TextMeasurementPool

    public init(textPool: TextMeasurementPool) {
        self.textPool = textPool
    }

    /// Test-only convenience: creates a private pool not shared with RenderEnvironment.
    init() {
        self.textPool = TextMeasurementPool()
    }

    /// Notify the pipeline that the visible leading index has changed.
    /// No-op if leadingIndex hasn't changed since last call.
    /// Cancels and replaces any running prefetch task.
    public func onIndexBoundary(
        _ leadingIndex: Int,
        workingRange: WorkingRange,
        tables: [NodeTable],
        availableWidth: CGFloat
    ) {
        guard leadingIndex != lastLeadingIndex else { return }
        lastLeadingIndex = leadingIndex
        prefetchTask?.cancel()
        taskStartCount += 1

        prefetchTask = Task {
            let rangeEnd = min(leadingIndex + 60, tables.count)
            guard rangeEnd > leadingIndex else { return }

            // Capture textPool here — Task inherits actor isolation so self.textPool
            // is accessible without await. group.addTask closures are @Sendable and
            // cannot reference actor-isolated state directly.
            let pool = self.textPool

            // Collect indices not yet in the ring buffer.
            var needed: [Int] = []
            for i in leadingIndex..<rangeEnd {
                let existing = await workingRange.entry(at: i)
                if existing == nil { needed.append(i) }
            }
            guard !needed.isEmpty, !Task.isCancelled else { return }

            // Measure and extract fragments in parallel.
            // extractFragments is nonisolated — safe to call inside the task.
            var results: [(Int, ResolvedLayout, [Fragment])] = []
            await withTaskGroup(of: (Int, ResolvedLayout, [Fragment]).self) { group in
                for index in needed {
                    group.addTask {
                        let table = tables[index]
                        let layout = await measureNode(
                            table, nodeIndex: 0,
                            width: availableWidth,
                            textPool: pool
                        )
                        let fragments = extractFragments(table: table, layout: layout)
                        return (index, layout, fragments)
                    }
                }
                for await triple in group { results.append(triple) }
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                workingRange.advance(to: max(0, leadingIndex - 3))
                for (i, layout, fragments) in results {
                    workingRange.commit(layout, fragments, at: i)
                }
            }
        }
    }

    /// Awaits the current prefetch task. Used in tests to synchronise assertions.
    public func waitForCurrentPrefetch() async {
        await prefetchTask?.value
    }
}
#endif

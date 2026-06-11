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

    public init() {}

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

            // Collect indices not yet in the ring buffer.
            var needed: [Int] = []
            for i in leadingIndex..<rangeEnd {
                let existing = await workingRange.layout(at: i)
                if existing == nil { needed.append(i) }
            }
            guard !needed.isEmpty, !Task.isCancelled else { return }

            // Measure in parallel.
            var results: [(Int, ResolvedLayout)] = []
            await withTaskGroup(of: (Int, ResolvedLayout).self) { group in
                for index in needed {
                    group.addTask {
                        let layout = await measureNode(
                            tables[index], nodeIndex: 0,
                            width: availableWidth,
                            textPool: .shared
                        )
                        return (index, layout)
                    }
                }
                for await pair in group { results.append(pair) }
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                workingRange.advance(to: max(0, leadingIndex - 3))
                for (i, layout) in results {
                    workingRange.commit(layout, at: i)
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

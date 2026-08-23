// VelocityUIGridRuntimeViewController.swift

import SwiftUI
import UIKit
import VelocityUI

/// Live-only demo VC for `.grid(columns:spacing:)` (VelocityUI-0c5 grid DSL). Sibling of
/// `VelocityUIRuntimeViewController`, not a modification of it — this screen exists purely so the
/// picker has somewhere to open a scrollable grid; it isn't part of the headless runtime matrix
/// (no `LaunchArguments.Runtime` case, no orchestrator param) since the ask was "open it and
/// scroll it", not a measured comparison against the other runtimes.
@MainActor
final class VelocityUIGridRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let harness: BenchmarkHarness
    private let environment: RenderEnvironment
    private var liveMetrics: LiveMetricsController?

    init(items: [BenchmarkItem], harness: BenchmarkHarness) {
        self.benchmarkItems = items
        self.harness = harness
        self.environment = RenderEnvironment(
            contentDeliveryObserver: { kind in
                switch kind {
                case .fromGrayPlaceholder:
                    harness.recordGrayToImageTransition()
                case .fromThumbnailPlaceholder:
                    harness.recordThumbnailToImageTransition()
                }
            },
            pipelineTaskSpawnObserver: {
                harness.recordPipelineTaskSpawn()
            }
        )
        super.init(nibName: nil, bundle: nil)
        title = "VelocityUI — Grid"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let feedView = VelocityUIGridFeedView(items: benchmarkItems, environment: environment)
        let hostVC = UIHostingController(rootView: feedView)
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let scrollView = view.firstScrollView, liveMetrics == nil else { return }
        let c = LiveMetricsController(scrollView: scrollView, harness: harness, imageMode: LaunchArguments().imageMode, runtimeLabel: "VelocityUI-grid")
        c.start()
        liveMetrics = c
    }
}

// MARK: - SwiftUI feed view

private struct VelocityUIGridFeedView: View {
    let items: [BenchmarkItem]
    let environment: RenderEnvironment

    var body: some View {
        AsyncFeed(items: items, environment: environment, layout: .grid(columns: 3, spacing: 6)) { item in
            VelocityUIGridBenchmarkCell(item: item)
        }
        .prefetchWindow(ahead: 10, behind: 5)
    }
}

// MARK: - Cell DSL

/// Square tile — `.grid`'s row height comes from the tallest cell in the row (see
/// `GridLayoutProvider`), so a fixed `aspectRatio: 1` regardless of the item's real
/// `aspectRatio` keeps every row a uniform height, the look people expect from a grid.
private struct VelocityUIGridBenchmarkCell: RenderView {
    let item: BenchmarkItem

    var renderBody: some RenderNode {
        AsyncImageNode(url: item.imageURL, aspectRatio: 1, contentMode: .fill)
            .cornerRadius(4)
            .placeholder(thumbnail: item.thumbnailData)
            .placeholder(blurHash: item.blurHash)
    }
}

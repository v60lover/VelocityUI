// VelocityUIRuntimeViewController.swift

import SwiftUI
import UIKit
import VelocityUI

@MainActor
final class VelocityUIRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let environment: RenderEnvironment
    private var liveMetrics: LiveMetricsController?

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness, orchestrator: BenchmarkOrchestrator? = nil) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        self.harness = harness
        self.orchestrator = orchestrator
        // `harness` (the init parameter, not `self.harness`) is captured here — `self` isn't
        // fully initialized until after `super.init()` below, so it can't be referenced yet.
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
        title = "VelocityUI"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let feedView = VelocityUIFeedView(items: benchmarkItems, environment: environment)
        let hostVC = UIHostingController(rootView: feedView)
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let scrollView = view.firstScrollView else { return }
        orchestrator?.scrollViewReady(scrollView)
        if orchestrator == nil, liveMetrics == nil {
            let c = LiveMetricsController(scrollView: scrollView, harness: harness, imageMode: LaunchArguments().imageMode, runtimeLabel: "VelocityUI")
            c.start()
            liveMetrics = c
        }
    }
}

// MARK: - SwiftUI feed view

private struct VelocityUIFeedView: View {
    let items: [BenchmarkItem]
    let environment: RenderEnvironment

    var body: some View {
        AsyncFeed(items: items, environment: environment) { item in
            VelocityUIBenchmarkCell(item: item)
        }
        .prefetchWindow(ahead: 10, behind: 5)
    }
}

// MARK: - Cell DSL

private struct VelocityUIBenchmarkCell: RenderView {
    let item: BenchmarkItem

    var renderBody: VStackNode {
        VStackNode(alignment: .leading, spacing: 8) {
            AsyncImageNode(url: item.imageURL, aspectRatio: CGFloat(item.aspectRatio), contentMode: .fill)
                .cornerRadius(CGFloat(item.cornerRadius))
                .placeholder(thumbnail: item.thumbnailData)
                .placeholder(blurHash: item.blurHash)
            TextNode("random string \n random string", font: .body).lineLimit(2)
            HStackNode(spacing: 4) {
                TextNode("jhon doe")
                SpacerNode()
                TextNode("11/12/12")
            }
        }
    }
}

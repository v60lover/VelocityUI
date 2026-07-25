// VelocityUIRuntimeViewController.swift

import SwiftUI
import UIKit
@_spi(BenchmarkHost) import VelocityUI

@MainActor
final class VelocityUIRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let environment: RenderEnvironment

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness, orchestrator: BenchmarkOrchestrator? = nil) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        self.harness = harness
        self.orchestrator = orchestrator
        self.environment = RenderEnvironment()
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

        #if DEBUG
        // Wire gray-transition and thumbnail-transition counters for the slow-scroll and
        // maxFlingNoGray scenarios. FeedScrollView<BenchmarkItem> is the first scroll view
        // in the UIHostingController subtree.
        if let feedView = scrollView as? FeedScrollView<BenchmarkItem> {
            feedView._onContentDeliveredDebug = { [weak self] in
                self?.harness.recordGrayToImageTransition()
            }
            feedView._onThumbnailReplacedDebug = { [weak self] in
                self?.harness.recordThumbnailToImageTransition()
            }
        }
        #endif

        orchestrator?.scrollViewReady(scrollView)
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

    var renderBody: AsyncImageNode {
        AsyncImageNode(url: item.imageURL, aspectRatio: CGFloat(item.aspectRatio), contentMode: .fill)
            .cornerRadius(CGFloat(item.cornerRadius))
            .placeholder(thumbnail: item.thumbnailData)
            .placeholder(blurHash: item.blurHash)
    }
}

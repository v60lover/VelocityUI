// VelocityUIRuntimeViewController.swift

import SwiftUI
import UIKit
import VelocityUI

@MainActor
final class VelocityUIRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    // Reserved for Option A integration (VelocityUI-rel: ImageActor.preload API).
    // Both image modes currently route through BenchmarkURLProtocol because ImageActor
    // has no public preload API — see viewDidAppear comment.
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let environment: RenderEnvironment

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness, orchestrator: BenchmarkOrchestrator? = nil) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        self.harness = harness
        self.orchestrator = orchestrator
        // BenchmarkURLProtocol handles benchmark:// URLs locally — zero real network traffic.
        let config = URLSessionConfiguration.default
        config.protocolClasses = [BenchmarkURLProtocol.self] + (config.protocolClasses ?? [])
        self.environment = RenderEnvironment(session: URLSession(configuration: config))
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
        // Both image modes are equivalent here: ImageActor has no public preload API
        // (VelocityUI-rel), so same-pipeline cannot bypass the fetch+decode lane the way
        // UICollectionView and Texture do via imageSource.imageData(for:). Both modes
        // lazy-fetch from BenchmarkURLProtocol (local, zero real network) as cells enter
        // the working range. Cross-runtime same-pipeline comparisons should account for
        // this difference until VelocityUI-rel lands.
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

    var renderBody: HStackNode {
        HStackNode(alignment: .top, spacing: 12) {
            AsyncImageNode(url: item.imageURL, aspectRatio: CGFloat(item.aspectRatio), contentMode: .fill)
                .cornerRadius(CGFloat(item.cornerRadius))
            if !item.caption.isEmpty {
                TextNode(item.caption)
            }
        }
    }
}

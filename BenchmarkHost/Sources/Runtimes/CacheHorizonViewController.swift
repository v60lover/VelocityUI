// CacheHorizonViewController.swift

import SwiftUI
import UIKit
import VelocityUI

/// Runtime VC for the `cache-horizon` scenario: a >2,000-item mixed transcript scrolled to the
/// bottom and back, with every cache transition counted through `RasterDiagnosticsObserver`.
/// Prints a `CacheHorizonReport` as JSON and exits when the reverse pass ends or the backstop fires.
@MainActor
final class CacheHorizonViewController: UIViewController {
    private let items: [HorizonItem]
    private let metrics = CacheHorizonMetrics()
    private let environment: RenderEnvironment
    private let driver = CacheHorizonDriver()
    private let backstop: TimeInterval
    private var backstopTimer: Timer?
    private var didStart = false
    private var didFinish = false

    /// Called once with the final report.
    var onComplete: ((CacheHorizonReport) -> Void)?

    init(itemCount: Int, backstop: TimeInterval) {
        self.items = CacheHorizonDataset.items(count: itemCount)
        self.backstop = backstop
        let metrics = self.metrics
        self.environment = RenderEnvironment(
            rasterDiagnosticsObserver: RasterDiagnosticsObserver { metrics.record($0) }
        )
        super.init(nibName: nil, bundle: nil)
        title = "VelocityUI — cache horizon"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let hostVC = UIHostingController(rootView: HorizonFeedView(items: items, environment: environment))
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart, let scrollView = view.firstScrollView else { return }
        didStart = true
        let metrics = self.metrics
        let env = environment
        driver.start(
            scrollView: scrollView,
            onPhaseChange: { metrics.setPhase($0) },
            onTick: {
                metrics.sample(
                    frozenStoreBytes: env.frozenBitmapStore.currentByteTotal,
                    physFootprintBytes: AllocationProbe.currentPhysFootprint()
                )
            },
            onEnd: { [weak self] in self?.finish() }
        )
        backstopTimer = Timer.scheduledTimer(withTimeInterval: backstop, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        backstopTimer?.invalidate()
        driver.stop()
        onComplete?(metrics.report(itemCount: items.count))
    }
}

private struct HorizonFeedView: View {
    let items: [HorizonItem]
    let environment: RenderEnvironment

    var body: some View {
        AsyncFeed(items: items, environment: environment) { item in
            HorizonCell(item: item)
        }
        .prefetchWindow(ahead: 10, behind: 5)
        .padding(.horizontal, 8)
    }
}

private struct HorizonCell: RenderView {
    let item: HorizonItem

    var renderBody: some RenderNode {
        VStackNode(alignment: .leading, spacing: 8) {
            nodes
        }
    }

    private var nodes: [any RenderNode] {
        var parser = IncrementalMarkdownParser()
        parser.append(CacheHorizonDataset.markdown(for: item) + "\n\n")
        var result = parser.renderNodes(theme: .default)
        if item.kind == .image {
            result.append(
                AsyncImageNode(url: CacheHorizonDataset.imageURL(for: item), aspectRatio: 16.0 / 9.0, contentMode: .fill)
                    .renderID("horizon-image-\(item.id)")
            )
        }
        return result
    }
}

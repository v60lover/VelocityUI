// SwiftUIListRuntimeViewController.swift
//
// Asymmetry notes vs LazyVStack:
// - List enforces row separators and selection state by default — both disabled for fairness.
// - List is UICollectionView-backed (iOS 16+); cells recycle like UIKit. LazyVStack does not.
// - SwiftUI diffing on Identifiable items is left on (idiomatic).

import NukeUI
import os
import SwiftUI
import UIKit

final class SwiftUIListRuntimeViewController: UIViewController {
    private let benchmarkItems: [BenchmarkItem]
    private let imageSource: any ImageSource
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private var liveMetrics: LiveMetricsController?

    init(items: [BenchmarkItem], imageSource: any ImageSource, harness: BenchmarkHarness, orchestrator: BenchmarkOrchestrator? = nil) {
        self.benchmarkItems = items
        self.imageSource = imageSource
        self.harness = harness
        self.orchestrator = orchestrator
        super.init(nibName: nil, bundle: nil)
        title = "SwiftUI List"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let feedView = ListFeedView(
            items: benchmarkItems,
            imageSource: imageSource,
            harness: harness
        )
        let hostVC = UIHostingController(rootView: feedView)
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let sv = view.firstScrollView {
            orchestrator?.scrollViewReady(sv)
            if orchestrator == nil, liveMetrics == nil {
                let c = LiveMetricsController(scrollView: sv, harness: harness, imageMode: LaunchArguments().imageMode, runtimeLabel: "SwiftUI List")
                c.start()
                liveMetrics = c
            }
        }
    }
}

private struct ListFeedView: View {
    let items: [BenchmarkItem]
    let imageSource: any ImageSource
    let harness: BenchmarkHarness

    var body: some View {
        List(items, id: \.id) { item in
            ListRowView(item: item, imageSource: imageSource, harness: harness)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        }
        .listStyle(.plain)
        .selectionDisabled()
    }
}

private struct ListRowView: View {
    let item: BenchmarkItem
    let imageSource: any ImageSource
    let harness: BenchmarkHarness

    @State private var imageData: Data?
    @State private var spanState: OSSignpostIntervalState?

    private var isIdiomatic: Bool { imageSource is IdiomaticImageSource }

    var body: some View {
        imageView
            .aspectRatio(item.aspectRatio, contentMode: .fill)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: item.cornerRadius))
            .onAppear {
                if spanState == nil {
                    spanState = harness.beginCellMount()
                }
            }
            .onDisappear {
                if let s = spanState {
                    harness.endCellMount(s)
                    spanState = nil
                }
            }
            .task {
                guard !isIdiomatic else { return }
                imageData = await imageSource.imageData(for: item)
                if let s = spanState {
                    harness.endCellMount(s)
                    spanState = nil
                }
            }
    }

    @ViewBuilder
    private var imageView: some View {
        if isIdiomatic {
            LazyImage(url: item.imageURL) { state in
                Group {
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color(hue: item.placeholderHue, saturation: 0.5, brightness: 0.8)
                    }
                }
                .onAppear {
                    // Cache-hit: image already available on first render, onChange won't fire.
                    if state.image != nil, let s = spanState {
                        harness.endCellMount(s)
                        spanState = nil
                    }
                }
                .onChange(of: state.isLoading) { _, isLoading in
                    if !isLoading, let s = spanState {
                        harness.endCellMount(s)
                        spanState = nil
                    }
                }
            }
            .pipeline(.benchmark)
        } else if let data = imageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            Color(hue: item.placeholderHue, saturation: 0.5, brightness: 0.8)
        }
    }
}

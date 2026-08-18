// StreamBenchmarkViewController.swift

import SwiftUI
import UIKit
import VelocityUI

/// Runtime VC for the `stream` scenario (VelocityUI-xxf7) — VelocityUI-only, sibling of
/// `VelocityUIRuntimeViewController`, not a modification of it (that one is scroll-scenario
/// specific: it wires `ScrollDriver` via `orchestrator?.scrollViewReady`, which this scenario has
/// nothing to drive). Hosts a SwiftUI `AsyncFeed` over a single growing `StreamMessage`, fed by
/// `StreamDriver` through the public streaming API (VelocityUI-zuot) — `IncrementalMarkdownParser
/// .append(_:)` on the message, then a fresh value pushed into `store.message` so `AsyncFeed`
/// observes the change through ordinary SwiftUI state, never a private hook.
@MainActor
final class StreamBenchmarkViewController: UIViewController {
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let environment: RenderEnvironment
    private let store = StreamStore()
    private let tokens: [String]
    private let tokensPerSecond: Double
    private let includeInterleavedBlocks: Bool
    /// Drives the stream directly when `orchestrator == nil` (the manual/picker flow — see
    /// `viewDidAppear`). The headless `orchestrator` path owns its own `StreamDriver` internally
    /// (`BenchmarkOrchestrator.streamReady`); this one exists purely so the picker's "Streaming
    /// Text" row has something to drive it, mirroring every other runtime VC's `orchestrator ==
    /// nil` → hand-driven/live-HUD branch.
    private let manualDriver = StreamDriver()
    private var liveMetrics: LiveMetricsController?

    init(
        harness: BenchmarkHarness,
        orchestrator: BenchmarkOrchestrator?,
        hotBlockRasterizeEnabled: Bool,
        includeInterleavedBlocks: Bool = true,
        tokens: [String] = StreamDataset.tokens(),
        tokensPerSecond: Double = 20
    ) {
        self.harness = harness
        self.orchestrator = orchestrator
        self.tokens = tokens
        self.tokensPerSecond = tokensPerSecond
        self.includeInterleavedBlocks = includeInterleavedBlocks
        self.environment = RenderEnvironment(hotBlockRasterizeEnabled: hotBlockRasterizeEnabled)
        super.init(nibName: nil, bundle: nil)
        title = "VelocityUI — stream"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let feedView = StreamFeedView(store: store, environment: environment, includeInterleavedBlocks: includeInterleavedBlocks)
        let hostVC = UIHostingController(rootView: feedView)
        addChild(hostVC)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)
    }

    private var didStartDriving = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartDriving else { return }
        didStartDriving = true

        if let orchestrator {
            // Headless measured path — BenchmarkOrchestrator owns capture start/stop timing.
            orchestrator.streamReady(tokens: tokens, tokensPerSecond: tokensPerSecond) { [weak store] token in
                store?.append(token)
            }
            return
        }

        // Manual/picker flow: no orchestrator, no measured capture — drive directly and attach
        // a live HUD, same shape as every other runtime VC's `orchestrator == nil` branch (see
        // e.g. VelocityUIRuntimeViewController.viewDidAppear). Unlike scroll runtimes there is no
        // gesture to hand-drive the content, so the manualDriver runs on its own; the HUD still
        // shows live frame/allocation stats while it does.
        manualDriver.start(tokens: tokens, tokensPerSecond: tokensPerSecond, onToken: { [weak store] token in
            store?.append(token)
        }, onEnd: {})
        if let scrollView = view.firstScrollView, liveMetrics == nil {
            let c = LiveMetricsController(scrollView: scrollView, harness: harness, imageMode: LaunchArguments().imageMode, runtimeLabel: "VelocityUI-stream")
            c.start()
            liveMetrics = c
        }
    }
}

// MARK: - SwiftUI-observable message store

/// Bridges `StreamDriver`'s UIKit-side ticks into the SwiftUI state `AsyncFeed` observes.
/// One growing message — `append(_:)` mutates its `IncrementalMarkdownParser` and republishes
/// the whole array, mirroring `StreamingMarkdownFeedIntegrationTests`' `feed.items = [...]`
/// re-push pattern.
@MainActor
private final class StreamStore: ObservableObject {
    @Published var messages: [StreamMessage] = [StreamMessage(id: 0, parser: IncrementalMarkdownParser())]

    func append(_ token: String) {
        var parser = messages[0].parser
        parser.append(token)
        messages = [StreamMessage(id: 0, parser: parser)]
    }
}

// MARK: - SwiftUI feed view

private struct StreamFeedView: View {
    @ObservedObject var store: StreamStore
    let environment: RenderEnvironment
    let includeInterleavedBlocks: Bool

    var body: some View {
        AsyncFeed(items: store.messages, environment: environment) { message in
            StreamBenchmarkCell(message: message, includeInterleavedBlocks: includeInterleavedBlocks)
        }
        .prefetchWindow(ahead: 10, behind: 3)
    }
}

// MARK: - Cell DSL

private struct StreamBenchmarkCell: RenderView {
    let message: StreamMessage
    let includeInterleavedBlocks: Bool

    var renderBody: some RenderNode {
        VStackNode(alignment: .leading, spacing: 8) {
            StreamDataset.interleavedRenderNodes(for: message.parser, includeInterleavedBlocks: includeInterleavedBlocks)
        }
    }
}

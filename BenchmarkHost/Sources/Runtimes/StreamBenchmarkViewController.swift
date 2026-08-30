// StreamBenchmarkViewController.swift

import SwiftUI
import UIKit
import VelocityUI

/// Runtime VC for the `stream` scenario (VelocityUI-xxf7) — VelocityUI-only, sibling of
/// `VelocityUIRuntimeViewController`, not a modification of it (that one is scroll-scenario
/// specific: it wires `ScrollDriver` via `orchestrator?.scrollViewReady`, which this scenario has
/// nothing to drive). Hosts a SwiftUI `AsyncFeed` over a single growing `StreamMessage`, fed by
/// `StreamDriver` through the public streaming API (VelocityUI-zuot) — `StreamStore` appends each
/// token into a `StreamingMarkdownController` (VelocityUI-8g6l), then pushes a fresh
/// `StreamMessage` into `store.messages` so `AsyncFeed` observes the change through ordinary
/// SwiftUI state, never a private hook.
@MainActor
final class StreamBenchmarkViewController: UIViewController {
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let environment: RenderEnvironment
    private let store = StreamStore()
    private let tokens: [String]
    private let tokensPerSecond: Double
    private let includeInterleavedBlocks: Bool
    /// VelocityUI-0tbi's "gesture-gated deferral" spike toggle — see `StreamGestureCoalescer`.
    /// Defaults to false (current behavior, unchanged from before this bead).
    private let gestureGatedDeferralEnabled: Bool
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
        gestureGatedDeferralEnabled: Bool = false,
        includeInterleavedBlocks: Bool = true,
        tokens: [String] = StreamDataset.tokens(),
        tokensPerSecond: Double = 20
    ) {
        self.harness = harness
        self.orchestrator = orchestrator
        self.tokens = tokens
        self.tokensPerSecond = tokensPerSecond
        self.includeInterleavedBlocks = includeInterleavedBlocks
        self.gestureGatedDeferralEnabled = gestureGatedDeferralEnabled
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

        let scrollView = view.firstScrollView
        if gestureGatedDeferralEnabled, let scrollView {
            store.startGestureGatedDeferral(scrollView: scrollView)
        }

        if let orchestrator {
            // Headless measured path — BenchmarkOrchestrator owns capture start/stop timing.
            // No real gesture ever occurs here (--live is rejected for --scenario stream), so the
            // deferral toggle above is wired for interface symmetry but inert on this path.
            orchestrator.streamReady(tokens: tokens, tokensPerSecond: tokensPerSecond) { [weak store] token in
                store?.append(token)
            }
            return
        }

        // Manual/picker flow: no orchestrator, no measured capture — drive directly and attach
        // a live HUD, same shape as every other runtime VC's `orchestrator == nil` branch (see
        // e.g. VelocityUIRuntimeViewController.viewDidAppear). Unlike scroll runtimes there is no
        // gesture to hand-drive the content, so the manualDriver runs on its own; the HUD still
        // shows live frame/allocation stats while it does. A real drag here is exactly what
        // gestureGatedDeferralEnabled reacts to.
        manualDriver.start(tokens: tokens, tokensPerSecond: tokensPerSecond, onToken: { [weak store] token in
            store?.append(token)
        }, onEnd: {})
        if let scrollView, liveMetrics == nil {
            let c = LiveMetricsController(scrollView: scrollView, harness: harness, imageMode: LaunchArguments().imageMode, runtimeLabel: "VelocityUI-stream")
            c.start()
            liveMetrics = c
        }
    }
}

// MARK: - Theme

extension MarkdownTheme {
    /// `.default` with a smaller code font (16pt vs. the 20pt body/code default) — just for this
    /// scenario's readability at benchmark cell widths.
    fileprivate static let stream: MarkdownTheme = {
        var theme = MarkdownTheme.default
        theme.code = VFontDescriptor(size: 13, weight: VFontDescriptor.regularWeight)
        return theme
    }()
}

// MARK: - SwiftUI-observable message store

/// Bridges `StreamDriver`'s UIKit-side ticks into the SwiftUI state `AsyncFeed` observes.
/// One growing message — `append(_:)` mutates its `IncrementalMarkdownParser` and republishes
/// the whole array, mirroring `StreamingMarkdownFeedIntegrationTests`' `feed.items = [...]`
/// re-push pattern.
@MainActor
private final class StreamStore: ObservableObject {
    @Published var messages: [StreamMessage] = [StreamMessage(id: 0, parser: IncrementalMarkdownParser())]

    /// One memoizing controller per message id (VelocityUI-8g6l), so sealed-block styling stays
    /// cached across republishes instead of being rederived from `message.parser` on every read.
    /// `message.parser` still exists purely to give `AsyncFeed`'s Equatable diff a changing value
    /// to key on — the controller (kept here, off the Sendable `StreamMessage`) is what actually
    /// backs rendering. Tokens keep accumulating into the controller even while a
    /// `StreamGestureCoalescer` is buffering (not publishing) — the buffered path must never lose
    /// a token just because the last few appends happened during an active gesture.
    private let controllers: [Int: StreamingMarkdownController] = [0: StreamingMarkdownController(theme: .stream)]
    private var coalescer: StreamGestureCoalescer?

    /// The only message id this scenario ever drives is 0; a lookup miss is a programmer error.
    func controller(for id: Int) -> StreamingMarkdownController {
        controllers[id]!
    }

    /// Enables VelocityUI-0tbi's "gesture-gated deferral" toggle: while `scrollView` reports
    /// isTracking||isDragging||isDecelerating, `append(_:)` stops republishing `messages` (so
    /// `AsyncFeed`/`FeedScrollView` never re-lays-out on the scroll path); a single catch-up
    /// publish runs once the gesture ends. Must be called before the first `append(_:)`.
    func startGestureGatedDeferral(scrollView: UIScrollView) {
        let c = StreamGestureCoalescer()
        c.start(isGestureActive: { [weak scrollView] in
            guard let scrollView else { return false }
            return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        }, flush: { [weak self] parser in
            self?.messages = [StreamMessage(id: 0, parser: parser)]
        })
        coalescer = c
    }

    func append(_ token: String) {
        let controller = controller(for: 0)
        controller.append(token)
        if let coalescer {
            coalescer.submit(controller.parser)
        } else {
            messages = [StreamMessage(id: 0, parser: controller.parser)]
        }
    }
}

// MARK: - SwiftUI feed view

private struct StreamFeedView: View {
    @ObservedObject var store: StreamStore
    let environment: RenderEnvironment
    let includeInterleavedBlocks: Bool

    var body: some View {
        AsyncFeed(items: store.messages, environment: environment) { message in
            let controller = store.controller(for: message.id)
            let nodes = StreamDataset.interleavedRenderNodes(
                textNodes: controller.renderNodes,
                frontier: controller.parser.frontier,
                includeInterleavedBlocks: includeInterleavedBlocks
            )
            return StreamBenchmarkCell(nodes: nodes)
        }
        .prefetchWindow(ahead: 10, behind: 3)
    }
}

// MARK: - Cell DSL

/// Holds already-derived `[any RenderNode]` rather than a `StreamMessage`/controller reference —
/// `RenderView` requires `Sendable` (RenderNode.swift:17) and `StreamingMarkdownController` is a
/// deliberately non-Sendable `@MainActor` class, so it can't be a stored property here. `nodes`
/// is derived on `@MainActor` in `StreamFeedView.body` (where the controller lives) and handed in
/// as a plain `Sendable` array (`RenderNode: Sendable`).
private struct StreamBenchmarkCell: RenderView {
    let nodes: [any RenderNode]

    var renderBody: some RenderNode {
        VStackNode(alignment: .leading, spacing: 8) {
            nodes
        }
    }
}

// StreamBenchmarkViewController.swift

import SwiftUI
import UIKit
import VelocityUI

/// Runtime VC for the `stream` scenario (VelocityUI-xxf7) — VelocityUI-only, sibling of
/// `VelocityUIRuntimeViewController`, not a modification of it (that one is scroll-scenario
/// specific: it wires `ScrollDriver` via `orchestrator?.scrollViewReady`, which this scenario has
/// nothing to drive). Hosts a SwiftUI `AsyncFeed` over a growing list of `StreamMessage`s, fed by
/// `StreamDriver` through the public streaming API (VelocityUI-zuot) — `StreamStore` appends each
/// token into the active turn's `StreamingMarkdownController` (VelocityUI-8g6l), then pushes a
/// fresh `StreamMessage` into `store.messages` so `AsyncFeed` observes the change through ordinary
/// SwiftUI state, never a private hook.
@MainActor
final class StreamBenchmarkViewController: UIViewController {
    private let harness: BenchmarkHarness
    private let orchestrator: BenchmarkOrchestrator?
    private let environment: RenderEnvironment
    private let store = StreamStore()
    /// Flat concatenation of every turn's chunks — feeds the headless `orchestrator` path, which
    /// measures one continuous answer and has no notion of turn boundaries.
    private let tokens: [String]
    /// `StreamDataset.turns()` matching `tokens` — feeds the manual/picker path, which interleaves
    /// a `.user` bubble between each turn's streamed segment (see `driveManualTurns`).
    private let turns: [StreamDataset.StreamTurn]
    private let tokensPerSecond: Double
    private let includeInterleavedBlocks: Bool
    /// VelocityUI-0tbi's "gesture-gated deferral" spike toggle — see `StreamGestureCoalescer`.
    /// Defaults to false (current behavior, unchanged from before this bead).
    private let gestureGatedDeferralEnabled: Bool
    /// Drives the stream directly when `orchestrator == nil` (the manual/picker flow — see
    /// `viewDidAppear`/`driveManualTurns`). The headless `orchestrator` path owns its own
    /// `StreamDriver` internally (`BenchmarkOrchestrator.streamReady`); this one exists purely so
    /// the picker's "Streaming Text" row has something to drive it, mirroring every other runtime
    /// VC's `orchestrator == nil` → hand-driven/live-HUD branch. Restarted (via `start(...)`'s own
    /// `stop()`) once per turn rather than run once over the flat stream — see `driveManualTurns`.
    private let manualDriver = StreamDriver()
    private var liveMetrics: LiveMetricsController?

    init(
        harness: BenchmarkHarness,
        orchestrator: BenchmarkOrchestrator?,
        hotBlockRasterizeEnabled: Bool,
        gestureGatedDeferralEnabled: Bool = false,
        includeInterleavedBlocks: Bool = true,
        turns: [StreamDataset.StreamTurn] = StreamDataset.turns(),
        tokensPerSecond: Double = 20
    ) {
        self.harness = harness
        self.orchestrator = orchestrator
        self.turns = turns
        self.tokens = turns.flatMap { $0.assistantChunks }
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
            // Headless measured path — BenchmarkOrchestrator owns capture start/stop timing and
            // only understands one flat token stream, so this stays a single user bubble (the
            // first turn's question) followed by one continuous streamed answer, same shape as
            // before turn-splitting existed. No real gesture ever occurs here (--live is rejected
            // for --scenario stream), so the deferral toggle above is wired for interface symmetry
            // but inert on this path.
            store.addUserMessage(turns.first?.userMessage ?? "")
            store.beginAssistantMessage()
            orchestrator.streamReady(tokens: tokens, tokensPerSecond: tokensPerSecond) { [weak store] token in
                store?.append(token)
            }
            return
        }

        // Manual/picker flow: no orchestrator, no measured capture — drive turn by turn and
        // attach a live HUD, same shape as every other runtime VC's `orchestrator == nil` branch
        // (see e.g. VelocityUIRuntimeViewController.viewDidAppear). Unlike scroll runtimes there
        // is no gesture to hand-drive the content, so the manualDriver runs on its own; the HUD
        // still shows live frame/allocation stats while it does. A real drag here is exactly what
        // gestureGatedDeferralEnabled reacts to.
        driveManualTurns(startingAt: 0)
        if let scrollView, liveMetrics == nil {
            let c = LiveMetricsController(scrollView: scrollView, harness: harness, imageMode: LaunchArguments().imageMode, runtimeLabel: "VelocityUI-stream")
            c.start()
            liveMetrics = c
        }
    }

    /// Simulated "user is sending" latency before the next turn's user bubble lands — mirrors the
    /// small gap between the previous answer finishing and the user's next message actually
    /// posting (typing/send), rather than it appearing the instant the assistant stops.
    private let userMessageLatency: Duration = .seconds(2)
    /// Simulated "thinking" latency between the user bubble landing and the assistant's answer
    /// starting to stream — mirrors a real LLM chat, where the user's message posts immediately
    /// but generation only begins after a round trip to the model.
    private let responseLatency: Duration = .seconds(2)

    /// Waits `userMessageLatency`, then shows `turns[index]`'s user bubble, waits
    /// `responseLatency`, then opens a fresh assistant bubble and streams that turn's chunks —
    /// recursing into the next turn from `onEnd` so the following `.user` message appears only
    /// once the current segment has finished streaming, not upfront. Ends silently once `index`
    /// runs past the last turn.
    private func driveManualTurns(startingAt index: Int) {
        guard index < turns.count else { return }
        let turn = turns[index]
        Task { [weak self] in
            try? await Task.sleep(for: self?.userMessageLatency ?? .zero)
            guard let self else { return }
            self.store.addUserMessage(turn.userMessage)
            try? await Task.sleep(for: self.responseLatency)
            self.store.beginAssistantMessage()
            self.manualDriver.start(tokens: turn.assistantChunks, tokensPerSecond: self.tokensPerSecond, onToken: { [weak store] token in
                store?.append(token)
            }, onEnd: { [weak self] in
                self?.driveManualTurns(startingAt: index + 1)
            })
        }
    }
}

// MARK: - Theme

extension MarkdownTheme {
    /// `.default` with a smaller code font (16pt vs. the 20pt body/code default) — just for this
    /// scenario's readability at benchmark cell widths.
    fileprivate static let stream: MarkdownTheme = {
        var theme = MarkdownTheme.default
        theme.code = VFontDescriptor(size: 15, weight: VFontDescriptor.regularWeight)
        return theme
    }()
}

// MARK: - SwiftUI-observable message store

/// Bridges `StreamDriver`'s UIKit-side ticks into the SwiftUI state `AsyncFeed` observes. Grows
/// one message at a time — a `.user` bubble via `addUserMessage(_:)`, an `.assistant` bubble via
/// `beginAssistantMessage()` — so callers can interleave the two as turns complete instead of
/// seeding the whole transcript upfront. `append(_:)` mutates the *active* assistant turn's
/// `IncrementalMarkdownParser` and republishes the whole array, mirroring
/// `StreamingMarkdownFeedIntegrationTests`' `feed.items = [...]` re-push pattern.
@MainActor
private final class StreamStore: ObservableObject {
    @Published var messages: [StreamMessage] = []
    /// Bumped once per user turn (`addUserMessage(_:)` only, never `beginAssistantMessage()`) —
    /// `StreamFeedView` threads it into `.tailFollow(_:pinTrigger:)` so `AsyncFeed` fires
    /// `FeedScrollView.pinTailSpacer()` right after the new user bubble lands.
    @Published var pinToken = 0

    private var nextID = 0
    /// One memoizing controller per assistant turn (VelocityUI-8g6l), keyed by that turn's message
    /// id, so sealed-block styling stays cached across republishes instead of being rederived from
    /// the parser on every read. The parser on `StreamMessage` still exists purely to give
    /// `AsyncFeed`'s Equatable diff a changing value to key on — the controller (kept here, off
    /// the Sendable `StreamMessage`) is what actually backs rendering.
    private var controllers: [Int: StreamingMarkdownController] = [:]
    /// The turn `append(_:)` currently targets — set by `beginAssistantMessage()`, read dynamically
    /// (not captured) by both `append(_:)` and the gesture-coalescer flush closure below, so
    /// switching turns mid-stream never leaves either pointed at a stale id.
    private var activeAssistantID: Int?
    private var coalescer: StreamGestureCoalescer?

    /// Appends a static `.user` bubble and returns its id.
    @discardableResult
    func addUserMessage(_ text: String) -> Int {
        let id = nextID
        nextID += 1
        messages.append(StreamMessage(id: id, content: .user(text)))
        pinToken += 1
        return id
    }

    /// Appends a fresh empty `.assistant` bubble, makes it the target of subsequent `append(_:)`
    /// calls, and returns its id.
    @discardableResult
    func beginAssistantMessage() -> Int {
        let id = nextID
        nextID += 1
        controllers[id] = StreamingMarkdownController(theme: .stream)
        messages.append(StreamMessage(id: id, content: .assistant(IncrementalMarkdownParser())))
        activeAssistantID = id
        return id
    }

    /// A lookup miss is a programmer error — every `.assistant` `StreamMessage` in `messages` was
    /// created by `beginAssistantMessage()`, which always registers a controller first.
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
            self?.publishActiveAssistant(parser)
        })
        coalescer = c
    }

    func append(_ token: String) {
        guard let id = activeAssistantID, let controller = controllers[id] else { return }
        controller.append(token)
        if let coalescer {
            coalescer.submit(controller.parser)
        } else {
            publishActiveAssistant(controller.parser)
        }
    }

    private func publishActiveAssistant(_ parser: IncrementalMarkdownParser) {
        guard let id = activeAssistantID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = StreamMessage(id: id, content: .assistant(parser))
    }
}

// MARK: - SwiftUI feed view

private struct StreamFeedView: View {
    @ObservedObject var store: StreamStore
    let environment: RenderEnvironment
    let includeInterleavedBlocks: Bool

    var body: some View {
        AsyncFeed(items: store.messages, environment: environment) { message in
            let nodes: [any RenderNode]
            switch message.content {
            case .user(let text):
                nodes = [TextNode(text).messageRole(.user)]
            case .assistant:
                let controller = store.controller(for: message.id)
                nodes = StreamDataset.interleavedRenderNodes(
                    textNodes: controller.renderNodes,
                    frontier: controller.parser.frontier,
                    includeInterleavedBlocks: includeInterleavedBlocks
                )
            }
            return StreamBenchmarkCell(nodes: nodes)
        }
        .prefetchWindow(ahead: 10, behind: 3)
//        .tailFollow(.llmChat, pinTrigger: store.pinToken)
        .padding(.horizontal, 8)
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

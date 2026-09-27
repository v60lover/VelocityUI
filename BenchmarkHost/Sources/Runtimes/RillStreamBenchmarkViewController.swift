import RillUI
import SwiftUI
import UIKit

/// Picker-only counterpart to StreamBenchmarkViewController for the full stress fixture.
@MainActor
final class RillStreamBenchmarkViewController: UIViewController {
    private let harness: BenchmarkHarness
    private let turns: [StreamDataset.StreamTurn]
    private let tokensPerSecond: Double
    private let store = RillStreamStore()
    private let driver = StreamDriver()
    private let costRecorder = StreamCostRecorder(warmupTokens: 20)
    private var liveMetrics: LiveMetricsController?
    private var didStart = false
    private var deliveredCount = 0

    init(harness: BenchmarkHarness, turns: [StreamDataset.StreamTurn], tokensPerSecond: Double) {
        self.harness = harness
        self.turns = turns
        self.tokensPerSecond = tokensPerSecond
        super.init(nibName: nil, bundle: nil)
        title = "Rill — Full stream stress"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: RillStreamFeedView(store: store))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        costRecorder.start()
        driveTurns(startingAt: 0)
        if let scrollView = view.firstScrollView {
            let metrics = LiveMetricsController(
                scrollView: scrollView,
                harness: harness,
                imageMode: LaunchArguments().imageMode,
                runtimeLabel: "Rill-stream"
            )
            metrics.start()
            liveMetrics = metrics
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        driver.stop()
        costRecorder.stop()
        liveMetrics?.stop()
        liveMetrics = nil
    }

    private func driveTurns(startingAt index: Int) {
        guard index < turns.count else { return }
        let turn = turns[index]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.logFootprint("turn \(index + 1) before user bubble")
            self.store.addUserMessage(turn.userMessage)
            try? await Task.sleep(for: .seconds(2))
            guard self.view.window != nil else { return }
            self.logFootprint("turn \(index + 1) user bubble +2s")
            self.store.beginAssistantMessage()
            self.driver.start(
                tokens: turn.assistantChunks,
                tokensPerSecond: self.tokensPerSecond,
                onToken: { [weak self] token in
                    guard let self else { return }
                    self.deliveredCount += 1
                    self.costRecorder.recordDelivery { self.store.append(token) }
                },
                onEnd: { [weak self] in
                    guard let self else { return }
                    self.logFootprint("turn \(index + 1) end")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.logFootprint("turn \(index + 1) +2s")
                    }
                    if index + 1 == self.turns.count { self.printCostReport() }
                    self.driveTurns(startingAt: index + 1)
                }
            )
        }
    }

    private func printCostReport() {
        let total = turns.reduce(0) { $0 + $1.assistantChunks.count }
        let device = UIDevice.current
        #if DEBUG
        let config = "Debug"
        #else
        let config = "Release"
        #endif
        print("[cost] runtime=Rill delivered=\(deliveredCount)/\(total)")
        print("[cost] device=\(device.name) os=\(device.systemVersion) config=\(config) warmup=\(costRecorder.warmupTokens) tps=\(tokensPerSecond) scenario=large-stress")
        print("[cost] \(costRecorder.summary())")
        costRecorder.stop()
    }

    private func logFootprint(_ label: String) {
        let mb = Double(AllocationProbe.currentPhysFootprint()) / 1_048_576
        print("[memory] Rill \(label): phys_footprint=\(String(format: "%.1f", mb)) MB")
    }
}

@MainActor
private final class RillStreamStore: ObservableObject {
    enum Content {
        case user(String)
        case assistant(MarkdownSource)
    }

    struct Message: Identifiable {
        let id: Int
        let content: Content
    }

    @Published private(set) var messages: [Message] = []
    private var activeSource: MarkdownSource?

    func addUserMessage(_ text: String) {
        messages.append(Message(id: messages.count, content: .user(text)))
    }

    func beginAssistantMessage() {
        let source = MarkdownSource()
        activeSource = source
        messages.append(Message(id: messages.count, content: .assistant(source)))
    }

    func append(_ token: String) {
        activeSource?.append(token)
    }
}

private struct RillStreamFeedView: View {
    @ObservedObject var store: RillStreamStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(store.messages) { message in
                    switch message.content {
                    case .user(let text):
                        Text(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .assistant(let source):
                        StreamingMarkdownView(source)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

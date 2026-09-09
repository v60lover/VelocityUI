// LiveLLMViewController.swift

import SwiftUI
import UIKit
import VelocityUI

/// Runtime VC for the "Live LLM" scenario (VelocityUI-25q7) — third row in the picker's
/// "Scenarios" section, sibling of `StreamBenchmarkViewController` but driven by a real network
/// response instead of a canned token list. The user types a prompt in the bottom input bar; the
/// reply streams in from any OpenAI-compatible endpoint (`LiveLLMClient`) token by token into a
/// fresh `StreamingMarkdownController`, same "Option A" append-then-republish pattern the other
/// stream scenario uses.
@MainActor
final class LiveLLMViewController: UIViewController {
    private let environment: RenderEnvironment
    private let store = LiveLLMStore()
    private var settings: LiveLLMSettings
    private let inputBar = LiveLLMInputBar()
    private var streamTask: Task<Void, Never>?

    init(hotBlockRasterizeEnabled: Bool = true) {
        self.settings = LiveLLMSettings.load()
        self.environment = RenderEnvironment(hotBlockRasterizeEnabled: hotBlockRasterizeEnabled)
        super.init(nibName: nil, bundle: nil)
        title = "Live LLM"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(presentSettings)
        )

        let feedView = LiveLLMFeedView(store: store, environment: environment)
        let hostVC = UIHostingController(rootView: feedView)
        addChild(hostVC)
        view.addSubview(hostVC.view)
        hostVC.didMove(toParent: self)

        view.addSubview(inputBar)
        inputBar.onSend = { [weak self] text in self?.send(text) }

        hostVC.view.translatesAutoresizingMaskIntoConstraints = false
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostVC.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hostVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostVC.view.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        if settings.apiKey.isEmpty {
            store.addSystemNotice("No API key set yet — tap ⚙️ to add one (defaults to Groq's free OpenAI-compatible endpoint).")
        }
    }

    @objc private func presentSettings() {
        let alert = UIAlertController(title: "Live LLM Settings", message: "OpenAI-compatible provider (Groq, OpenRouter, Ollama, …)", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Base URL"; $0.text = self.settings.baseURL; $0.autocapitalizationType = .none; $0.keyboardType = .URL }
        alert.addTextField { $0.placeholder = "API key"; $0.text = self.settings.apiKey; $0.isSecureTextEntry = true; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "Model"; $0.text = self.settings.model; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            self.settings = LiveLLMSettings(
                baseURL: fields[0].text ?? self.settings.baseURL,
                apiKey: fields[1].text ?? self.settings.apiKey,
                model: fields[2].text ?? self.settings.model
            )
            self.settings.save()
        })
        present(alert, animated: true)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let baseURL = settings.resolvedBaseURL else {
            store.addSystemNotice("Invalid base URL — check ⚙️ settings.")
            return
        }

        store.addUserMessage(trimmed)
        let history = store.history
        store.beginAssistantMessage()

        let config = LiveLLMClient.ProviderConfig(baseURL: baseURL, apiKey: settings.apiKey, model: settings.model)
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in LiveLLMClient.streamChatCompletion(config: config, messages: history) {
                    self.store.append(delta)
                }
            } catch is CancellationError {
                // Superseded by a newer send() — leave the partial reply as-is.
            } catch {
                self.store.append("\n\n⚠️ \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Input bar

/// Bottom-pinned prompt bar — a multi-line `UITextView` (auto-growing up to 4 lines) plus a send
/// button, styled to read as a real chat composer rather than a benchmark-harness control.
private final class LiveLLMInputBar: UIView {
    var onSend: ((String) -> Void)?

    private let textView = UITextView()
    private let sendButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()
    private var textViewHeightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground

        let topRule = UIView()
        topRule.backgroundColor = .separator

        textView.font = .systemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .tertiarySystemBackground
        textView.layer.cornerRadius = 16
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        textView.isScrollEnabled = false
        textView.delegate = self

        placeholderLabel.text = "Message the model…"
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderText

        let sendSymbolConfig = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: sendSymbolConfig), for: .normal)
        sendButton.tintColor = .systemBlue
        sendButton.addTarget(self, action: #selector(tapSend), for: .touchUpInside)

        for v in [topRule, textView, placeholderLabel, sendButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textViewHeightConstraint,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 14),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 6),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapSend() {
        let text = textView.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend?(text)
        textView.text = ""
        textViewDidChange(textView)
        // No tap-through on rendered markdown yet — dropping the keyboard after send is the only
        // way to see the reply land without it being covered.
        textView.resignFirstResponder()
    }
}

extension LiveLLMInputBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        let maxHeight = textView.font!.lineHeight * 4 + textView.textContainerInset.top + textView.textContainerInset.bottom
        let fitSize = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        textViewHeightConstraint.constant = min(max(36, fitSize.height), maxHeight)
        textView.isScrollEnabled = fitSize.height > maxHeight
    }
}

// MARK: - Theme

extension MarkdownTheme {
    /// `.default` scaled down to a real chat-message size (17pt body, matching `UIFont.preferredFont(forTextStyle: .body)`)
    /// instead of the 20pt benchmark default, and headings stepped down to match.
    fileprivate static let liveLLM: MarkdownTheme = {
        var theme = MarkdownTheme.default
        theme.body = VFontDescriptor(size: 17, weight: VFontDescriptor.regularWeight)
        theme.code = VFontDescriptor(size: 14, weight: VFontDescriptor.regularWeight)
        theme.headings = [
            1: VFontDescriptor(size: 24, weight: VFontDescriptor.boldWeight),
            2: VFontDescriptor(size: 21, weight: VFontDescriptor.boldWeight),
            3: VFontDescriptor(size: 19, weight: VFontDescriptor.boldWeight),
            4: VFontDescriptor(size: 17, weight: VFontDescriptor.boldWeight),
            5: VFontDescriptor(size: 17, weight: VFontDescriptor.boldWeight),
            6: VFontDescriptor(size: 17, weight: VFontDescriptor.boldWeight),
        ]
        theme.headingFallback = VFontDescriptor(size: 17, weight: VFontDescriptor.boldWeight)
        return theme
    }()
}

// MARK: - SwiftUI-observable message store

/// Sibling of `StreamBenchmarkViewController`'s private `StreamStore`, not a reuse of it (that
/// one is `fileprivate` to its own file and tied to canned turns). Same "Option A" shape: grow
/// `messages` one bubble at a time, mutate the active assistant turn's
/// `StreamingMarkdownController` on `append(_:)`, then republish. Additionally keeps a raw-text
/// buffer per assistant turn (`rawText`) — `StreamingMarkdownController` has no plain-text
/// accessor, and `history` needs the exact bytes sent to the model, not a re-render of the parsed
/// tree.
@MainActor
private final class LiveLLMStore: ObservableObject {
    @Published var messages: [StreamMessage] = []
    @Published var pinToken = 0

    private var nextID = 0
    private var controllers: [Int: StreamingMarkdownController] = [:]
    private var rawText: [Int: String] = [:]
    private var activeAssistantID: Int?

    /// Plain-text turn history, oldest first, in the shape `LiveLLMClient` sends to the model.
    /// System notices are never part of the conversation the model sees.
    var history: [LiveLLMClient.Message] {
        messages.compactMap { message in
            switch message.content {
            case .user(let text):
                return LiveLLMClient.Message(role: "user", content: text)
            case .assistant:
                let text = rawText[message.id] ?? ""
                return text.isEmpty ? nil : LiveLLMClient.Message(role: "assistant", content: text)
            }
        }
    }

    func addUserMessage(_ text: String) {
        let id = nextID
        nextID += 1
        messages.append(StreamMessage(id: id, content: .user(text)))
        pinToken += 1
    }

    func addSystemNotice(_ text: String) {
        addUserMessage(text)
    }

    func beginAssistantMessage() {
        let id = nextID
        nextID += 1
        controllers[id] = StreamingMarkdownController(theme: .liveLLM)
        rawText[id] = ""
        messages.append(StreamMessage(id: id, content: .assistant(IncrementalMarkdownParser())))
        activeAssistantID = id
    }

    func controller(for id: Int) -> StreamingMarkdownController {
        controllers[id]!
    }

    func append(_ token: String) {
        guard let id = activeAssistantID, let controller = controllers[id] else { return }
        controller.append(token)
        rawText[id, default: ""] += token
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = StreamMessage(id: id, content: .assistant(controller.parser))
    }
}

// MARK: - SwiftUI feed view

private struct LiveLLMFeedView: View {
    @ObservedObject var store: LiveLLMStore
    let environment: RenderEnvironment

    var body: some View {
        AsyncFeed(items: store.messages, environment: environment) { message in
            let nodes: [any RenderNode]
            switch message.content {
            case .user(let text):
                nodes = [
                    TextNode(text)
                        .font(MarkdownTheme.liveLLM.body)
                        .messageRole(.user)
                ]
            case .assistant:
                nodes = store.controller(for: message.id).renderNodes
            }
            return LiveLLMCell(nodes: nodes)
        }
        .prefetchWindow(ahead: 10, behind: 3)
        .tailFollow(.llmChat, pinTrigger: store.pinToken)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

// MARK: - Cell DSL

private struct LiveLLMCell: RenderView {
    let nodes: [any RenderNode]

    var renderBody: some RenderNode {
        VStackNode(alignment: .leading, spacing: 6) {
            nodes
        }
    }
}

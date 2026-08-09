// LiveMetricsHUD.swift

import UIKit

/// Owns the on-screen HUD for one runtime screen in the manual/picker flow.
/// Bundles a `LiveMetricsCollector` (sampling) with a passthrough overlay window
/// (display), refreshed at a low fixed cadence so the overlay never competes with
/// the scroll path it is measuring.
///
/// Attach exactly once per runtime VC, and only when `orchestrator == nil` — the
/// headless measured path must never build this (it would add a second display
/// link and an overlay window to a run whose whole point is a clean measurement).
@MainActor
final class LiveMetricsController {

    private let collector: LiveMetricsCollector
    private let hudView: LiveMetricsHUDView
    private let window: PassthroughWindow
    private var refreshTimer: Timer?
    /// Non-nil only when launched with `--touch-speed` > 1 — see LaunchArguments.touchSpeedMultiplier.
    private let touchSpeedMultiplier: TouchSpeedMultiplier?
    private weak var scrollView: UIScrollView?

    /// - Parameters:
    ///   - scrollView: the runtime's scroll view (velocity + sampling source).
    ///   - harness: shared harness — read for live placeholder-churn counts.
    ///   - imageMode: shown in the header (RSS/alloc are only comparable within a mode).
    ///   - runtimeLabel: shown in the header (e.g. "VelocityUI", "Texture").
    ///   - targetFPS: display refresh ceiling for FPS colour-coding.
    init(
        scrollView: UIScrollView,
        harness: BenchmarkHarness,
        imageMode: LaunchArguments.ImageMode,
        runtimeLabel: String
    ) {
        self.collector = LiveMetricsCollector(scrollView: scrollView, harness: harness)
        self.scrollView = scrollView

        let targetFPS = scrollView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        self.hudView = LiveMetricsHUDView(
            runtimeLabel: runtimeLabel,
            imageMode: imageMode,
            targetFPS: Double(targetFPS)
        )

        if let scene = scrollView.window?.windowScene {
            self.window = PassthroughWindow(windowScene: scene)
        } else {
            self.window = PassthroughWindow(frame: UIScreen.main.bounds)
        }

        let multiplier = LaunchArguments().touchSpeedMultiplier
        self.touchSpeedMultiplier = multiplier > 1 ? TouchSpeedMultiplier(multiplier: CGFloat(multiplier)) : nil
    }

    func start() {
        let host = LiveMetricsHostViewController(hud: hudView)
        window.rootViewController = host
        window.passthroughView = hudView
        // Above the navigation bar but below system alerts.
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.isHidden = false

        collector.start()

        if let touchSpeedMultiplier, let scrollView {
            touchSpeedMultiplier.attach(to: scrollView)
        }

        // 4 Hz — legible without contributing meaningful main-thread load. The
        // snapshot math runs over the rolling window, off the per-frame path.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hudView.update(with: self.collector.snapshot())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        touchSpeedMultiplier?.detach()
        collector.stop()
        window.isHidden = true
        window.rootViewController = nil
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }
}

// MARK: - Passthrough window

/// A window that only intercepts touches landing inside `passthroughView`
/// (the HUD panel — so its collapse tap works); every other touch falls through
/// to the runtime's scroll view underneath.
final class PassthroughWindow: UIWindow {
    weak var passthroughView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let panel = passthroughView else { return nil }
        let local = panel.convert(point, from: self)
        guard panel.bounds.contains(local) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Root VC for the overlay window — pins the HUD panel to the top-leading safe area.
private final class LiveMetricsHostViewController: UIViewController {
    private let hud: LiveMetricsHUDView

    init(hud: LiveMetricsHUDView) {
        self.hud = hud
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hud.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
        ])
    }
}

// MARK: - HUD view

/// Compact translucent panel of live metric rows. Tap to collapse to just the
/// FPS line; tap again to expand.
final class LiveMetricsHUDView: UIView {

    private let targetFPS: Double
    private let header: String

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let stack = UIStackView()

    private let headerLabel = LiveMetricsHUDView.makeLabel(size: 10, weight: .semibold)
    private let fpsLabel = LiveMetricsHUDView.makeLabel(size: 20, weight: .bold)
    private let frameLabel = LiveMetricsHUDView.makeLabel(size: 11, weight: .regular)
    private let hitchLabel = LiveMetricsHUDView.makeLabel(size: 11, weight: .regular)
    private let rssLabel = LiveMetricsHUDView.makeLabel(size: 11, weight: .regular)
    private let allocLabel = LiveMetricsHUDView.makeLabel(size: 11, weight: .semibold)
    private let velocityLabel = LiveMetricsHUDView.makeLabel(size: 11, weight: .regular)
    private let churnLabel = LiveMetricsHUDView.makeLabel(size: 11, weight: .regular)
    private let suspectLabel = LiveMetricsHUDView.makeLabel(size: 11, weight: .regular)

    private var collapsed = false
    private var collapsibleRows: [UIView] {
        [frameLabel, hitchLabel, rssLabel, allocLabel, velocityLabel, churnLabel, suspectLabel]
    }

    init(runtimeLabel: String, imageMode: LaunchArguments.ImageMode, targetFPS: Double) {
        self.targetFPS = targetFPS
        self.header = "\(runtimeLabel) · \(imageMode.rawValue)"
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        layer.cornerRadius = 12
        layer.masksToBounds = true

        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        headerLabel.text = header
        headerLabel.textColor = .secondaryLabel
        [headerLabel, fpsLabel, frameLabel, hitchLabel, rssLabel, allocLabel, velocityLabel, churnLabel, suspectLabel]
            .forEach { stack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -10),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleCollapsed)))
    }

    @objc private func toggleCollapsed() {
        collapsed.toggle()
        collapsibleRows.forEach { $0.isHidden = collapsed }
    }

    func update(with s: LiveMetricsCollector.Snapshot) {
        fpsLabel.attributedText = colored(
            String(format: "%.0f fps", s.fps),
            color: fpsColor(s.fps)
        )

        frameLabel.attributedText = colored(
            String(format: "frame ms  %.1f / %.1f / %.1f", s.frameMsP50, s.frameMsP99, s.frameMsMax),
            color: frameColor(p99: s.frameMsP99)
        )

        hitchLabel.text = String(format: "hitches/1k  %.1f", s.hitchesPer1k)
        hitchLabel.textColor = s.hitchesPer1k > 5 ? .systemOrange : .white

        let deltaSign = s.rssDeltaBytes >= 0 ? "+" : "−"
        rssLabel.text = "RSS  \(mb(s.currentRSSBytes))  ·  peak \(mb(s.peakRSSBytes))  ·  Δ\(deltaSign)\(mb(abs(s.rssDeltaBytes)))"
        rssLabel.textColor = .white

        allocLabel.attributedText = colored(
            "alloc/frame  \(bytesShort(s.allocBytesPerFrame))",
            color: allocColor(s.allocBytesPerFrame)
        )

        velocityLabel.text = String(format: "scroll  %.0f pt/s", s.scrollVelocity)
        velocityLabel.textColor = .secondaryLabel

        churnLabel.text = "gray→img \(s.grayTransitions)   thumb→img \(s.thumbnailTransitions)"
        churnLabel.textColor = s.grayTransitions > 0 ? .systemRed : .secondaryLabel

        suspectLabel.text = "pipeline spawns \(s.pipelineTaskSpawns)"
        suspectLabel.textColor = .secondaryLabel
    }

    // MARK: - Formatting

    private func mb(_ bytes: Int) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private func bytesShort(_ bytes: Double) -> String {
        if bytes >= 1_048_576 { return String(format: "%.2f MB", bytes / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.0f KB", bytes / 1_024) }
        return String(format: "%.0f B", bytes)
    }

    private func colored(_ text: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.foregroundColor: color])
    }

    // MARK: - Colour coding

    private func fpsColor(_ fps: Double) -> UIColor {
        if fps >= targetFPS * 0.95 { return .systemGreen }
        if fps >= targetFPS * 0.8 { return .systemYellow }
        return .systemRed
    }

    private func frameColor(p99: Double) -> UIColor {
        let budgetMs = 1_000.0 / targetFPS
        if p99 <= budgetMs * 1.5 { return .systemGreen }
        if p99 <= budgetMs * 3 { return .systemYellow }
        return .systemRed
    }

    /// Phase 1 contract target is ~0 net heap/frame (see VelocityUI-zgs). A few KB
    /// of jitter is tolerable; hundreds of KB up to MBs is the regression this is
    /// meant to make visible.
    private func allocColor(_ bytesPerFrame: Double) -> UIColor {
        if bytesPerFrame < 65_536 { return .systemGreen }       // < 64 KB
        if bytesPerFrame < 524_288 { return .systemYellow }     // < 512 KB
        return .systemRed
    }

    private static func makeLabel(size: CGFloat, weight: UIFont.Weight) -> UILabel {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.textColor = .white
        label.numberOfLines = 1
        return label
    }
}

// LaunchArguments.swift

import Foundation

struct LaunchArguments {
    enum Runtime: String {
        case velocityUI = "velocityui"
        case swiftUILazyVStack = "swiftui-lazyvstack"
        case swiftUIList = "swiftui-list"
        case uiCollectionView = "uicollectionview"
        case texture = "texture"
    }

    enum ImageMode: String {
        case idiomatic
        case raw
    }

    enum VelocityProfile: String {
        case slow, medium, max
    }

    enum Scenario: String {
        case cold, warm
        case slowScrollFirstThreeItems = "slow-scroll-first-three-items"
        /// Physics-limited regime: prefetch cannot keep up at ScrollDriver.maxFling velocity.
        /// grayToImageTransitionCount must be 0 (decode-guaranteed placeholders always paint
        /// something image-shaped); thumbnailToImageTransitionCount documents how often the
        /// physics fallback engaged. See VelocityUI-1su.3.
        case maxFlingNoGray = "max-fling-no-gray"
        /// The Phase 1 contract scenario (VelocityUI-ah8.4): warm-up pass over a
        /// range bounded to fit inside the image cache, return to top, wait for
        /// footprint quiesce, then measure the SAME range a second time — a
        /// cache-hit replay where no decode is expected. This is what Q5 gates on.
        case replay
        /// ChatGPT-style streaming-text scenario (VelocityUI-xxf7): `StreamDriver` appends a
        /// canned markdown token stream into a single growing message via the VelocityUI-zuot
        /// public streaming API, instead of `ScrollDriver` driving `scrollView.contentOffset`.
        /// VelocityUI-only today — `--runtime` must be `velocityui` (or omitted). `--items` is
        /// not used (the token stream is a fixed, representative dataset); `--stream-rate` and
        /// `--hot-rasterize` are the scenario's own knobs (see their docs below). `--duration`
        /// is still the hard backstop, same role as every other scenario.
        case stream
    }

    enum HotBlockRasterizeMode: String {
        case on, off
    }

    var runtime: Runtime?
    var imageMode: ImageMode
    var velocityProfile: VelocityProfile
    var scenario: Scenario
    var itemCount: Int
    /// Seconds the measurement pass runs before auto-terminating. Defaults to 30 s.
    var measurementDuration: TimeInterval
    /// Items to prefetch ahead of visible cells. UICollectionView prefetch only; default matches VelocityUI's working range for fairness.
    var prefetchWindow: Int
    /// When true (`--live`) and a `--runtime` is set, the app opens that runtime
    /// directly in interactive live-HUD mode — no BenchmarkOrchestrator, no measured
    /// pass, no self-terminate. Lets you jump straight into one runtime's LiveMetricsHUD
    /// for hand-scroll profiling. Ignored in the headless matrix (which never passes it).
    var liveHUD: Bool
    /// Extra scroll speed multiplier applied on top of real finger movement
    /// (`--touch-speed <N>`, e.g. 3 for 3x). 1 (the default) means no amplification.
    /// Only the direct-drag portion is affected — momentum after the finger lifts
    /// still decelerates at native release velocity. See TouchSpeedMultiplier /
    /// VelocityUI-hbe item 5. Works in both `--live` and the plain manual/picker
    /// flow, since both attach a LiveMetricsController.
    var touchSpeedMultiplier: Double
    /// Tokens/second `StreamDriver` appends at (`--stream-rate <N>`). Only read by the `stream`
    /// scenario. Defaults to 20 — fast enough to finish the canned dataset well inside the
    /// default `--duration` backstop, slow enough that individual frame costs are still
    /// resolvable at 60 Hz (not multiple tokens landing in the same displaylink tick).
    var streamTokensPerSecond: Double
    /// `--hot-rasterize <on|off>` — threads into `RenderEnvironment.hotBlockRasterizeEnabled`
    /// for the `stream` scenario's ON/OFF toggle (VelocityUI-xxf7). Defaults to `.on`. Ignored
    /// by every other scenario.
    var hotBlockRasterizeMode: HotBlockRasterizeMode
    /// `--stream-text-only` — when set, `StreamDataset.interleavedRenderNodes` never splices in
    /// the `AsyncImageNode`/`SpacerNode` blocks, so the stream scenario has no network/decode
    /// dependency at all (pure text growth). The acceptance-criteria run does NOT set this — the
    /// interleaved non-text blocks are required there — this exists for a quick device sanity
    /// pass, or to isolate the text-rasterizer cost from image-decode noise. Ignored by every
    /// other scenario.
    var streamTextOnly: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        runtime = Self.value(for: "--runtime", in: args).flatMap(Runtime.init)
        imageMode = Self.value(for: "--image-mode", in: args).flatMap(ImageMode.init) ?? .idiomatic
        velocityProfile = Self.value(for: "--velocity-profile", in: args).flatMap(VelocityProfile.init) ?? .medium
        scenario = Self.value(for: "--scenario", in: args).flatMap(Scenario.init) ?? .warm
        itemCount = Self.value(for: "--items", in: args).flatMap(Int.init) ?? 100
        measurementDuration = Self.value(for: "--duration", in: args).flatMap(TimeInterval.init) ?? 30
        prefetchWindow = Self.value(for: "--prefetch-window", in: args).flatMap(Int.init) ?? 10
        liveHUD = args.contains("--live")
        touchSpeedMultiplier = Self.value(for: "--touch-speed", in: args).flatMap(Double.init) ?? 1.0
        streamTokensPerSecond = Self.value(for: "--stream-rate", in: args).flatMap(Double.init) ?? 20.0
        hotBlockRasterizeMode = Self.value(for: "--hot-rasterize", in: args).flatMap(HotBlockRasterizeMode.init) ?? .on
        streamTextOnly = args.contains("--stream-text-only")
    }

    /// Explicit-value init for unit tests — does not read from ProcessInfo.
    init(
        scenario: Scenario,
        velocityProfile: VelocityProfile = .medium,
        runtime: Runtime? = nil,
        imageMode: ImageMode = .idiomatic,
        itemCount: Int = 300,
        measurementDuration: TimeInterval = 30,
        prefetchWindow: Int = 10,
        liveHUD: Bool = false,
        touchSpeedMultiplier: Double = 1.0,
        streamTokensPerSecond: Double = 20.0,
        hotBlockRasterizeMode: HotBlockRasterizeMode = .on,
        streamTextOnly: Bool = false
    ) {
        self.scenario = scenario
        self.velocityProfile = velocityProfile
        self.runtime = runtime
        self.imageMode = imageMode
        self.itemCount = itemCount
        self.measurementDuration = measurementDuration
        self.prefetchWindow = prefetchWindow
        self.liveHUD = liveHUD
        self.touchSpeedMultiplier = touchSpeedMultiplier
        self.streamTokensPerSecond = streamTokensPerSecond
        self.hotBlockRasterizeMode = hotBlockRasterizeMode
        self.streamTextOnly = streamTextOnly
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1) else { return nil }
        return args[idx + 1]
    }
}

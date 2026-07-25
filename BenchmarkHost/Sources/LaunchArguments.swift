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
        case samePipeline = "same-pipeline"
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

    init() {
        let args = ProcessInfo.processInfo.arguments
        runtime = Self.value(for: "--runtime", in: args).flatMap(Runtime.init)
        imageMode = Self.value(for: "--image-mode", in: args).flatMap(ImageMode.init) ?? .idiomatic
        velocityProfile = Self.value(for: "--velocity-profile", in: args).flatMap(VelocityProfile.init) ?? .medium
        scenario = Self.value(for: "--scenario", in: args).flatMap(Scenario.init) ?? .warm
        itemCount = Self.value(for: "--items", in: args).flatMap(Int.init) ?? 100
        measurementDuration = Self.value(for: "--duration", in: args).flatMap(TimeInterval.init) ?? 30
        prefetchWindow = Self.value(for: "--prefetch-window", in: args).flatMap(Int.init) ?? 10
    }

    /// Explicit-value init for unit tests — does not read from ProcessInfo.
    init(
        scenario: Scenario,
        velocityProfile: VelocityProfile = .medium,
        runtime: Runtime? = nil,
        imageMode: ImageMode = .idiomatic,
        itemCount: Int = 100,
        measurementDuration: TimeInterval = 30,
        prefetchWindow: Int = 10
    ) {
        self.scenario = scenario
        self.velocityProfile = velocityProfile
        self.runtime = runtime
        self.imageMode = imageMode
        self.itemCount = itemCount
        self.measurementDuration = measurementDuration
        self.prefetchWindow = prefetchWindow
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1) else { return nil }
        return args[idx + 1]
    }
}

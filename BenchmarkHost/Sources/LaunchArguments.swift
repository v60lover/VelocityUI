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
    }

    var runtime: Runtime?
    var imageMode: ImageMode
    var velocityProfile: VelocityProfile
    var scenario: Scenario
    var itemCount: Int

    init() {
        let args = ProcessInfo.processInfo.arguments
        runtime = Self.value(for: "--runtime", in: args).flatMap(Runtime.init)
        imageMode = Self.value(for: "--image-mode", in: args).flatMap(ImageMode.init) ?? .idiomatic
        velocityProfile = Self.value(for: "--velocity-profile", in: args).flatMap(VelocityProfile.init) ?? .medium
        scenario = Self.value(for: "--scenario", in: args).flatMap(Scenario.init) ?? .warm
        itemCount = Self.value(for: "--items", in: args).flatMap(Int.init) ?? 100
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1) else { return nil }
        return args[idx + 1]
    }
}

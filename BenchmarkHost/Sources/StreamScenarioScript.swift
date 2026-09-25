// StreamScenarioScript.swift

import CoreGraphics

/// Host actions that a streaming cost run performs while tokens keep arriving
/// (VelocityUI-ln1g.1). Pure data: the view controller executes them.
enum StreamScenarioAction: Sendable, Equatable {
    /// Scroll so the streaming message is far off screen.
    case scrollAwayFromTail
    /// Scroll back so the streaming message is on screen again.
    case scrollToTail
    /// Change the feed's horizontal padding, which changes the layout width.
    case setHorizontalPadding(CGFloat)
}

struct StreamScenarioStep: Sendable, Equatable {
    /// The action fires just before this token index is delivered.
    let beforeToken: Int
    let action: StreamScenarioAction
}

struct StreamScenarioScript: Sendable, Equatable {
    let name: String
    let steps: [StreamScenarioStep]

    /// Actions due just before `tokenIndex`, in script order.
    func actions(before tokenIndex: Int) -> [StreamScenarioAction] {
        steps.filter { $0.beforeToken == tokenIndex }.map(\.action)
    }

    static let none = StreamScenarioScript(name: "in-view", steps: [])

    /// Streams while the message is off screen for the middle of the run.
    static func offscreen(from: Int, to: Int) -> StreamScenarioScript {
        StreamScenarioScript(name: "offscreen-\(from)-\(to)", steps: [
            .init(beforeToken: from, action: .scrollAwayFromTail),
            .init(beforeToken: to, action: .scrollToTail),
        ])
    }

    /// Leaves the message off screen for a long stretch, then returns, so it can be evicted and re-enter.
    static func evictAndReenter(leaveAt: Int, returnAt: Int) -> StreamScenarioScript {
        StreamScenarioScript(name: "evict-reenter-\(leaveAt)-\(returnAt)", steps: [
            .init(beforeToken: leaveAt, action: .scrollAwayFromTail),
            .init(beforeToken: returnAt, action: .scrollToTail),
        ])
    }

    /// Narrows then restores the layout width mid-stream.
    static func widthChange(at: Int, narrowPadding: CGFloat, restorePadding: CGFloat) -> StreamScenarioScript {
        StreamScenarioScript(name: "width-change-\(at)", steps: [
            .init(beforeToken: at, action: .setHorizontalPadding(narrowPadding)),
            .init(beforeToken: at + 50, action: .setHorizontalPadding(restorePadding)),
        ])
    }
}

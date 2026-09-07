// AsyncFeed+TestHooks.swift

#if canImport(UIKit)
import SwiftUI
import UIKit

#if canImport(XCTest)
extension AsyncFeed {
    /// Test-only: exercises the same coordinator-wiring path as `makeUIView(context:)` without a
    /// SwiftUI `Context` (no public initializer). Pass the same `Coordinator` across repeated calls
    /// to simulate SwiftUI re-invoking `makeUIView` for one view identity.
    func _testMakeUIView(coordinator: Coordinator) -> FeedScrollView<Item> {
        buildUIView(coordinator: coordinator)
    }

    /// Test-only: exercises `itemsDiffer` exactly as `updateUIView` does — comparing `uiView.items`
    /// against this struct's `items` — without requiring a SwiftUI `Context`.
    func _testItemsDiffer(uiView: FeedScrollView<Item>) -> Bool {
        itemsDiffer(uiView.items, items, on: uiView)
    }

    /// Test-only: exercises the same coordinator-refresh + pin-trigger-diff + items-diff path as
    /// `updateUIView(_:context:)` without a SwiftUI `Context`. `animate` mirrors what
    /// `shouldAnimate(context:)` would have returned.
    func _testUpdateUIView(uiView: FeedScrollView<Item>, coordinator: Coordinator, animate: Bool = false) {
        performUpdate(uiView: uiView, coordinator: coordinator, animate: animate)
    }
}
#endif
#endif

// StreamMessage.swift

import VelocityUI

/// `AsyncFeed`'s `Item` for the `stream` scenario (VelocityUI-xxf7) — a single growing chat
/// message. The app owns `parser` and mutates it with `.append(_:)` as `StreamDriver` emits
/// tokens, then pushes a fresh value back into the SwiftUI state `AsyncFeed` observes — the same
/// "Option A" pattern `StreamingMarkdownFeedIntegrationTests` exercises against the library
/// directly, driven here through a real `StreamDriver` instead of a hand-written token loop.
struct StreamMessage: Identifiable, Sendable, Equatable {
    let id: Int
    var parser: IncrementalMarkdownParser
}

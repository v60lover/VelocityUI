// StreamMessage.swift

import VelocityUI

/// `AsyncFeed`'s `Item` for the `stream` scenario (VelocityUI-xxf7) — a growing transcript of
/// static user questions (`.user`) interleaved with streamed assistant answers (`.assistant`),
/// one bubble per turn. The app owns each assistant turn's `parser` and mutates it with
/// `.append(_:)` as `StreamDriver` emits tokens, then pushes a fresh value back into the SwiftUI
/// state `AsyncFeed` observes — the same "Option A" pattern `StreamingMarkdownFeedIntegrationTests`
/// exercises against the library directly, driven here through a real `StreamDriver` instead of a
/// hand-written token loop.
struct StreamMessage: Identifiable, Sendable, Equatable {
    /// Rendered via `.messageRole(_:)` (VelocityUI-xxxx) — `.user` gets the right-aligned bubble,
    /// `.assistant` the default full-width look.
    enum Content: Sendable, Equatable {
        case user(String)
        case assistant(IncrementalMarkdownParser)
    }

    let id: Int
    var content: Content
}

// HighlightRegistry.swift

import Foundation
import os

/// Composition-root collaborator: an entry-count-bounded LRU cache of compiled syntax-highlighting
/// grammars, plus the active color theme. One instance per `AsyncFeed`, owned by
/// `RenderEnvironment`, injected downstream — no singleton, no static shared, no global grammar
/// cache. This is what lets two feeds run different themes at once and lets tests inject a fake
/// registry.
///
/// A plain `Sendable` class, not an actor, so `grammar(for:)` stays synchronous — the off-main
/// syntax highlighter (VelocityUI-oz5q.3) calls it from a `Task`, never with an `await`. State is
/// guarded by `OSAllocatedUnfairLock`, mirroring `FrozenBitmapStore`.
///
/// `themeGeneration` bumps on every real theme change. A later bead folds this counter into a
/// rendered code block's cache key so switching theme invalidates cached rasters instead of
/// leaving stale colors on screen — that wiring is not done here, only the counter itself.
public final class HighlightRegistry: Sendable {

    /// LRU list node. `@unchecked Sendable`: `grammar` is itself `Sendable` (an immutable
    /// `CompiledGrammar`), but every access to this node happens under `state.withLock`.
    final class Node: @unchecked Sendable {
        let languageID: LanguageID
        let grammar: CompiledGrammar
        weak var prev: Node?
        weak var next: Node?

        init(languageID: LanguageID, grammar: CompiledGrammar) {
            self.languageID = languageID
            self.grammar = grammar
        }
    }

    struct State {
        /// Sole strong owner of every `Node`.
        var entries: [LanguageID: Node] = [:]
        /// Oldest = next eviction victim.
        weak var head: Node?
        /// Most-recently-used.
        weak var tail: Node?
        var capacity: Int
        var activeTheme: Theme
        var themeGeneration: Int = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    /// `capacity: 8` covers the seven v1 languages (swift, javascript, typescript, python, json,
    /// bash, sql) plus `.plaintext` with no eviction in the common case.
    public init(capacity: Int = 8, activeTheme: Theme = .defaultLight) {
        self.state = OSAllocatedUnfairLock(initialState: State(capacity: capacity, activeTheme: activeTheme))
    }

    /// The current active theme (light or dark).
    public var activeTheme: Theme {
        state.withLock { $0.activeTheme }
    }

    /// Bumps once per real theme change. Starts at 0.
    public var themeGeneration: Int {
        state.withLock { $0.themeGeneration }
    }

    /// Replaces the active theme. A no-op (no generation bump) if `theme` equals the current
    /// active theme — nothing actually changed, so nothing should invalidate.
    public func setActiveTheme(_ theme: Theme) {
        state.withLock { st in
            guard theme != st.activeTheme else { return }
            st.activeTheme = theme
            st.themeGeneration += 1
        }
    }

    /// Synchronous lookup. A hit bumps `languageID` to most-recently-used and returns the SAME
    /// `CompiledGrammar` instance. A miss compiles a fresh grammar, caches it, and evicts the
    /// least-recently-used entry if now over `capacity`.
    ///
    /// "Compile" is a placeholder today — `CompiledGrammar(languageID:)` carries no rule table yet.
    /// The real grammar data (TextMate vs tree-sitter) is filled in by VelocityUI-oz5q.3; this
    /// registry only needs something to cache and hand back by identity.
    public func grammar(for languageID: LanguageID) -> CompiledGrammar {
        state.withLock { st in
            if let node = st.entries[languageID] {
                Self.touch(&st, node)
                return node.grammar
            }
            let node = Node(languageID: languageID, grammar: CompiledGrammar(languageID: languageID))
            st.entries[languageID] = node
            Self.appendAtTail(&st, node)
            Self.evictLRUUntilWithinCapacity(&st)
            return node.grammar
        }
    }

    // MARK: - Private (all operate under the lock — never call outside `state.withLock`)

    /// Unlinks `node` from the list without touching `entries`.
    private static func unlink(_ st: inout State, _ node: Node) {
        let prev = node.prev
        let next = node.next
        if let prev {
            prev.next = next
        } else {
            st.head = next
        }
        if let next {
            next.prev = prev
        } else {
            st.tail = prev
        }
        node.prev = nil
        node.next = nil
    }

    /// Appends `node` at the tail (most-recently-used end). `node` must already be detached.
    private static func appendAtTail(_ st: inout State, _ node: Node) {
        node.prev = st.tail
        node.next = nil
        if let oldTail = st.tail {
            oldTail.next = node
        } else {
            st.head = node
        }
        st.tail = node
    }

    /// Moves `node` to the tail (most-recently-used end) — a lookup hit.
    private static func touch(_ st: inout State, _ node: Node) {
        unlink(&st, node)
        appendAtTail(&st, node)
    }

    private static func remove(_ st: inout State, _ languageID: LanguageID) {
        guard let node = st.entries.removeValue(forKey: languageID) else { return }
        unlink(&st, node)
    }

    private static func evictLRUUntilWithinCapacity(_ st: inout State) {
        while st.entries.count > st.capacity {
            guard let victim = st.head else { break }
            remove(&st, victim.languageID)
        }
    }
}

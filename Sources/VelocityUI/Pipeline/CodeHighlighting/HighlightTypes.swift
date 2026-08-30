// HighlightTypes.swift

import Foundation
import CoreGraphics
import SwiftTreeSitter

/// v1 language set for the syntax highlighter (VelocityUI-oz5q.3 picks the engine).
/// `.plaintext` is the fallback for `nil`/unrecognized fence info strings — no colors, never an error.
public enum LanguageID: Hashable, Sendable {
    case swift
    case javascript
    case typescript
    case python
    case json
    case bash
    case sql
    case plaintext
}

public extension LanguageID {
    /// Maps a fenced-code-block's raw fence-info string (e.g. "python", "js", `nil`) to a
    /// grammar lookup key. Unrecognized or missing language falls back to `.plaintext` --
    /// same "never an error" contract `TreeSitterHighlighter` already applies to any
    /// unwired language (`.typescript`, `.sql`).
    init(fenceInfo: String?) {
        switch fenceInfo?.lowercased() {
        case "swift": self = .swift
        case "js", "javascript", "jsx": self = .javascript
        case "ts", "typescript", "tsx": self = .typescript
        case "py", "python": self = .python
        case "json": self = .json
        case "bash", "sh", "shell", "zsh": self = .bash
        case "sql": self = .sql
        default: self = .plaintext
        }
    }
}

/// Token categories a `SyntaxHighlighter` colors independently of language.
public enum TokenType: Hashable, Sendable {
    case keyword
    case string
    case number
    case comment
    case type
    case function
    case plain
}

/// A compiled grammar for one language. A `final class`, not a struct, so `HighlightRegistry`'s
/// LRU cache can hand back the SAME instance by reference identity on a hit instead of
/// recompiling — that's the whole point of caching it.
///
/// `language`/`highlightsQuery` are `nil` for `.plaintext` and for any language whose grammar
/// isn't wired up yet (`.typescript`, `.sql` — see `GrammarCompiler.swift`). `TreeSitterHighlighter`
/// treats both cases identically: empty color runs, never an error. Kept `internal`, not `public`
/// — the tree-sitter types are an engine-implementation detail behind `SyntaxHighlighter`, not
/// part of the library's public surface.
public final class CompiledGrammar: Sendable {
    public let languageID: LanguageID
    let language: Language?
    let highlightsQuery: Query?

    init(languageID: LanguageID, language: Language?, highlightsQuery: Query?) {
        self.languageID = languageID
        self.language = language
        self.highlightsQuery = highlightsQuery
    }
}

/// One colored span within a single sealed line, in UTF-16 code-unit offsets local to that line.
/// `color` is already resolved against the `Theme` passed to `colorRuns(for:grammar:theme:)` —
/// callers (the rasteriser in VelocityUI-oz5q.4) apply it directly, no second theme lookup.
public struct ColorRun: Sendable, Hashable {
    public let range: Range<Int>
    public let tokenType: TokenType
    public let color: VColorDescriptor

    public init(range: Range<Int>, tokenType: TokenType, color: VColorDescriptor) {
        self.range = range
        self.tokenType = tokenType
        self.color = color
    }
}

/// The color runs for one sealed line, in left-to-right document order.
public struct LineColorRuns: Sendable, Hashable {
    public let runs: [ColorRun]

    public init(runs: [ColorRun]) {
        self.runs = runs
    }
}

/// Turns sealed code lines into per-line color runs. `nonisolated` and pure: same
/// `(lines, grammar, theme)` in -> same runs out, no global state read. A partial (unsealed)
/// trailing line must never be passed in — callers seal lines before calling this.
public protocol SyntaxHighlighter: Sendable {
    func colorRuns(for lines: ArraySlice<String>, grammar: CompiledGrammar, theme: Theme) -> [LineColorRuns]
}

/// token-type -> color mapping for one appearance (light or dark). `color(for:)` falls back to
/// `.primary` for any `TokenType` missing from `colors`.
public struct Theme: Sendable, Hashable {
    public enum Appearance: Sendable, Hashable {
        case light
        case dark
    }

    public let appearance: Appearance
    public let colors: [TokenType: VColorDescriptor]

    public init(appearance: Appearance, colors: [TokenType: VColorDescriptor]) {
        self.appearance = appearance
        self.colors = colors
    }

    public func color(for tokenType: TokenType) -> VColorDescriptor {
        colors[tokenType] ?? .primary
    }

    /// Built-in default light theme — a placeholder editorial palette, not pixel-matched to any
    /// specific editor. Swap freely once design has an opinion.
    public static let defaultLight = Theme(appearance: .light, colors: [
        .keyword: VColorDescriptor(red: 0.68, green: 0.10, blue: 0.42, alpha: 1),
        .string: VColorDescriptor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1),
        .number: VColorDescriptor(red: 0.11, green: 0.0, blue: 0.81, alpha: 1),
        .comment: VColorDescriptor(red: 0.42, green: 0.47, blue: 0.51, alpha: 1),
        .type: VColorDescriptor(red: 0.17, green: 0.35, blue: 0.53, alpha: 1),
        .function: VColorDescriptor(red: 0.32, green: 0.25, blue: 0.6, alpha: 1),
        .plain: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
    ])

    /// Built-in default dark theme.
    public static let defaultDark = Theme(appearance: .dark, colors: [
        .keyword: VColorDescriptor(red: 0.97, green: 0.44, blue: 0.63, alpha: 1),
        .string: VColorDescriptor(red: 0.99, green: 0.55, blue: 0.38, alpha: 1),
        .number: VColorDescriptor(red: 0.66, green: 0.8, blue: 1.0, alpha: 1),
        .comment: VColorDescriptor(red: 0.51, green: 0.55, blue: 0.59, alpha: 1),
        .type: VColorDescriptor(red: 0.5, green: 0.83, blue: 0.99, alpha: 1),
        .function: VColorDescriptor(red: 0.85, green: 0.72, blue: 0.99, alpha: 1),
        .plain: VColorDescriptor(red: 1, green: 1, blue: 1, alpha: 1),
    ])
}

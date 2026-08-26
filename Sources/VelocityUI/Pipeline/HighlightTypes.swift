// HighlightTypes.swift

import Foundation
import CoreGraphics

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
/// recompiling — that's the whole point of caching it. Opaque today: the real rule table
/// (TextMate vs tree-sitter) is chosen in VelocityUI-oz5q.3, which will extend this type.
public final class CompiledGrammar: Sendable {
    public let languageID: LanguageID

    public init(languageID: LanguageID) {
        self.languageID = languageID
    }
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

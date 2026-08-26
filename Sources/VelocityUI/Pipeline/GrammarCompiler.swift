// GrammarCompiler.swift

import Foundation
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterBash
import TreeSitterSwift

/// Compiles a `CompiledGrammar` for `languageID`. Called by `HighlightRegistry` on a cache miss.
///
/// Never throws: a language with no grammar wired up yet, or a highlights query that fails to
/// compile against its grammar, both degrade to a `CompiledGrammar` with `language`/
/// `highlightsQuery` set to `nil` — `TreeSitterHighlighter` treats that identically to
/// `.plaintext` (empty color runs), never an error.
func compileGrammar(for languageID: LanguageID) -> CompiledGrammar {
    guard let spec = grammarSpec(for: languageID) else {
        return CompiledGrammar(languageID: languageID, language: nil, highlightsQuery: nil)
    }
    guard let query = try? Query(language: spec.language, data: Data(spec.highlightsQuery.utf8)) else {
        return CompiledGrammar(languageID: languageID, language: nil, highlightsQuery: nil)
    }
    return CompiledGrammar(languageID: languageID, language: spec.language, highlightsQuery: query)
}

private struct GrammarSpec {
    let language: Language
    let highlightsQuery: String
}

/// v1 grammar wiring. `.typescript` and `.sql` intentionally return `nil` — see
/// `Package.swift`'s dependency comment (typescript adds a second grammar not in the acceptance
/// criteria; DerekStride/tree-sitter-sql's own manifest fails to resolve under this toolchain).
/// Both fall back to plaintext exactly like `.plaintext` itself.
private func grammarSpec(for languageID: LanguageID) -> GrammarSpec? {
    switch languageID {
    case .swift:
        return GrammarSpec(language: Language(language: tree_sitter_swift()), highlightsQuery: HighlightQueries.swift)
    case .javascript:
        return GrammarSpec(language: Language(language: tree_sitter_javascript()), highlightsQuery: HighlightQueries.javascript)
    case .python:
        return GrammarSpec(language: Language(language: tree_sitter_python()), highlightsQuery: HighlightQueries.python)
    case .json:
        return GrammarSpec(language: Language(language: tree_sitter_json()), highlightsQuery: HighlightQueries.json)
    case .bash:
        return GrammarSpec(language: Language(language: tree_sitter_bash()), highlightsQuery: HighlightQueries.bash)
    case .typescript, .sql, .plaintext:
        return nil
    }
}

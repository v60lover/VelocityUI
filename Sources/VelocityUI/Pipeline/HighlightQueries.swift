// HighlightQueries.swift

/// Our own curated tree-sitter highlights queries, one per v1 language — NOT the grammar's
/// bundled `highlights.scm` (VelocityUI-wmss.4.1 spike: the bundled queries don't surface as
/// SPM resources on macOS, and we need captures mapped to our own `TokenType` anyway). Trimmed
/// to patterns with no `#match?`/`#is-not?` predicates: predicates need a source-text provider
/// we don't wire up, and the plain node-type patterns already cover keyword/string/number/
/// comment/type/function — the token categories `TokenType` distinguishes.
enum HighlightQueries {
    static let json = """
    (string) @string
    (number) @number
    (true) @constant.builtin
    (false) @constant.builtin
    (null) @constant.builtin
    """

    static let javascript = """
    (comment) @comment
    [(string) (template_string)] @string
    (number) @number
    [(true) (false) (null) (undefined)] @constant.builtin
    (function_declaration name: (identifier) @function)
    (function_expression name: (identifier) @function)
    (method_definition name: (property_identifier) @function.method)
    (call_expression function: (identifier) @function)
    (call_expression function: (member_expression property: (property_identifier) @function.method))
    [
      "as" "async" "await" "break" "case" "catch" "class" "const" "continue"
      "debugger" "default" "delete" "do" "else" "export" "extends" "finally"
      "for" "from" "function" "get" "if" "import" "in" "instanceof" "let"
      "new" "of" "return" "set" "static" "switch" "target" "throw" "try"
      "typeof" "var" "void" "while" "with" "yield"
    ] @keyword
    """

    static let python = """
    (comment) @comment
    (string) @string
    [(integer) (float)] @number
    [(none) (true) (false)] @constant.builtin
    (function_definition name: (identifier) @function)
    (call function: (identifier) @function)
    (call function: (attribute attribute: (identifier) @function.method))
    (type (identifier) @type)
    [
      "and" "as" "assert" "async" "await" "break" "class" "continue" "def"
      "del" "elif" "else" "except" "finally" "for" "from" "global" "if"
      "import" "in" "is" "lambda" "nonlocal" "not" "or" "pass" "raise"
      "return" "try" "while" "with" "yield" "match" "case"
    ] @keyword
    """

    static let bash = """
    [(string) (raw_string)] @string
    (comment) @comment
    (command_name) @function
    (function_definition name: (word) @function)
    (file_descriptor) @number
    [
      "case" "do" "done" "elif" "else" "esac" "export" "fi" "for" "function"
      "if" "in" "select" "then" "unset" "until" "while"
    ] @keyword
    """

    static let swift = """
    [(comment) (multiline_comment)] @comment
    [(line_str_text) (multi_line_str_text) (raw_str_part) (raw_str_end_part)] @string
    [(integer_literal) (hex_literal) (oct_literal) (bin_literal) (real_literal)] @number
    [(boolean_literal) "nil"] @constant.builtin
    (type_identifier) @type
    (function_declaration (simple_identifier) @function.method)
    (call_expression (simple_identifier) @function.call)
    [
      "func" "deinit" "protocol" "extension" "indirect" "nonisolated" "override"
      "convenience" "required" "some" "any" "weak" "unowned" "didSet" "willSet"
      "subscript" "let" "var" "enum" "struct" "class" "typealias" "async" "await"
      "import" "case" "if" "for" "while" "return" "guard" "in"
      "try" "break" "continue" "switch" "static"
    ] @keyword
    [(else) (catch_keyword) (default_keyword) (throw_keyword)] @keyword
    """
}

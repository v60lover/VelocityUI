// MarkdownTheme.swift

/// Maps each markdown block kind to the font it renders in — the explicit replacement for the
/// old hardcoded size formula in `IncrementalMarkdownParser.style(_:)`. A plain value type: set
/// it once at `StreamingMarkdownController` construction (or pass it into `renderNodes(theme:)` /
/// `blockList(itemID:width:theme:)`) and leave it fixed for that parser's lifetime — sealed
/// blocks are styled once and cached, so mutating a live controller's theme mid-stream won't
/// restyle blocks already sealed.
///
///     var theme = MarkdownTheme.default
///     theme.headings[2] = VFontDescriptor(size: 22, weight: VFontDescriptor.boldWeight)  // ## -> 22pt
///     let message = StreamingMarkdownController(theme: theme)
public struct MarkdownTheme: Sendable, Hashable {
    /// Body-like blocks: paragraphs, list items, blockquotes, table rows, thematic breaks.
    public var body: VFontDescriptor
    /// Fenced code blocks (the block itself; inline `code` spans are styled separately).
    public var code: VFontDescriptor
    /// Per-level heading fonts, keyed by level (1...6). A level with no entry uses `headingFallback`.
    public var headings: [Int: VFontDescriptor]
    /// Font for any heading level missing from `headings`.
    public var headingFallback: VFontDescriptor

    public init(
        body: VFontDescriptor,
        code: VFontDescriptor,
        headings: [Int: VFontDescriptor],
        headingFallback: VFontDescriptor
    ) {
        self.body = body
        self.code = code
        self.headings = headings
        self.headingFallback = headingFallback
    }

    /// Font for a heading of the given level; `headingFallback` when the level isn't mapped.
    public func heading(level: Int) -> VFontDescriptor {
        headings[level] ?? headingFallback
    }

    /// A scale tuned to the 20pt body: bold headings that step down gently and never render
    /// smaller than body text. h1 28, h2 24, h3 22, h4–h6 20 (bold at body size). Replaces the
    /// old `max(15, 28 - (level - 1) * 3)` ramp, which jumped hard at h2 and made h4–h6 smaller
    /// than body. Change any entry to retune.
    public static let `default` = MarkdownTheme(
        body: VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight),
        code: VFontDescriptor(size: 20, weight: VFontDescriptor.regularWeight),
        headings: [
            1: VFontDescriptor(size: 28, weight: VFontDescriptor.boldWeight),
            2: VFontDescriptor(size: 24, weight: VFontDescriptor.boldWeight),
            3: VFontDescriptor(size: 22, weight: VFontDescriptor.boldWeight),
            4: VFontDescriptor(size: 20, weight: VFontDescriptor.boldWeight),
            5: VFontDescriptor(size: 20, weight: VFontDescriptor.boldWeight),
            6: VFontDescriptor(size: 20, weight: VFontDescriptor.boldWeight),
        ],
        headingFallback: VFontDescriptor(size: 20, weight: VFontDescriptor.boldWeight)
    )
}

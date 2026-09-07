# Changelog

All notable changes to VelocityUI are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the library is pre-1.0, minor (`0.x`) releases may include breaking API changes.

## [Unreleased]

### Planned priority
- Shelf layouts.
- Tap handling for rendered content (tap, select text, etc).
- Hosting view API for custom views
- Sectioned grids
- Gifs/Video handling
- 

## [0.5.0] — 2026-09-08

This release expands the streaming Markdown renderer and adds the lower-level layout and scroll
behavior needed for LLM-style chat feeds.

### Added
- **Markdown tables** — a `MarkdownTableNode`, cell layout and column-width solving, single-image
  table rasterization, and horizontal scrolling for tables wider than the viewport.
- **Inline and display math** — parser support for math delimiters, inline math attachments, and
  block math rasterization with horizontal scrolling for wide formulas.
- **More Markdown syntax** — autolinks and bare URLs, backslash escapes, task-list checkboxes,
  thematic rules, and styled blockquotes.
- **Chat message layout** — `TextNode.messageRole(_:)`, horizontal alignment and maximum-width
  controls, plus pre-rounded user-message backgrounds.
- **LLM tail following** — `TailFollowMode.llmChat`, a pinned trailing spacer, automatic
  scroll-to-bottom engagement, user-scroll disengagement and re-engagement, and display-paced
  critically damped animation.
- **Streaming reveal animation** — newly appended fragment tails fade in without restarting the
  already visible part of a block, while Reduce Motion keeps updates instant.
- **Raster diagnostics** — a feed-scoped observer for cache misses, repairs, evictions, and
  repaint failures without exposing rendered text.

### Changed
- Frozen bitmap budgeting now tracks actual raster artifacts instead of logical block counts.
- Raster reads, writes, promotion, repair, and eviction now share canonical `BlockKey`
  construction.
- Raster invalidation and replacement scheduling now happen atomically at the `RenderPipeline`
  actor boundary.
- The benchmark host now includes an LLM-chat mode and expanded streaming Markdown fixtures.
- Updated the public runtime version and installation guidance to `0.5.0` and refreshed the
  README with streaming-first examples and video-link placeholders.

### Fixed
- Detects missing raster artifacts and schedules asynchronous repair instead of leaving blank or
  stale content on screen.
- Prevents the loading placeholder from flashing on text-only streaming messages while keeping it
  for image, GIF, and video cells.
- Corrected table row heights, column widths, alignment, and math-block rendering edge cases.

## [0.4.0] — 2026-09-01

First tagged release. The four-layer engine works end-to-end and is covered by 130+ tests;
the public API is still moving.

### Added
- **Core engine** — four-layer architecture (DSL → off-main render pipeline → CALayer scroll
  container → media pipeline) with a single-instance `RenderEnvironment` composition root and
  no singletons.
- **Developer DSL** — `AsyncFeed`, `RenderView`, `@RenderNodeBuilder`, and the node set
  (`VStackNode`/`HStackNode`/`ZStackNode`, `TextNode`, `AsyncImageNode`, `AsyncGIFNode`,
  `AsyncVideoNode`, `SpacerNode`, `HostingNode`).
- **Scroll container** — pooled CALayer-backed cells with a fully synchronous scroll path,
  two-phase commit (geometry first, media second), and no `UICollectionView`.
- **Media pipeline** — `ImageActor`, `GIFActor`, `VideoController`, and `VideoPreparationActor`
  on custom `DispatchQueue`-backed executors; decode-time corner rounding and BGRA8888
  normalisation; BlurHash-style placeholder decode.
- **Layout** — grid/vertical `GridLayout`, ring-buffer `WorkingRange`, `LayoutCache`, and a
  pooled TextKit 2 `TextMeasurementPool`.
- **Streaming Markdown** — `IncrementalMarkdownParser` (block sealing + one hot block),
  validated against `swift-markdown` as a test-time differential parse oracle; streaming text
  rasterization that freezes sealed blocks to bitmap tiles.
- **Code blocks** — tree-sitter syntax highlighting (Swift, JavaScript, Python, JSON, Bash),
  two-layer streaming delivery (sealed body + live tail), and `UIScrollView`-like horizontal
  code scrolling with momentum and edge spring.
- **Tables** — GFM table parsing (grouped rows) with a column-width solver.
- **Math** — vendored pure-Swift LaTeX engine (SwaTex) rendering straight to `CGImage`.
- `VelocityUIVersion.current` runtime version constant.

### Notes
- Requires iOS 17+, Swift 6, Xcode 16+.
- Licensed under Apache-2.0.

[Unreleased]: https://github.com/v60lover/VelocityUI/compare/0.5.0...HEAD
[0.5.0]: https://github.com/v60lover/VelocityUI/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/v60lover/VelocityUI/releases/tag/0.4.0

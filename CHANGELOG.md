# Changelog

All notable changes to VelocityUI are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the library is pre-1.0, minor (`0.x`) releases may include breaking API changes.

## [Unreleased]

### Planned
- `StreamingChatFeed` high-level DSL surface (bubbles, roles, auto-scroll-to-bottom).
- More tree-sitter grammars (C, Rust, Go, TypeScript; SQL deferred on a toolchain issue).
- Inline Markdown links, images, and blockquotes.
- Math display-mode block layout and baseline alignment in running text.
- Accessibility pass for streaming content.

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

[Unreleased]: https://github.com/v60lover/VelocityUI/compare/0.4.0...HEAD
[0.4.0]: https://github.com/v60lover/VelocityUI/releases/tag/0.4.0

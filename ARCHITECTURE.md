# VelocityUI — Architecture

> High-performance scrolling feeds and grids with videos, GIFs, and images on iOS.
> **"Texture rebuilt from scratch with Swift 6, async/await, structured concurrency,
> and a SwiftUI-syntax DSL — none of SwiftUI's rendering pipeline in the hot path."**

Source of truth: `velocityui-prompt.md` (full engineering spec). This document is the
explanatory companion — what the pieces are, how data flows between them, and why the
unusual decisions exist.

---

## 1. The Problem

No existing library combines all of:

1. SwiftUI-syntax developer API
2. Parallel off-main layout (pure functions + `TaskGroup`)
3. CALayer-direct rendering (no UIView per cell, no UICollectionView)
4. Async media pipeline (images / GIFs / video)
5. React-inspired structural diffing
6. Swift 6 strict concurrency
7. A synchronous scroll fast-path with **zero async hops**

| Alternative | Why it falls short |
|---|---|
| Texture / AsyncDisplayKit | ObjC++ core, no Swift Concurrency, effectively unmaintained |
| SwiftUI native | All `body` eval, layout, text sizing on `@MainActor` |
| UICollectionView + UIHostingConfiguration | Still runs the SwiftUI view graph per cell |
| Airbnb Epoxy | Declarative wrapper only — no async layout engine, no media pipeline |

---

## 2. Four-Layer Overview

Each layer communicates via `Sendable` value types only, enforced by the Swift 6
compiler. No mutable shared state crosses a layer boundary.

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Developer DSL  (@MainActor, SwiftUI-like)     │
│                                                         │
│  RenderView + @RenderNodeBuilder result builder         │
│  VStackNode · HStackNode · ZStackNode · SpacerNode      │
│  TextNode · AsyncImageNode · AsyncGIFNode               │
│  AsyncVideoNode · HostingNode (UIView escape hatch)     │
└────────────────────────┬────────────────────────────────┘
                         │ NodeTable
                         │ (flat Sendable value type — NO existentials)
┌────────────────────────▼────────────────────────────────┐
│  Layer 2: Render Pipeline  (off-main, parallel)         │
│                                                         │
│  Allocation-free differ + 3-tier change classifier      │
│  measureNode(): nonisolated pure fn, fanned out via     │
│    TaskGroup on the cooperative pool                    │
│  TextMeasurementPool (pooled TextKit 2 contexts)        │
│  LayoutCache: actor (the only shared mutable state)     │
│  WorkingRange: contiguous ring buffer                   │
└────────────────────────┬────────────────────────────────┘
                         │ ResolvedLayout
                         │ (O(1) ring-buffer lookup during scroll)
┌────────────────────────▼────────────────────────────────┐
│  Layer 3: Scroll Container  (@MainActor, UIScrollView)  │
│                                                         │
│  Custom cell lifecycle — NO UICollectionView            │
│  CALayer-backed RenderCell pool                         │
│  Scroll path: zero async hops, zero Task spawns         │
│  Two-phase commit: geometry first, media second         │
│  UIView interaction overlay: taps + accessibility       │
└────────────────────────┬────────────────────────────────┘
                         │ triggers media fetch/decode
┌────────────────────────▼────────────────────────────────┐
│  Layer 4: Media Pipeline  (custom-executor actors)      │
│                                                         │
│  Network fetch: plain async (I/O suspends, any thread)  │
│  Decode: bounded concurrent DispatchQueues, isolated    │
│    from the cooperative pool                            │
│  ImageActor · GIFActor · VideoController +              │
│  VideoPreparationActor                                  │
│  Rounding + BGRA8888 normalisation at decode time       │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Composition Root — One Object Graph Per Feed

VelocityUI has **no singletons**. Every long-lived collaborator — actors, caches,
pools, controllers — is owned by a single `RenderEnvironment` instance, constructed
once per `AsyncFeed`, and injected into everything that uses it.

```
                       ┌─────────────────────────────────┐
                       │  RenderEnvironment (Sendable)   │
                       │                                 │
                       │  textPool        : TextMeasurementPool
                       │  layoutCache     : LayoutCache
                       │  dimensionCache  : DimensionCache
                       │  imageActor      : ImageActor
                       │  gifActor        : GIFActor
                       │  videoController : VideoController   @MainActor
                       │  videoPreparation: VideoPreparationActor
                       └─────────────────┬───────────────┘
                                         │  init injection
       ┌────────────────────────┬────────┴────────┬─────────────────────┐
       ▼                        ▼                 ▼                     ▼
 RenderPipeline           FeedScrollView      RenderDiffer        Memory-pressure
 (uses textPool,          (uses imageActor,   (uses dimension-    handler (evicts
  layoutCache)            gifActor, video…)   Cache for `.media`  gif + video-prep
                                              classification)    via env)
```

### Why this shape

Singletons would (and did, before this rule) cause:

| Problem | What it costs |
|---|---|
| Two feeds in the same app share one `LayoutCache` | Cross-feed cache pollution; memory budget cannot be tuned per feed |
| Test cannot substitute a fake `ImageActor` | Pipeline tests must hit the real network or mock at module level |
| `AsyncFeed` deinit doesn't tear down decode work | Leaked Tasks holding `CGImage`s, AVPlayers, GIF ring buffers |
| `static let shared` resists Swift 6 concurrency tightening | Module-init order bugs; harder to reason about isolation domains |

### Forbidden patterns (rejected at review)

- `static let shared` on any VelocityUI-owned type
- File-private mutable instances referenced from more than one call site
- `@MainActor` global vars holding live state
- Service-locator wrappers, `@Injected` property wrappers, thread-locals

System-API singletons (`URLSession.shared`, `FileManager.default`,
`NotificationCenter.default`) may be used **only as the default value of an init
parameter**, so tests can substitute one. They are never read inline.

### Default vs custom construction

`AsyncFeed(items:id:content:)` constructs a `RenderEnvironment()` with all-defaults
when no environment is supplied — so app developers don't think about wiring. Power
users override individual collaborators (different decode-queue concurrency, smaller
video budget, fake actors in tests) by passing a configured environment:

```swift
let env = RenderEnvironment(
    imageActor: ImageActor(decodeConcurrency: 5),
    videoController: VideoController(maxAttached: 2)
)
AsyncFeed(items: posts, id: \.id, environment: env) { … }
```

### Pure helpers stay pure

`measureNode`, `classify`, `normaliseAndRound`, `rasterizeText` and the other
`nonisolated` functions on the layout/decode path do not read from a global
cache — they take the pool/cache they need as an argument. This keeps them
testable in isolation and prevents accidental capture of an unrelated
environment's state.

---

## 4. The Contract (non-negotiable invariants)

Three clauses, each mechanically checkable in CI with `os_signpost` and a
frame-drop counter on real hardware:

1. **The scroll path never awaits.** `updateVisibleCells` and `updateVideoPlayback`
   are synchronous. Zero `Task` spawns per frame unless video state actually changes.
   `WorkingRange` lookup is an O(1) array index — no hash, no allocation.
2. **Layout never blocks media.** Measurement runs on the cooperative pool; decode
   runs on dedicated `DispatchQueue`s. They never compete for threads.
3. **Media never starves layout.** Custom executors on all media actors mean decode
   bursts during fast scroll cannot exhaust cooperative-pool threads needed by layout.

Derived rules that must never be violated:

- **No `CATextLayer` anywhere** — it uses its own layout engine, so measured height ≠
  rendered height. All text goes `NSTextLayoutManager` → `CGImage` → plain
  `CALayer.contents`.
- **No `cornerRadius`/`masksToBounds` on any `CALayer`** — that forces an offscreen
  render pass per layer per frame. Rounding is baked in via `CGContext` clip at decode.
- **All images normalised to BGRA8888 premultiplied at decode** — otherwise Core
  Animation does a hidden `copy_image` conversion on the main thread at commit.
- **`NodeTable` crosses layer boundaries** — no existential `any RenderNode` past Layer 1.
- **`WorkingRange` is a ring buffer** — never a `[Int: ResolvedLayout]` dictionary.

---

## 5. End-to-End Data Flow

From a developer's declarative cell to pixels on screen:

```
 Developer writes                 Layer 1 (@MainActor)
 ───────────────────              ─────────────────────
 struct VideoPostCell: RenderView
   var renderBody: some RenderNode {     ┌──────────────┐
     ZStackNode {                  ───▶  │ RenderNode   │
       AsyncVideoNode(url: …)            │ tree         │
       VideoIndicatorNode()              └──────┬───────┘
     }                                          │ flatten() — once, at the boundary
   }                                            ▼
                                         ┌──────────────┐
                                         │  NodeTable   │  flat [NodeKind] array
                                         │  (Sendable)  │  + parentIndices: [Int]
                                         └──────┬───────┘  + layoutHash/appearanceHash
                                                │
 Layer 2 (off-main) ────────────────────────────┤
                                                ▼
   ┌─────────────┐  cache miss  ┌────────────────────────────┐
   │ LayoutCache │◀────────────▶│ measureNode() × N items    │
   │   (actor)   │  cache hit   │ nonisolated pure functions │
   └─────────────┘              │ fanned out via TaskGroup   │
                                └─────────────┬──────────────┘
                                              │ ResolvedLayout
                                              ▼
                                ┌────────────────────────────┐
                                │ WorkingRange (ring buffer) │
                                │ committed on MainActor     │
                                └─────────────┬──────────────┘
 Layer 3 (@MainActor) ────────────────────────┤
                                              │ O(1) lookup, synchronous
                                              ▼
                                ┌────────────────────────────┐
                                │ FeedScrollView             │
                                │  └─ RenderCell (CALayer)   │
                                │     phase 1: geometry      │
                                │     phase 2: media content │
                                └─────────────┬──────────────┘
 Layer 4 ─────────────────────────────────────┤
                                              ▼
                                ┌────────────────────────────┐
                                │ ImageActor / GIFActor /    │
                                │ VideoController            │
                                │ fetch → decode → round →   │
                                │ normalise → CGImage        │
                                └────────────────────────────┘
```

---

## 6. Layer 1 — Developer DSL

SwiftUI-syntax API. A developer writes a `RenderView` with a `renderBody` built by
the `@RenderNodeBuilder` result builder, and mounts it via `AsyncFeed`
(a `UIViewRepresentable`):

```swift
AsyncFeed(items: posts, id: \.id) { post in … }
    .layout(.masonry(columns: 3, spacing: 1))
    .prefetchWindow(ahead: 10, behind: 3)
    .onTap { post, sourceFrame in … }
    .onReachEnd { await loadMore() }
```

Every node carries two hashes:

- `layoutHash` — layout-affecting properties (content, font size, aspect ratio…)
- `appearanceHash` — appearance-only properties (color, corner radius…)

These power the 3-tier change classifier in Layer 2 (subtree skip in O(1)).

### NodeTable: killing the existential

`any RenderNode` existentials mean heap allocation per node, dynamic casts, and
pointer-chasing. A feed rebuild touching hundreds of cells × ~10 nodes = thousands of
existential allocations per update. So the tree is flattened **once**, at the Layer 1/2
boundary:

```
  RenderNode tree (existentials, @MainActor)        NodeTable (flat, Sendable)
  ──────────────────────────────────────────        ──────────────────────────
        ZStackNode                                  nodes:   [.zstack, .video, .custom]
        ┌───┴────────┐              flatten()       parents: [  -1,       0,      0   ]
  AsyncVideoNode  IndicatorNode      ─────▶         layoutHash:     0xA3F…
                                                    appearanceHash: 0x7B2…
```

`NodeKind` is a flat enum — `switch` is O(1) with no witness table. Tree structure is
expressed via index (`parentIndices`), not pointers. Layers 2–4 never see an existential.

---

## 7. Layer 2 — Render Pipeline

### Layout as pure functions (no LayoutActor)

`measureNode()` is a `nonisolated` pure function taking a `NodeTable`. It runs on the
cooperative pool, fully parallel via `TaskGroup`. The **only** actor in the layout path
is `LayoutCache`, because it's the only shared mutable state — keyed by
`(layoutHash, width)`.

### Text: the Swift 6 asterisk

`NSTextLayoutManager`, `UIFont`, `NSAttributedString` are not `Sendable`. The answer is
a **pool of single-owner contexts**, bounded to core count:

```
 TaskGroup tasks                TextMeasurementPool
 ┌────────┐                     ┌────────────────────────────┐
 │ task A │── await wait() ───▶ │ AsyncSemaphore(cores)      │
 │ task B │                     │ pool: [ctx][ctx][ctx][ctx] │
 │ task C │◀── ctx checked out ─│  └─ each ctx: TextKit 2    │
 └────────┘    used, returned   │     stack, single owner    │
                                └────────────────────────────┘
```

`TextMeasurementContext` is `@unchecked Sendable` — safe by construction (one owner per
checkout, never escapes the `withContext` block), not by compiler proof. Pooling matters:
object creation dominates short-string measurement cost.

Two text render modes, chosen explicitly at library init — both go through
`NSTextLayoutManager` (never `CATextLayer`):

| Mode | How | Trade-off | Use for |
|---|---|---|---|
| `asyncBitmap` | Rasterize to `CGImage` off-main → `CALayer.contents` | +memory (~4 B/px), zero main-thread draw | media-heavy feeds |
| `synchronousDraw` | Measure off-main, draw on main at commit | −memory, +main-thread commit cost | text-heavy feeds |

### WorkingRange: the ring buffer

At 120 Hz the frame budget is 8.3 ms. A `[Int: ResolvedLayout]` dictionary hashes on
every lookup and its eviction (`filter`) reallocates the whole dictionary on MainActor
mid-scroll — which is why it was banned. The replacement is a fixed-capacity contiguous
ring buffer (default 60 slots ≈ 3 screens):

```
 item index space:  …  41  42  43  44  45  46  47  48  …
                         │   │   │   │   │   │   │
 buffer (capacity 60):  [ L ][ L ][ L ][ L ][ L ][nil]…
                          ▲
                          rangeStart = 42

 layout(at: 45)  →  buffer[45 - 42]          O(1), no hash, no allocation
 commit(L, at:)  →  buffer[i - rangeStart]   O(1)
 advance(to: 44) →  shift left by 2, nil the tail   (window slides with scroll)
```

The pipeline is notified **only when the leading visible index crosses an item
boundary** — not per frame — preventing a Task spawn at 120 Hz.

### Diffing: 3-tier classifier + allocation-free differ

When items change, each `(prev, next)` NodeTable pair is classified:

```
 classify(prev, next)
        │
        ├─ hashes equal ───────────────▶ .none        (skip entirely)
        ├─ color-only change ──────────▶ .appearance  (cheap layer update)
        ├─ image URL change w/ known
        │  dimensions ─────────────────▶ .media       (re-fetch, no re-layout)
        └─ content/size/font change ───▶ .layout      (full re-measure)
```

`RenderDiffer` reuses scratch arrays (`removeAll(keepingCapacity: true)`) so steady-state
diffs allocate nothing.

---

## 8. Layer 3 — Scroll Container

`FeedScrollView` is a `@MainActor` `UIScrollView` subclass with a fully custom cell
lifecycle — **no UICollectionView** (cost acknowledged: VoiceOver scroll semantics, RTL,
insert/delete animations are deferred to v2; a UIView interaction overlay provides taps
+ accessibility basics for v1).

### The synchronous scroll path

```
 layoutSubviews()                          every frame, all synchronous
 ├── updateVisibleCells()
 │     ├─ binary-search visible index range over resolvedFrames
 │     ├─ recycle cells outside the prefetch window
 │     ├─ for each newly visible index:
 │     │    workingRange.layout(at: i)   ── O(1) ring-buffer read
 │     │    hit  → dequeue cell, applyLayout (geometry), add sublayer
 │     │    miss → placeholder (should not happen after warmup)
 │     └─ sync frames to interaction overlay
 ├── updateVideoPlayback()
 │     ├─ compute desired play/pause per visible cell (visibility threshold)
 │     ├─ diff against current state — usually empty → return, 0 Tasks
 │     └─ changed → ONE batched Task (or pauseAll + cancel decodes if flinging)
 └── notifyPipelineIfNeeded()
       └─ only when leading index crossed an item boundary → 1 Task
```

### RenderCell: two-phase commit

```
 Phase 1 — geometry (synchronous, on scroll path)
 ┌──────────────────────────────┐
 │ RenderCell.layer             │   frames set inside a CATransaction
 │ ├─ placeholderLayer (grad.)  │   with actions disabled; zero
 │ └─ contentLayer              │   computation, zero content
 │    ├─ sublayer (text)   ▢    │
 │    ├─ sublayer (image)  ▢    │   NO CATextLayer
 │    └─ sublayer (video)  ▢    │   NO cornerRadius / masksToBounds
 └──────────────────────────────┘
                 │
                 ▼  media arrives async (already decoded/rounded/normalised)
 Phase 2 — content
   sublayer.contents = cgImage      a pointer swap + 0.2 s fade —
   placeholder fades out when       no main-thread image work at all
   all media layers are filled
```

### Recycle semantics

| Scenario | Behavior | Why |
|---|---|---|
| Cross-item recycle | **Hard cut** to placeholder | Stale content from a different item is a UX *and privacy* bug |
| Same-item recycle | **Stale-until-replaced** | Content stays up; a minor update is incoming |

---

## 9. Layer 4 — Media Pipeline

### Threading model

```
                cooperative pool              dedicated DispatchQueues
                (layout's territory)          (decode's territory)
 ┌──────────┐   ┌───────────────────┐   ┌────────────────────────────────┐
 │ network  │   │ URLSession await  │   │ velocityui.image.decode        │
 │ fetch    │──▶│ (I/O suspends —   │──▶│ concurrent, semaphore(3)       │
 │          │   │ holds no thread)  │   │ velocityui.gif.decode          │
 └──────────┘   └───────────────────┘   │ concurrent, semaphore(2)       │
                                        └────────────────────────────────┘
```

Network and decode are deliberately separated: a serial pipeline processing
"200 ms network + 5 ms decode" jobs has 2.5 % CPU utilisation, and visible-priority
decodes would queue behind stalled network waits. Media actors use custom
`DispatchQueue`-backed executors so decode bursts can never starve the cooperative
pool (contract clause 3).

### Decode-time processing — one blit does everything

```
 raw CGImage from ImageIO
        │
        ▼  normaliseAndRound()  — on the decode queue, once per image
 ┌────────────────────────────────────┐
 │ CGContext (BGRA8888 premultiplied) │
 │   cornerRadius > 0 → path + clip   │      Per-frame GPU cost moved to
 │   draw(image)                      │ ───▶ once-per-decode CPU cost.
 │   makeImage()                      │      Verify in Instruments:
 └────────────────────────────────────┘      • no "Offscreen-Rendered Yellow"
        │                                    • no "Copied Images"
        ▼
 cached CGImage → CALayer.contents (zero conversion at commit)
```

### Dimension-first fetch

Layout often needs image dimensions before pixels. A ranged HTTP request
(`Range: bytes=0-1023`) grabs just the header — JPEG SOF and PNG IHDR both live in the
first KB — and `DimensionCache` stores the result (full decodes also cache dimensions
as a side effect).

### Per-media-type ownership

```
 ┌───────────────────────────────┐  ┌───────────────────────────────────┐
 │ ImageActor (actor)            │  │ VideoController (@MainActor)      │
 │  custom serial executor       │  │  owns AVPlayers + AVPlayerLayers  │
 │  NSCache memory cache         │  │  HARD BUDGET: 3 attached players  │
 │  fetch → decode → blit        │  │  evicts least-visible on overflow │
 ├───────────────────────────────┤  ├───────────────────────────────────┤
 │ GIFActor (actor)              │  │ VideoPreparationActor (actor)     │
 │  CGImage ring buffer +        │  │  pre-loads AVPlayerItems off-main │
 │  CADisplayLink (v1; Metal v2) │  │  HARD BUDGET: 8 prepared items    │
 │  4/8/16 resident frames by    │  │  (background-safe — never touches │
 │  device RAM                   │  │   players or layers)              │
 └───────────────────────────────┘  └───────────────────────────────────┘
```

GIF playback keeps only a sliding window of frames resident (all-frames-resident is
190 MB+ for a dense GIF). Memory warnings evict GIF frames and prepared video items;
`NSCache` handles image eviction automatically.

---

## 10. Build Order & Current Status

Build **vertically**: each phase exercises every layer boundary with minimal media
complexity, instead of finishing one layer at a time.

```
 Spikes ✅ ──▶ Phase 1 ⏳ ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4 ──▶ Phase 5 ──▶ Phase 6
 validation    image-only     text        GIF         video       masonry     hardening
               vertical feed  parity                                          (signposts,
                                                                              CI, a11y v2)
```

### Done (beads closed)

| Bead | What it proved |
|---|---|
| Spike 0 | Package.swift + Swift 6 strict-concurrency scaffold |
| Spike 1 | Pure-function layout + pooled `TextMeasurementContext` — race-free, pool beats per-call |
| Spike 2 | Ring buffer O(1) + zero nil lookups after warmup, zero scroll-path allocations |
| Spike 3 | CALayer scroll @120 fps — zero offscreen renders, zero copied images |
| Spike 4 | TextKit 2 measure = render within 1 pt (emoji, RTL, multi-line) |
| Layer 1 DSL | Node catalog + `@RenderNodeBuilder` result builder |

### Phase 1 epic (open) — image-only vertical feed

The dependency-ordered work, tracked in beads (`bd ready` for current state):

```
                       ┌─ flatten(): tree → NodeTable        (b52)
   DSL boundary ───────┤
                       └─ Render fragments in ResolvedLayout (8gz)
                                  │
   Pipeline ────────── RenderPipeline v2 + LayoutCache       (aew, c71)
                                  │
   Container ───────── FeedScrollView + RenderCell v2        (23u, 0kr)
                       Vertical layout provider              (hl2)
                                  │
   Media ───────────── ImageActor + two-phase commit wiring  (0c5, vim)
                       DimensionCache + ranged HTTP          (9t9)
                                  │
   Integration ─────── differ/classifier (9ip) · AsyncFeed (4kp)
                       InteractionOverlay (b6u) · DeviceTestHost (vto)
                                  │
   Sign-off ────────── pipeline integration tests (a5k)
                       on-device perf acceptance             (hbe)
```

### What exists in `Sources/` today

```
Sources/VelocityUI/
├── DSL/              RenderNode, RenderNodeBuilder, Nodes, NodeTable
├── Pipeline/         LayoutEngine, ResolvedLayout, WorkingRange, RenderPipeline,
│                     TextMeasurementPool/Context, TextRasteriser, ImageNormaliser
├── ScrollContainer/  RenderCell
└── Media/            ImageActor
```

---

## 11. Key Decisions Quick Reference

| Decision | Choice | One-line why |
|---|---|---|
| iOS minimum | 16.0 | TextKit 2 |
| Concurrency | Swift 6 strict | Compile-time safety (asterisk: pooled `@unchecked Sendable` TextKit contexts) |
| UICollectionView | ❌ | Fights the architecture; costs accepted for v1 |
| UIView per cell | ❌ | No UIKit layout pass; GPU compositing; main thread idle |
| Layout primitive | `nonisolated` pure fns + TaskGroup | Parallel by default, no actor serialization |
| Node representation (L2+) | `NodeTable` flat enum | No existential boxing, O(1) switch |
| `CATextLayer` | ❌ everywhere | Different layout engine — heights won't match measurement |
| `cornerRadius` on layers | ❌ | Offscreen render pass per layer per frame |
| Corner rounding | `CGContext` clip at decode | One off-main CPU blit, zero GPU cost |
| Image format | BGRA8888 premul at decode | Zero CA `copy_image` on main at commit |
| WorkingRange | Contiguous ring buffer | Dictionary lookup/evict = hash + allocation on the scroll path |
| Pipeline notification | Index boundary only | No Task-per-frame at 120 Hz |
| Video budget | 3 attached / 8 prepared | Hardware decode pipeline cap |
| GIF v1 | CGImage ring buffer + CADisplayLink | FLAnimatedImage-proven; Metal only with profiling data |
| Singletons | ❌ none on owned types | One `RenderEnvironment` per feed; per-feed lifetime + test substitution |
| Wiring | Constructor injection through `RenderEnvironment` | Explicit dependency graph; no service locator, no property wrappers |
| Distribution | SwiftPM only | — |

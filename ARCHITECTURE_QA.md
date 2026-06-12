# VelocityUI — Architecture Deep Dive & Q&A

Companion to `ARCHITECTURE.md`. This document explains the design in depth through
anticipated questions — the kind a reviewer, new contributor, or QA engineer would ask.
Each answer includes the *why*, the failure mode being avoided, and (where applicable)
how to verify the claim with tools.

Source of truth remains `velocityui-prompt.md`.

---

## Table of Contents

1. [Fundamentals](#1-fundamentals)
2. [Layer 1 — DSL & NodeTable](#2-layer-1--dsl--nodetable)
3. [Layer 2 — Layout & Render Pipeline](#3-layer-2--layout--render-pipeline)
4. [Layer 3 — Scroll Container](#4-layer-3--scroll-container)
5. [Layer 4 — Media Pipeline](#5-layer-4--media-pipeline)
6. [Concurrency Model](#6-concurrency-model)
7. [Performance Verification & QA Checklist](#7-performance-verification--qa-checklist)
8. [Adversarial Questions](#8-adversarial-questions)
9. [Glossary](#9-glossary)

---

## 1. Fundamentals

### Q: In one paragraph, what is VelocityUI?

A Swift 6 package for high-performance scrolling feeds/grids of mixed media (images,
GIFs, video, text) on iOS. Developers write SwiftUI-syntax declarative cells; the
engine flattens them to value types, measures layout off-main in parallel, and renders
directly to `CALayer`s — no UICollectionView, no UIView per cell, no SwiftUI render
pipeline in the hot path. The defining property: **the scroll path is 100% synchronous**
— zero awaits, zero Task spawns, zero allocations per frame.

### Q: Why does the scroll path have to be synchronous? Isn't async "free" in Swift?

Async is not free on a frame deadline. At 120 Hz you have **8.3 ms** per frame. An
`await` is a suspension point: the continuation is scheduled on an executor and resumes
*at some later point* — possibly after the frame deadline. Even an "instant" actor hop
costs an enqueue/dequeue. If `updateVisibleCells` awaited anything — a layout, a cache,
an actor — cell placement would lag scrolling by an unpredictable number of frames,
visible as blank cells or rubber-banding content.

So the design inverts the dependency: all async work (layout, decode, fetch) happens
*ahead of time*, driven by a prefetch window, and deposits results into a structure
(`WorkingRange`) that the scroll path can read synchronously in O(1).

```
   WRONG (async on scroll path)          RIGHT (async ahead of scroll)
   ──────────────────────────            ────────────────────────────
   scroll frame                          (earlier) prefetch task:
     └─ await layout(i)  ← may              measure → commit to ring buffer
        resume after the
        8.3 ms deadline                  scroll frame:
                                            └─ ringBuffer[i - start]  ← ~ns
```

### Q: What are the three contract clauses, and why those three?

1. **The scroll path never awaits** — protects the frame deadline (above).
2. **Layout never blocks media** — layout runs on the cooperative pool; decode runs on
   dedicated `DispatchQueue`s. If they shared threads, a burst of decodes could delay
   layout, and the ring buffer would fall behind the scroll position → blank cells.
3. **Media never starves layout** — the converse. Media actors use custom
   `DispatchQueue`-backed executors so they physically cannot occupy cooperative-pool
   threads.

They're the three edges of the triangle scroll ↔ layout ↔ media. Cut any edge and one
subsystem can degrade another invisibly. All three are mechanically checkable in CI
(signposts + frame-drop counter), which is the point — a contract you can't test is a
hope, not a contract.

### Q: Why not just use SwiftUI's `List`/`LazyVGrid`?

All SwiftUI `body` evaluation, layout, and text sizing happen on `@MainActor`. For a
text-light feed that's fine. For a heterogeneous media feed (mixed video/GIF/image
cells, masonry, 120 Hz), main-thread layout cost scales with cell complexity and you
cannot move it off-main — the API gives you no seam to do so. VelocityUI's entire
Layer 2 exists to be that seam.

### Q: Why not UICollectionView with a custom layout?

You'd keep the prefetch API and accessibility for free, but you'd inherit:

- UIView-per-cell — full UIKit layout pass (`layoutSubviews` cascade) per cell per reuse.
- Cell sizing callbacks that the framework may call on the main thread at awkward times.
- An internal invalidation model that fights externally-computed, already-resolved frames.

VelocityUI already computes every frame off-main; at commit time it only needs to set
`layer.frame` and `layer.contents`. A UIView hierarchy adds cost without adding value.
**Acknowledged costs:** VoiceOver scroll semantics, focus/keyboard nav, RTL, drag-drop,
insert/delete animations. v1 covers tap + accessibility basics via a transparent UIView
overlay; the rest is scheduled v2 work, not denied.

---

## 2. Layer 1 — DSL & NodeTable

### Q: Walk me through what happens when a developer's `renderBody` is evaluated.

1. `AsyncFeed` (a `UIViewRepresentable`) hands items to `FeedScrollView`.
2. For each item, the `cellBuilder` closure runs **on MainActor**, producing a
   `RenderNode` tree via the `@RenderNodeBuilder` result builder. This tree contains
   existentials (`children: [any RenderNode]`) — acceptable here because it's built
   once per item change, not per frame.
3. `flatten()` converts the tree into a `NodeTable` — a flat `[NodeKind]` array plus a
   `parentIndices: [Int]` array — at the Layer 1/2 boundary.
4. Everything below Layer 1 sees only `NodeTable`. The existential tree is dead after
   flattening.

### Q: Why is `any RenderNode` banned past Layer 1? Be specific about the cost.

Three concrete costs of existentials in a hot loop:

1. **Heap allocation** — an existential box larger than 3 words heap-allocates. A feed
   update touching 300 cells × ~10 nodes = ~3,000 allocations *per data refresh*.
2. **Dynamic dispatch / casts** — `measureNode` on an existential needs protocol
   witness-table dispatch or `as?` casts per node.
3. **Pointer-chasing** — tree-of-boxes traversal defeats the prefetcher; each child
   visit is a dependent load.

`NodeTable` fixes all three: `NodeKind` is a flat enum (switch compiles to a jump
table, no witness table), nodes live contiguously in one array, and tree structure is
an integer index (`parentIndices`), not a pointer.

### Q: What are `layoutHash` and `appearanceHash`, and why two hashes instead of one?

Every node hashes its properties into two buckets:

- `layoutHash` — properties that affect *geometry*: text content, font size/weight,
  line limit, aspect ratio, content mode, children's layout hashes.
- `appearanceHash` — properties that affect only *pixels within existing geometry*:
  text color, corner radius.

Two hashes let the differ answer "do I need to re-measure?" separately from "do I need
to redraw?". A color change re-rasterizes one layer's contents; it must not trigger a
TaskGroup re-measurement of the cell. With a single combined hash, every appearance
tweak would look like a layout change. The root `NodeTable.layoutHash` also enables
**O(1) subtree skip**: equal root hashes → the entire cell is unchanged, no per-node walk.

### Q: What's `HostingNode` and why does it require a declared size?

The escape hatch: `HostingNode(size:) { MKMapView() }` embeds an arbitrary UIView (or
SwiftUI view). The size is **declared, not measured**, because measuring a UIView
requires the main thread and the view to exist — both of which would poison the
off-main, pure-function layout path. Declaring the size keeps `measureNode` pure: the
hosting node contributes a constant. The trade: the developer must know the size up
front. That's deliberate — "no runtime measurement surprise" is a feature.

### Q: When exactly does `flatten()` run, and is it a per-frame cost?

No. It runs **once per item content change**, on MainActor, at the DSL boundary
(when `items` is set / when the differ identifies a changed item). Scrolling never
re-flattens. The per-frame path consumes only `ResolvedLayout` from the ring buffer.

---

## 3. Layer 2 — Layout & Render Pipeline

### Q: Why pure functions + TaskGroup instead of a `LayoutActor`?

An actor serializes. A `LayoutActor.measure()` would process one cell at a time —
turning an embarrassingly parallel problem (cells are independent) into a queue.
`measureNode` is `nonisolated` and pure (same inputs → same output, no shared state),
so a `TaskGroup` can fan out N measurements across all cores with zero coordination.

The **only** actor in the layout path is `LayoutCache`, because the cache is the only
shared mutable state. Rule of thumb the codebase follows: *isolate state, not work.*

### Q: But `measureNode` calls into `LayoutCache` — doesn't that serialize anyway?

No — the cache check/store happens in the TaskGroup task *around* the pure call, not
inside it. The actor hop is two short critical sections (get, set) per cell; the
expensive part (text measurement, tree walk) runs fully parallel between them. If the
cache hit-rate is high, most tasks do one actor hop and return.

### Q: Explain the "Swift 6 asterisk" — the `@unchecked Sendable` on text measurement.

TextKit 2 types (`NSTextLayoutManager`, `NSTextContainer`, `NSTextContentStorage`) and
`NSAttributedString`/`UIFont` are not `Sendable` — Apple hasn't audited them for
cross-thread use. We need them on background threads to measure off-main. Options:

| Option | Verdict |
|---|---|
| Measure on MainActor | Defeats the whole architecture |
| New context per measurement | Safe, but object creation dominates short-string cost (benchmarked in Spike 1) |
| One shared context behind an actor | Serializes all text measurement |
| **Pool of contexts, one owner at a time** | **Chosen** — parallel up to core count, alloc cost amortized |

`TextMeasurementContext` is `@unchecked Sendable` with a *machine-checkable usage
pattern*: a context is only reachable inside `pool.withContext { ctx in … }` —
checkout guarded by an `AsyncSemaphore`, returned in a `defer`. Single ownership is
guaranteed by construction (Spike 1 validated no reference escapes a task's lifetime
under TSan), not by the compiler. That's exactly what `@unchecked` is for; the asterisk
is documented rather than hidden.

### Q: Why is `CATextLayer` banned? It renders text on the GPU, isn't that good?

`CATextLayer` uses **its own layout engine**, not TextKit 2. Its line breaking,
truncation, and metrics differ subtly from `NSTextLayoutManager`. We *measure* with
TextKit 2 off-main; if we then *rendered* with CATextLayer, measured height ≠ rendered
height — text clipped mid-line or cells with stray padding, data-dependent and
device-dependent. The invariant is: **the engine that measures is the engine that
draws.** Both render modes (`asyncBitmap`, `synchronousDraw`) go through
`NSTextLayoutManager`; Spike 4 asserts measure/render parity within 1 pt across
multi-line, emoji, RTL, and zero-width-joiner content.

### Q: When do I pick `asyncBitmap` vs `synchronousDraw`?

Decided once at library init, not per cell:

- **`asyncBitmap`** — rasterize text to `CGImage` on the decode queue → assign to
  `CALayer.contents`. Commit cost on main ≈ a pointer swap. Memory cost ≈ 4 bytes/pixel
  per rendered text region. Right when text is the *minority* (media feeds): few text
  cells, so the memory is bounded and main-thread time matters most.
- **`synchronousDraw`** — measure off-main, draw with `NSTextLayoutManager` on main at
  phase-1 commit. Lower memory, but adds main-thread draw cost per newly visible text
  cell. Right when text is the *majority* (Twitter/Mastodon-style feeds), where
  bitmap-per-cell memory would balloon.

### Q: The ring buffer — why exactly was `[Int: ResolvedLayout]` rejected? It's also O(1).

Dictionary "O(1)" hides three violations of the scroll contract:

1. **Hashing per lookup** — `Int` hashing is cheap but not free, and it runs on every
   visible-cell check, every frame.
2. **Eviction allocated** — the old implementation evicted with
   `layouts.filter { … }`, which *rebuilds the entire dictionary* — an O(n) allocation
   on MainActor, mid-scroll. This is the precise anti-pattern the contract bans.
3. **Unbounded growth between evictions** — a dictionary doesn't naturally encode "a
   contiguous window of items"; the ring buffer's shape *is* the invariant.

Ring buffer behavior:

```
 layout(at: i)   → buffer[i - rangeStart]      one subtraction, one bounds check
 commit(l, at:i) → buffer[i - rangeStart] = l  same
 advance(to: s)  → shift window forward; vacated slots nil'd; no allocation
                   (full reset only if the jump exceeds capacity, e.g. scrollToTop)
```

Capacity 60 ≈ 3 screens at ~20 items/screen. A lookup outside the window returns `nil`
→ the scroll path shows a placeholder and the pipeline backfills. Spike 2's pass
criterion: zero nil lookups after 0.5 s warmup at 120 fps over 200 items.

### Q: What does "pipeline notified on index boundary only" mean and why does it matter?

The naive design notifies the layout pipeline of every scroll offset change — that's a
`Task` spawn per frame, 120 Tasks/second, each hopping to an actor. Instead,
`FeedScrollView` tracks the **leading visible item index**; only when it changes
(content scrolled by at least one item) does it spawn one Task to
`pipeline.onIndexBoundary(...)`. The pipeline then:

1. Cancels the previous prefetch task (scroll direction may have changed).
2. Computes which indices in the new working range lack layouts.
3. Measures them in a TaskGroup.
4. Hops to MainActor once, advances the ring buffer window, commits all results.

Cancellation checks (`Task.isCancelled`) bracket every stage, so a fast fling doesn't
stack up stale prefetch work.

### Q: Explain the 3-tier change classifier with concrete examples.

`classify(prev, next)` maps a NodeTable pair to the *cheapest sufficient* reaction:

| Change | Class | Reaction |
|---|---|---|
| Nothing (hashes equal) | `.none` | Skip cell entirely |
| Text color `gray → red` | `.appearance` | Re-rasterize one layer's contents; no measurement |
| Image URL changed, new image's dimensions already in `DimensionCache` | `.media` | Re-fetch/decode; geometry already known, **no re-layout** |
| Image URL changed, dimensions unknown | `.layout` | Must re-measure (height depends on aspect ratio) |
| Text content edited | `.layout` | Height may change |
| Font size changed | `.layout` | Height changes |
| Video URL changed | `.media` | Player swap; video frames are typically fixed-aspect |

The interesting case is the URL change: whether it's `.media` or `.layout` depends on
**runtime cache state**, not on the node type. That's why classification can't be a
static property of the diff — it consults `DimensionCache`.

### Q: How is the differ "allocation-free"? Diffing produces output.

`RenderDiffer` keeps five scratch arrays as instance state and clears them with
`removeAll(keepingCapacity: true)` — capacity survives, so steady-state diffs write
into already-allocated storage. The returned `ChangeSet` borrows these arrays. The cost
is that the differ isn't reentrant and a `ChangeSet` is invalidated by the next `diff()`
call — acceptable because diffing is single-flighted per feed.

---

## 4. Layer 3 — Scroll Container

### Q: Trace one frame during scrolling. What exactly runs?

`layoutSubviews()` fires (UIScrollView calls it when `contentOffset` changes):

```
1. updateVisibleCells()                                 [synchronous]
   a. visibleIndexRange(): two binary searches (partitioningIndex)
      over resolvedFrames — O(log n), no allocation
   b. recycle pass: cells outside the prefetch window →
      prepareForReuse → back to pool
   c. mount pass: for each visible index without a cell:
        workingRange.layout(at: i)
          hit  → dequeue from pool, applyLayout (geometry only,
                 CATransaction with actions disabled), addSublayer
          miss → placeholder gradient (pipeline will backfill)
   d. sync visible frames into the interaction overlay (tap +
      accessibility frames updated in the SAME MainActor pass —
      never stale relative to what's on screen)

2. updateVideoPlayback()                                [synchronous]
   a. read pan velocity; |v| > 800 → "flinging"
   b. compute desired play/pause per visible video cell from
      visible-fraction vs autoplay threshold
   c. diff vs current state → usually empty → RETURN (0 Tasks)
   d. if changed: ONE batched Task (or pauseAll + cancel offscreen
      decodes when flinging)

3. notifyPipelineIfNeeded()                             [synchronous]
   leading index unchanged → RETURN (the common case)
   changed → one Task to pipeline.onIndexBoundary(...)
```

Steady-state scrolling within one item: **zero Tasks, zero allocations, zero awaits.**

### Q: What is the two-phase commit and why are geometry and media split?

- **Phase 1 (geometry)** — synchronous, on the scroll path. `applyLayout` sets sublayer
  frames inside a `CATransaction` with actions disabled. No contents, no computation —
  placeholder gradient shows. The user sees correctly-positioned skeletons instantly.
- **Phase 2 (content)** — asynchronous, whenever media lands. `applyContent` assigns an
  already-decoded/rounded/normalised `CGImage` to `sublayer.contents` with a 0.2 s fade.
  This is a pointer swap; CA uploads the texture off the main thread.

Splitting means scroll speed is **never** coupled to media latency. Slow network →
skeletons persist longer, but scrolling stays at 120 fps. The placeholder fades only
when *all* media layers in the cell are filled (avoids a popcorn effect within a cell).

### Q: Explain the two recycle modes. Why is cross-item different from same-item?

- **Cross-item recycle** (cell reused for a *different* item): **hard cut** — all
  sublayer contents nil'd, placeholder restored to opaque, in one transaction with
  actions disabled. Showing item A's photo in item B's frame, even for 100 ms, is both
  a UX bug and a **privacy bug** (think: a direct-message avatar flashing inside a
  stranger's post).
- **Same-item recycle** (same item, minor update incoming — e.g. like-count changed):
  **stale-until-replaced** — existing content stays visible and is swapped when the
  update lands. Blanking to placeholder here would cause a visible flicker for what is
  a one-frame data refresh.

Both modes cancel in-flight `MediaHandle`s first, so a recycled cell can never receive
a late callback for its previous occupant.

### Q: How does video autoplay decide what plays, and why the fling special-case?

Each frame, the visible fraction of every video cell is compared against its declared
threshold (e.g. `.onVisible(threshold: 0.6)` → play when ≥60% visible). The result is
diffed against current playback state; only deltas dispatch work.

When the pan velocity exceeds 800 pt/s (**flinging**), all videos pause and
below-visible image/GIF decodes are cancelled. Rationale: during a fast fling the user
can't watch a video anyway, and the hardware decoders + decode queues are better spent
preparing where the scroll will *land*. The fling branch is one batched Task, not
per-cell Tasks.

### Q: How do taps and accessibility work without UIViews per cell?

A single transparent `InteractionOverlay` UIView sits above the layer tree. It holds:

- a **frame map** (item index → resolved frame) for hit-testing taps → `onTap(item,
  sourceFrame)` (the frame enables hero transitions),
- **`UIAccessibilityElement`s** mirroring visible cells, updated in the same
  MainActor pass as cell mounting so VoiceOver frames are never stale.

v1 limitation (accepted): element-level a11y works; full VoiceOver *scroll semantics*
(scroll-to-item, page announcements) are v2.

---

## 5. Layer 4 — Media Pipeline

### Q: Why are network fetch and decode separated? Walk through the math.

The wrong design: an actor whose serial executor *is* the decode queue awaits
`URLSession` inside the queue. Then a job that is 200 ms network + 5 ms decode holds a
pipeline slot for 205 ms doing 5 ms of work — **2.5% CPU utilisation** — while
visible-priority decodes queue behind a network stall.

The right design:

```
network:  plain `await URLSession.shared.data(from:)` — I/O-bound; the task
          SUSPENDS and holds no thread. The cooperative pool is fine for this.
decode:   explicit dispatch to a bounded concurrent queue via
          withCheckedContinuation — CPU-bound; gets dedicated threads,
          bounded by a semaphore (images: 3, GIFs: 2).
```

Each resource is matched to its scheduler: latency to suspension points, CPU to
dedicated queues.

### Q: Why is corner rounding done at decode time instead of `layer.cornerRadius`?

`cornerRadius + masksToBounds` forces an **offscreen render pass per layer per frame**:
the compositor renders the layer to an intermediate buffer, clips, then composites. A
3-column grid = ≥3 offscreen passes *per frame*, forever, on the GPU.

Decode-time rounding (`CGContext` `addPath` + `clip` + `draw`) costs one CPU blit
**once per image**, on the decode queue where there's budget. The rounded alpha is
baked into the bitmap; render time costs zero.

**Verify:** Instruments → Core Animation → "Color Offscreen-Rendered Yellow". With
layer-based rounding every image flashes yellow; with decode-time rounding, nothing
does. This is Spike 3's pass criterion. (Texture, Nuke, and Pinterest's
AsyncDisplayKit-era pipeline all do exactly this.)

### Q: What is BGRA8888 normalisation and what breaks without it?

`CGImageSourceCreateThumbnailAtIndex` returns whatever pixel format the codec produced
— possibly RGB without alpha, non-premultiplied, or a mismatched color space. Core
Animation's preferred format is **BGRA8888, premultiplied alpha, display color space**.
Any mismatch → CA converts the image **at commit time, on the main thread** — a hidden
copy that silently negates async decode.

Fix: one normalising blit on the decode queue (combined with rounding — same
`CGContext`, the clip is simply skipped when `radius == 0`).

**Verify:** Instruments → "Color Copied Images" (mismatched images flash blue) and
look for `CA::Render::copy_image` in Time Profiler. Both must be absent — Spike 3.

### Q: How does dimension-first fetching work, and why bytes 0–1023?

Layout needs an image's aspect ratio before its pixels. Instead of downloading the
full image, `dimensions(for:)` sends a ranged request (`Range: bytes=0-1023`):

- PNG `IHDR` (width/height) is always within the first **33 bytes**.
- JPEG `SOF` is usually within ~512 bytes; 1 KB covers files with moderate EXIF.

`CGImageSourceCopyPropertiesAtIndex` parses dimensions from the partial data. Results
go to `DimensionCache`. Fallbacks: servers ignoring `Range` just return the full body
(still works, just less efficient); unparseable headers → full decode later caches
dimensions as a side effect. The cache also feeds the change classifier (URL change
with known dimensions = `.media`, not `.layout`).

### Q: Explain the GIF ring buffer. Why not decode all frames? Why not Metal?

**All frames resident** is a memory bomb: a dense 500-frame GIF at feed width ≈
190 MB+. **Decode-per-frame** with no buffer risks stutters when a frame's decode
overruns the display interval.

The middle path (proven by FLAnimatedImage): keep a sliding window of decoded frames
(`residentFrames`), sized by device RAM — **4 / 8 / 16 frames** for <2 GB / <4 GB /
≥4 GB devices. A `CADisplayLink` advances playback: show current frame (assign to
`CALayer.contents`), evict the frame just shown, decode one frame ~half a window ahead.

**Metal** (MTLTexture ring + `CAMetalLayer`, zero per-frame blit) is deferred to v2
*by policy*: it's only justified if profiling the CGImage path shows render-server
blit cost as a measured constraint. Building it speculatively is complexity without
evidence.

### Q: Why is video split into `VideoController` (@MainActor) and `VideoPreparationActor`?

Because the types force it, and the split is also the right shape:

- `AVPlayer` + `AVPlayerLayer` are UI-adjacent, non-Sendable, and must be managed
  where the layer tree lives → `VideoController` is `@MainActor`. It owns the player
  pool, attachment lifecycle, and play/pause.
- `AVPlayerItem` *preparation* (`asset.load(.isPlayable)` — network + parsing) is slow
  and main-thread-hostile → `VideoPreparationActor` runs it off-main and hands over a
  ready item at attach time.

No non-Sendable type crosses the boundary: the controller *asks* the actor for an item
(`await prepare/item(for:)`); players and layers never leave MainActor.

### Q: Why budgets of exactly 3 attached / 8 prepared?

- **3 attached**: iPhone hardware video decode supports a small number of simultaneous
  sessions; beyond it, sessions silently fall back to software decode (CPU + battery
  + dropped frames). 3 is the safe portable cap. On overflow, the *least visible*
  player is detached (visibility scores updated each frame by the scroll container).
- **8 prepared**: an `AVPlayerItem` holds buffers and a network connection. 8 covers
  the prefetch window ahead of scroll without hoarding memory. Prepared ≠ attached:
  preparation is cheap-ish and off-main; attachment burns a hardware session.

### Q: What happens under memory pressure?

On `didReceiveMemoryWarning`:

| Cache | Action |
|---|---|
| GIF resident frames | `GIFActor.evictAll()` — drop to current frame only per player |
| Prepared video items | `VideoPreparationActor.evictAll()` |
| Decoded images | Nothing explicit — `NSCache` already responds to pressure |
| LayoutCache / WorkingRange | Untouched — layouts are small and expensive to recompute; evicting them would cause visible blank-cell churn right when the system is struggling |

---

## 6. Concurrency Model

### Q: Map every component to its isolation domain.

| Component | Isolation | Why |
|---|---|---|
| DSL evaluation, `flatten()` | `@MainActor` | Touches developer closures; runs once per data change |
| `measureNode`, `classify`, `normaliseAndRound`, `rasterizeText` | `nonisolated` pure functions | No shared state → no isolation needed → fully parallel |
| `LayoutCache` | `actor` (cooperative pool) | Only shared mutable state in the layout path |
| `RenderPipeline` | `actor` | Owns prefetch task lifecycle, last-index state |
| `WorkingRange` | `@MainActor` class | Read synchronously by the scroll path — an actor would force `await` |
| `FeedScrollView`, `RenderCell`, `InteractionOverlay`, `VideoController` | `@MainActor` | UIKit/CA territory |
| `ImageActor`, `GIFActor` | `actor` with **custom DispatchQueue executor** | Must not occupy cooperative-pool threads (contract clause 3) |
| `VideoPreparationActor` | `actor` (cooperative pool) | Preparation is await-heavy, not CPU-heavy |
| `TextMeasurementContext` | `@unchecked Sendable`, pooled single-owner | TextKit 2 is not Sendable; safety by construction |

### Q: What is a custom actor executor and why do the media actors need one?

By default, all actors run on the shared **cooperative thread pool** (~1 thread per
core). The pool's rule is "threads must always make forward progress" — it is sized
for CPU work and shared by *everything* async in the process, including our layout
TaskGroups.

`ImageActor` overrides `unownedExecutor` to a `DispatchSerialQueue` it owns, and
dispatches decode work to a separate bounded concurrent queue. Result: a burst of 20
decode jobs during a fast fling consumes *its own* threads, and the cooperative pool
stays free for layout. Without this, decode bursts and layout would compete for the
same ~6 threads and the ring buffer would fall behind exactly when scrolling is
fastest — the worst possible time.

### Q: Why bounded *concurrent* decode queues instead of serial ones?

A serial queue caps decoding at 1 image at a time per media type (an earlier design
iteration made exactly this mistake). Decode is CPU-parallel-friendly; a concurrent
queue with an `AsyncSemaphore` (3 for images, 2 for GIFs) gives parallelism within an
explicit budget. The semaphore — not the queue width — is the contention control.

### Q: The codebase generally avoids `withCheckedContinuation`. Why is `ImageActor`'s use OK?

The general hazard with continuations is resuming zero or twice (hangs / crashes),
typically when bridging callback APIs with complex ownership. `ImageActor`'s pattern is
the degenerate-safe case:

```swift
await withCheckedContinuation { cont in
    decodeQueue.async {
        // straight-line code: exactly one resume on every path
        cont.resume(returning: processed)   // or nil
    }
}
```

`DispatchQueue.async` runs the closure exactly once; the closure resumes exactly once
on every branch. The ban targets multi-callback / priority-queue patterns, not
dispatch-and-resume.

### Q: How does cancellation flow through the system?

- **Prefetch**: `RenderPipeline` keeps one `prefetchTask`; a new index boundary
  cancels the old one. `Task.isCancelled` is checked before measuring, inside each
  TaskGroup child, and before the MainActor commit — a stale prefetch can't overwrite
  a newer window.
- **Media**: each mounted cell holds `MediaHandle`s; `prepareForReuse` cancels them,
  so recycled cells never receive late images. `ImageActor` checks `Task.isCancelled`
  before *and* after the network await (the cheap places to bail).
- **Fling**: `cancelBelowVisible()` on image/GIF actors sheds offscreen work
  immediately.

---

## 7. Performance Verification & QA Checklist

### Q: How do I verify each invariant? (The QA table)

| Invariant | Tool | Expected |
|---|---|---|
| No offscreen rendering | Instruments → Core Animation → "Color Offscreen-Rendered Yellow" | Zero yellow during scroll |
| No main-thread image conversion | "Color Copied Images" + Time Profiler | Zero blue; no `CA::Render::copy_image` |
| No scroll-path allocation | Instruments → Allocations during sustained scroll | Zero heap allocs attributable to `updateVisibleCells` |
| No scroll-path awaits | Code review + signposts | No suspension inside `layoutSubviews` call tree |
| Ring buffer keeps up | Spike 2 harness | Zero nil lookups after 0.5 s warmup, 120 fps, 200 items |
| Text measure = render | Spike 4 harness | ≤1 pt delta across 100 strings (emoji, RTL, ZWJ, dynamic type) |
| Frame rate | CADisplayLink frame-drop counter on real hardware | 120 fps sustained; main thread <15% CPU (Spike 3) |
| Swift 6 cleanliness | Build with strict concurrency | Zero diagnostics; `@unchecked Sendable` only on `TextMeasurementContext` |
| Pool safety | TSan + Spike 1 stress (500 nodes × 20 tasks) | No races; deterministic results; pool faster than per-call |

### Q: What were the four spikes and what did each de-risk?

All four passed before Phase 1 began (beads `VelocityUI-sjo.1–5`, closed):

1. **Spike 1 — pure-function layout + pooled text contexts.** De-risked: the entire
   Layer 2 concurrency model. If pooled TextKit 2 contexts race under Swift 6 strict
   concurrency, the architecture needs rethinking *before* anything is built on it.
2. **Spike 2 — ring buffer + synchronous scroll.** De-risked: the scroll contract.
   Proves prefetch can stay ahead of a 120 fps scroll without the scroll path awaiting.
3. **Spike 3 — CALayer scroll, no offscreen render, no copied images.** De-risked: the
   render strategy. Proves decode-time rounding + BGRA normalisation deliver 120 fps
   with <15% main-thread CPU on device.
4. **Spike 4 — text measure/render parity.** De-risked: the CATextLayer ban. Proves
   TextKit 2-measured heights match TextKit 2-rendered output within 1 pt, including
   the nasty cases (emoji, RTL, zero-width joiners, dynamic type).

### Q: Why build phases vertically (image feed first) instead of layer-by-layer?

A layer built in isolation validates against *imagined* neighbors. Phase 1 (image-only
vertical feed) forces **every** boundary to exist — DSL → NodeTable → pipeline → ring
buffer → scroll container → ImageActor — with the simplest possible media. If a
boundary type is wrong (e.g. `ResolvedLayout` lacks something cells need — see bead
`8gz`, render fragments), it surfaces in Phase 1 with one media type, not in Phase 4
with three. Later phases (text parity, GIF, video, masonry, hardening) snap onto a
*proven* skeleton.

### Q: What does Phase 1 acceptance (`VelocityUI-hbe`) actually sign off?

The contract, on hardware: scripted scroll over a sample image feed (DeviceTestHost),
frame-drop counter at zero below threshold, Allocations clean on the scroll path, both
Instruments color-debug checks clean, and the integration suite (`a5k`: items →
flatten → prefetch → ring buffer → cells, no device needed) green.

---

## 8. Adversarial Questions

*The "what about…" section — failure modes and honest answers.*

### Q: What happens if the user flings to index 5,000 instantly (scrollToBottom)?

The leading index jumps past the ring buffer window. `advance(to:)` detects
`shift >= capacity` and resets the whole buffer (the one case where it reallocates —
acceptable: it's a discrete user action, not per-frame). Every visible lookup misses →
full screen of placeholder gradients → the boundary notification triggers a prefetch
burst → cells fill as layouts land. Degradation is *graceful and bounded*: skeletons,
never a hang, never stale content.

### Q: What if image decode can't keep up with scroll speed?

Nothing on the scroll path waits for it. Cells show phase-1 geometry with placeholders;
images fade in as decodes complete. The fling branch actively sheds load (cancel
below-visible decodes) so the decode budget concentrates near the landing zone. The
failure mode is cosmetic (longer skeletons), never temporal (dropped frames).

### Q: Two cells share the same image URL. Do they decode twice?

`ImageActor` checks `NSCache` first, so a completed decode is shared. In-flight
request coalescing (two simultaneous requests for the same URL) is an ImageActor
implementation detail tracked in bead `0c5` — the cache key design (URL + target size
+ radius) must account for the same URL needing different processed variants.

### Q: Doesn't the `@MainActor.run` commit in the prefetch task violate "no async on the scroll path"?

No — directionality matters. The *pipeline* hops to MainActor to deposit results
(that's async work landing on main between frames, normal and cheap). The *scroll
path* never hops to the pipeline. The contract bans awaits in the
`layoutSubviews`-driven read path, not writes into MainActor state from elsewhere.

### Q: Hashes can collide. What happens if `layoutHash(A) == layoutHash(B)` for different content?

A collision makes the differ classify a changed cell as `.none` — stale layout until
the next data change. Probability: these are 64-bit hashes over structured input;
accidental collision is ~2⁻⁶⁴ per comparison. It's the same trust model SwiftUI and
React place in structural identity. If a specific node type ever shows pathological
inputs (e.g. hashing only a URL string that gets reused with different query params),
the fix is local: include the discriminating field in that node's hash.

### Q: `WorkingRange.advance` uses `removeFirst` + `append` — isn't that allocation/O(n)?

`removeFirst(k)` on an array is O(n) move (memmove of the tail), and `append` of the
nil-padding can allocate if capacity math is unlucky. Two mitigations: (1) `advance`
runs on the *pipeline's* MainActor commit, not on the per-frame read path — the
contract protects `layout(at:)`/`commit(at:)`, which are pure index math; (2) shift
sizes are small (items scrolled since last boundary). If Instruments ever shows this
matter, the upgrade is a true modular-index ring (head offset instead of physical
shift) — an internal change invisible to callers. *(Honest note: "ring buffer" today
describes the window semantics; the physical shift is an acceptable simplification
until data says otherwise.)*

### Q: A cell is recycled while its image decode is in flight. What guarantees no wrong-image flash?

Three independent guards: (1) `prepareForReuse` cancels all `MediaHandle`s before the
cell re-enters the pool; (2) `ImageActor` checks `Task.isCancelled` at each stage
boundary; (3) cross-item reuse hard-cuts contents to placeholder, so even a
hypothetically-leaked late callback would target a sublayer whose cell now renders for
a new item only after that item's own phase-2 content overwrites it. The privacy-bug
window is closed at the cell, the actor, and the layer level.

### Q: Why is `HostingNode` size fixed — what if my embedded view needs dynamic height?

Then it doesn't belong in `HostingNode`. Dynamic measurement of a UIView requires
main-thread sizing inside the layout pass — precisely the dependency the architecture
exists to remove. The honest options: compute the height yourself and pass it (the
data-driven path), or use native nodes (TextNode measures off-main). The constraint is
the feature: every cell's height is knowable off-main, so the feed never reflows under
the user's finger.

### Q: What's known to be missing in v1? (The honesty list)

- **Accessibility**: element-level only; no VoiceOver scroll semantics (scroll-to-item,
  page announcements) until v2.
- **RTL**: not mirrored yet (additive change to the layout pass — frames are already
  all computed centrally).
- **Insert/delete animations**: appended/removed items appear without animated
  transitions; fine for append-only feeds, not for mutable lists.
- **Drag and drop**: out of scope for the feed primitive.
- **Rotation**: full `invalidateAll` + re-measure (speculative multi-width caching is
  a documented future improvement, gated on it being an observed problem).
- **GIF on Metal, precompositing, IOSurface pooling, progressive JPEG**: all gated on
  Instruments evidence, deliberately not built speculatively.

### Q: What single regression would be most damaging, and how would it be caught?

An accidental allocation or await sneaking into `updateVisibleCells` — it would erode
frame pacing gradually and only on device. Defense in depth: the CI frame-drop counter
on real hardware (Phase 6), the Allocations-instrument scroll-path budget ("a single
unexpected alloc during `updateVisibleCells` is a regression"), and `os_signpost`
boundaries making any new suspension visible in a trace.

---

## 9. Glossary

| Term | Meaning |
|---|---|
| **RenderNode** | DSL value describing one UI element; carries `layoutHash` + `appearanceHash` |
| **RenderView** | Developer-facing protocol: `renderBody: some RenderNode` via result builder |
| **NodeTable** | Flat, Sendable, index-based representation of a cell's node tree; the Layer 1→2 currency |
| **NodeKind** | Flat enum of all node types — the existential-free encoding inside NodeTable |
| **ResolvedLayout** | Output of measurement: frames (and render fragments) for one cell at one width |
| **WorkingRange** | MainActor ring buffer of ResolvedLayouts covering ~3 screens around the viewport |
| **RenderCell** | Pooled CALayer-backed cell; two-phase commit (geometry, then content) |
| **MediaHandle** | Cancellable token for an in-flight media fetch owned by a mounted cell |
| **DimensionCache** | URL → pixel-size cache fed by ranged HTTP fetches and full decodes |
| **Change classifier** | `none / appearance / media / layout` — cheapest sufficient reaction to a diff |
| **Two-phase commit** | Geometry synchronously on scroll path; media contents async when ready |
| **Fling** | Pan velocity > 800 pt/s; pauses videos and sheds offscreen decode work |
| **Cooperative pool** | Swift Concurrency's shared, core-count-sized thread pool — layout's territory |
| **Custom executor** | DispatchQueue-backed actor executor isolating media work from the cooperative pool |
| **Spike** | 1-day pre-Phase-1 validation of a load-bearing assumption (all 4 passed) |
| **The Contract** | Scroll never awaits · layout never blocks media · media never starves layout |

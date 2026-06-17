# VelocityUI — Architecture for Juniors

> A friendly walkthrough of `ARCHITECTURE.md` and `ARCHITECTURE_QA.md` for engineers
> who are new to iOS, Swift Concurrency, or rendering pipelines. No prior knowledge of
> Texture, AsyncDisplayKit, Core Animation, or React's diffing model assumed.

If you finish this document you should be able to:

1. Explain *why* VelocityUI exists and what it does in one paragraph.
2. Read the four-layer diagram in `ARCHITECTURE.md` and know what each box does.
3. Open any file under `Sources/VelocityUI/` and understand which layer it belongs to.
4. Recognize the jargon (`@MainActor`, `Sendable`, ring buffer, CALayer, actor) and
   know what each term *means in this codebase*.
5. Ask a sharper question than "what does this do?" the next time you read code.

This file is the **friendly on-ramp**. `ARCHITECTURE.md` is the **map**.
`ARCHITECTURE_QA.md` is the **detailed deep-dive**. Read in that order.

---

## Table of Contents

1. [What is VelocityUI, in plain English?](#1-what-is-velocityui-in-plain-english)
2. [The problem we're solving](#2-the-problem-were-solving)
3. [The one rule that explains everything: the scroll path never stops](#3-the-one-rule-that-explains-everything-the-scroll-path-never-stops)
4. [Vocabulary you need before reading further](#4-vocabulary-you-need-before-reading-further)
5. [The four layers, explained like a restaurant kitchen](#5-the-four-layers-explained-like-a-restaurant-kitchen)
6. [Layer 1: the developer's API (the menu)](#6-layer-1-the-developers-api-the-menu)
7. [Layer 2: the render pipeline (the prep station)](#7-layer-2-the-render-pipeline-the-prep-station)
8. [Layer 3: the scroll container (the waiter)](#8-layer-3-the-scroll-container-the-waiter)
9. [Layer 4: the media pipeline (the specialty stations)](#9-layer-4-the-media-pipeline-the-specialty-stations)
10. [No singletons — the composition root](#10-no-singletons--the-composition-root)
11. ["Wait, but why...?" — common questions](#11-wait-but-why--common-questions)
12. [How to read the codebase](#12-how-to-read-the-codebase)
13. [Glossary](#13-glossary)

---

## 1. What is VelocityUI, in plain English?

VelocityUI is a Swift library that draws **scrolling feeds** — think Instagram, TikTok,
Pinterest — that stay smooth even when every cell is a video or an animated GIF, on
phones that draw the screen 120 times per second.

It does this by avoiding almost every part of the "normal" iOS UI toolkit. Most apps
use UIKit (`UICollectionView`) or SwiftUI (`List`, `LazyVGrid`) to draw a feed.
VelocityUI uses **none of them**. It draws cells directly with `CALayer` (the layer
underneath every UIView) and computes the layout for those cells **on background
threads** in parallel.

If that sentence sounded scary, you're in the right place. The rest of this doc
unpacks why those choices exist and what each piece does.

---

## 2. The problem we're solving

Modern phones refresh the screen at 60 Hz (older devices) or 120 Hz (ProMotion
iPhones / iPads). At 120 Hz you get one frame every **8.3 milliseconds**. If your code
takes longer than 8.3 ms to figure out what to draw, the user sees a stutter — a frame
gets repeated, scrolling feels jerky. This is called *dropping a frame*.

Now picture a feed full of mixed content:

- some cells have text that needs sizing,
- some cells have images that need downloading + decoding,
- some cells have videos that need preparing,
- some cells have GIFs that animate every frame.

If you do all of that on the **main thread** (the one UIKit and SwiftUI use), you will
absolutely drop frames. There simply isn't 8.3 ms to spare for "download this image,
decode it, lay out this text, attach a video player" while *also* scrolling.

The mainstream tools struggle here:

| Tool | Why it isn't enough |
|---|---|
| SwiftUI `List` / `LazyVGrid` | Everything runs on the main thread. No way to move it off. |
| `UICollectionView` + custom cells | Each cell is a UIView with its own layout pass. UIKit does extra work per cell that adds up. |
| Texture / AsyncDisplayKit | The classic solution, but it's old Objective-C++, unmaintained, and predates Swift Concurrency. |

VelocityUI is what you get if you start from scratch in Swift 6, push every expensive
job off the main thread, and protect the **scroll path** (the code that runs every
frame while the finger moves) from anything slow.

---

## 3. The one rule that explains everything: the scroll path never stops

If you remember only one thing from this entire document, remember this:

> **While the user is scrolling, the code that decides what's on screen is not
> allowed to wait for anything.**

"Wait for anything" includes:

- waiting for a network request,
- waiting for an image to decode,
- waiting for text to be measured,
- waiting for an `actor` to be free,
- waiting for *any* `await` of *any* kind.

Why so strict? Because every wait could last longer than 8.3 ms, and if it does, a
frame drops. The user sees a jitter.

So how does the cell at the top of the screen know its own size if size computation is
slow? Easy: **someone computed it earlier**, stored the result somewhere fast, and the
scroll code just looks it up. Imagine prepping a meal the night before a busy morning:
when breakfast time comes, you reheat instead of cook.

This is the core trick. Most of VelocityUI's complexity exists to:

1. Compute layout, decode media, prepare videos **ahead of time**, in parallel, on
   background threads.
2. Deposit the results into a data structure the scroll code can read **instantly**.
3. Make sure that "ahead of time" work doesn't block the screen.

The codebase formalizes this as **three contract clauses**:

1. **The scroll path never awaits.** The function that runs every frame is synchronous.
2. **Layout never blocks media.** Measuring cells and decoding images run on separate
   thread pools, so a slow image doesn't make scrolling stutter.
3. **Media never starves layout.** Decoding a burst of images can't accidentally hog
   the threads layout needs, either.

Think of it as three rules in a kitchen: the waiter never waits for the cook, the
salad station never blocks the grill, the grill never blocks the salad station.

---

## 4. Vocabulary you need before reading further

These terms come up everywhere. Don't try to memorize them; just skim once and come
back when you hit one.

### Threads, queues, and the "main thread"

- **Thread.** A CPU worker. A computer runs many at once.
- **Main thread.** The one thread that's allowed to touch the screen. UIKit and SwiftUI
  require the main thread for almost everything. If the main thread is busy, the screen
  freezes.
- **Background thread.** Any thread that's not main. Safe for slow work as long as the
  work doesn't poke UI.
- **Queue.** A list of jobs waiting for a thread to pick them up. `DispatchQueue` is
  Apple's classic API for queues.

### Swift Concurrency

- **`async` / `await`.** Modern Swift syntax for "this function can pause and resume
  later." `await someThing()` means "wait here until `someThing` finishes."
- **`Task`.** A unit of async work. Like a thread, but scheduled by Swift, not the OS.
- **Actor.** A type whose state can only be read or written by **one task at a time**.
  Calling a method on an actor from outside requires `await`. Actors prevent data races
  for free — but they also **serialize** access, which can be a downside.
- **`@MainActor`.** A label on a type or function meaning "this only runs on the main
  thread." UI code lives here.
- **`nonisolated`.** A label meaning "no actor protects me; call me from anywhere
  without `await`." Used on pure functions that have no shared state.
- **Cooperative pool.** Swift Concurrency's shared pool of background threads. Roughly
  one thread per CPU core. All `async` work runs here by default.
- **Custom executor.** A way to tell an actor "don't use the cooperative pool; use
  *my* private queue instead." VelocityUI uses this for media actors so they can't
  starve layout.

### Sendable and data races

- **`Sendable`.** A protocol meaning "this value is safe to pass between threads."
  Swift 6's compiler enforces this — you literally cannot send a non-`Sendable` value
  across an actor boundary.
- **`@unchecked Sendable`.** An escape hatch: "trust me, this is safe even though the
  compiler can't prove it." Used sparingly, only when there's a *human-checkable*
  reason it's safe.

### Drawing — UIKit vs. Core Animation

- **UIView.** The thing you usually think of as "a UI element." Has layout, gesture
  recognition, accessibility, lots of features.
- **CALayer.** The lower-level object underneath every UIView that actually draws
  pixels. Much lighter — no gesture handling, no automatic layout.
- **`layer.contents`.** A pointer to the bitmap (`CGImage`) that fills the layer.
  Assigning to this is essentially free (just a pointer swap).
- **`layer.cornerRadius` + `masksToBounds`.** The "make this layer have rounded
  corners" combo. **Banned in VelocityUI** because it forces the GPU to render the layer
  to an off-screen buffer and clip it — expensive per frame.

### TextKit

- **TextKit 2** (`NSTextLayoutManager`). The newer, accurate text layout engine
  Apple ships. VelocityUI uses this to measure how tall a piece of text will be.
- **`CATextLayer`.** A CoreAnimation layer that can draw text. **Banned in VelocityUI**
  because it uses its *own* layout engine, so the height you measured with TextKit 2
  won't match the height CATextLayer actually draws.

### Pixel formats

- **BGRA8888 premultiplied.** A pixel format: 8 bits each of Blue, Green, Red, Alpha,
  where the color channels have already been multiplied by alpha. This is what Core
  Animation prefers natively. If you give it any other format, it'll silently convert
  on the main thread (slow). VelocityUI converts every image to this format **at
  decode time** so commit is free.

You've now seen every scary term. Promise.

---

## 5. The four layers, explained like a restaurant kitchen

VelocityUI is structured as four layers. Each layer only talks to its neighbors, and
they only pass each other **value types** (no references to shared mutable state). Here's
the kitchen metaphor:

| Layer | Role | Kitchen analogy |
|---|---|---|
| **1 — Developer DSL** | The SwiftUI-style code a developer writes to describe a cell | The **menu** the chef writes |
| **2 — Render Pipeline** | Measures cells, runs on background threads in parallel | The **prep station**: chopping, weighing, prepping |
| **3 — Scroll Container** | Puts the right cells on screen at the right time, on the main thread | The **waiter**: takes ready dishes to the table |
| **4 — Media Pipeline** | Downloads and decodes images, GIFs, and videos | The **specialty stations**: grill, fryer, video player |

When the user scrolls, the waiter (Layer 3) only does fast, simple things — pick up
already-ready dishes, walk them to the table. The cooking (Layers 2 + 4) happens out
of the customer's sight, in parallel, ahead of time.

```
   ┌───────────────────────────┐
   │ Layer 1: Developer DSL    │  developer writes SwiftUI-like code
   │ (the menu)                │  → describes WHAT to show
   └────────────┬──────────────┘
                │  flatten once
                ▼
   ┌───────────────────────────┐
   │ Layer 2: Render Pipeline  │  measure off-main, in parallel
   │ (the prep station)        │  → figures out HOW BIG each cell is
   └────────────┬──────────────┘
                │  ResolvedLayout deposited into ring buffer
                ▼
   ┌───────────────────────────┐
   │ Layer 3: Scroll Container │  reads ring buffer, places CALayers
   │ (the waiter)              │  → puts cells on screen, FAST
   └────────────┬──────────────┘
                │  asks media pipeline for pictures/videos
                ▼
   ┌───────────────────────────┐
   │ Layer 4: Media Pipeline   │  fetch + decode off-main, in parallel
   │ (specialty stations)      │  → makes the bitmaps the waiter shows
   └───────────────────────────┘
```

The arrows go *down*, but they don't all run in order — Layer 4 starts working as soon
as Layer 3 knows what's about to be visible, often *before* the user has scrolled there.

---

## 6. Layer 1: the developer's API (the menu)

A developer using VelocityUI writes code that looks a lot like SwiftUI:

```swift
struct PostCell: RenderView {
    let post: Post

    var renderBody: some RenderNode {
        VStackNode {
            TextNode(post.author)
            AsyncImageNode(url: post.imageURL)
            TextNode(post.caption)
        }
    }
}

AsyncFeed(items: posts, id: \.id) { post in
    PostCell(post: post)
}
```

Looks familiar, right? But under the hood, this isn't SwiftUI — `RenderNode`,
`VStackNode`, `TextNode`, etc. are VelocityUI's own types.

### What's a `RenderNode`?

A `RenderNode` is a **lightweight value** that describes one piece of UI. It carries
two hashes:

- **`layoutHash`** — covers things that affect *size* (text content, font, aspect ratio).
- **`appearanceHash`** — covers things that affect *only color/pixels* (text color, etc).

Two hashes are better than one because they let the diffing system answer two
questions separately:

- "Did anything change that means I need to re-measure?" (cheap if no)
- "Did anything change that means I need to redraw?" (cheap if no)

If only the text color changed, the cell doesn't need to be measured again — just
redrawn. Saving that measurement work is one reason the library can keep up at 120 Hz.

### `NodeTable` — the "flatten once" trick

Right at the boundary between Layer 1 and Layer 2, VelocityUI takes the tree of
`RenderNode`s the developer wrote and **flattens it into a flat array** called
`NodeTable`. Why?

A tree of `any RenderNode` (an "existential" — a protocol-typed value) has problems:

1. Each node may need a heap allocation (slow).
2. Calling methods on it requires dynamic dispatch (slow).
3. Walking the tree chases pointers all over memory (slow for the CPU's cache).

Flattening to a plain array of enum values fixes all three:

```
   Tree (existentials, slow)         Flat NodeTable (fast)
   ┌──────────────────────┐          ┌─────────────────────────────────┐
   │  VStackNode          │          │ nodes:   [.vstack, .text, .image, .text] │
   │   ├─ TextNode        │  flatten │ parents: [   -1,     0,      0,     0  ] │
   │   ├─ AsyncImageNode  │  ───────▶│ layoutHash:     0xABC...                 │
   │   └─ TextNode        │          │ appearanceHash: 0x123...                 │
   └──────────────────────┘          └─────────────────────────────────────────┘
```

Tree structure is preserved using `parentIndices` (integer indexes into the array),
not pointers. Layers 2, 3, and 4 only ever see `NodeTable` — they never touch the
original tree.

The DSL also has a few special nodes:

- **`HostingNode`** — escape hatch for embedding a raw UIView (e.g. `MKMapView`). You
  must declare its size up front because measuring a UIView would require the main
  thread, and Layer 2 isn't allowed to use the main thread.

---

## 7. Layer 2: the render pipeline (the prep station)

This is the heart of the library. It runs on background threads, in parallel, and
produces `ResolvedLayout` values: "for this cell at this width, here's where every
piece goes."

### Pure functions instead of an actor

A natural design would be to put layout behind an actor: `LayoutActor.measure(cell)`.
But actors **serialize** — only one task can be inside an actor at a time. That would
turn an embarrassingly parallel problem (cells don't depend on each other) into a
queue.

VelocityUI instead makes the measurement function a **`nonisolated` pure function**:

```swift
nonisolated func measureNode(...) -> ResolvedLayout { ... }
```

Pure means: same inputs always give the same output, and it touches no shared state.
That means it's safe to call from many tasks at once. A `TaskGroup` fans out N
measurements across all CPU cores at the same time, with zero coordination needed.

The **only** actor in the layout path is `LayoutCache` — because the cache is the
only thing that's shared and mutable. The rule of thumb the codebase follows is:

> *Isolate state, not work.*

### The text-measurement asterisk

There's one catch. Text measurement uses TextKit 2 types (`NSTextLayoutManager`,
`NSAttributedString`, `UIFont`) — and Apple hasn't marked these as `Sendable`. So you
can't safely use them from multiple threads.

The chosen fix: a **pool** of text-measurement contexts. There's one context per CPU
core. When a task needs to measure text, it checks one out, uses it, returns it.
Because only one task ever holds a given context at a time, it's safe in practice,
even though the compiler can't prove it. So we mark the context `@unchecked Sendable`
— the "asterisk" version of `Sendable` that says "trust me, this is safe."

```
                            TextMeasurementPool
                            ┌──────────────────────────────┐
                            │ AsyncSemaphore(cores)        │  caps concurrent users
                            │ pool: [ctx, ctx, ctx, ctx]   │  one per core
   task A ── await wait() ──┤                              │
   task B ── await wait() ──┤  withContext { ctx in ... }  │
   task C ── await wait() ──┤                              │
                            └──────────────────────────────┘
```

### `WorkingRange`: the ring buffer where results are stored

Once Layer 2 has measured a bunch of cells, it needs to give the results to Layer 3
in a way Layer 3 can read **instantly** without any locking, hashing, or allocation.

A first instinct is `[Int: ResolvedLayout]` (a dictionary). That seems fine — lookups
are O(1), right? But on the scroll path it has three problems:

1. Hashing isn't free. Even cheap hashing adds up at 120 Hz × many cells.
2. Eviction (removing layouts that scrolled out of range) typically calls `.filter`,
   which **reallocates the whole dictionary on the main thread**. That's exactly the
   kind of stall we're trying to avoid.
3. A dictionary doesn't naturally encode "a sliding window of items," so it can grow
   unboundedly between cleanups.

So VelocityUI uses a **ring buffer**: a fixed-size array (default 60 slots, about 3
screens' worth of cells) that represents the window of items around the viewport:

```
   item index space: ... 41  42  43  44  45  46  47  48 ...
                          │   │   │   │   │   │
   buffer (capacity 60): [L][L][L][L][L][nil]...
                          ▲
                          rangeStart = 42

   layout(at: 45)  →  buffer[45 - 42]          one subtraction, no hash, no alloc
   advance(to: 44) →  shift the window left    only when the viewport moves to a new item
```

The scroll path's lookup becomes:

```swift
let layout = buffer[i - rangeStart]   // O(1), zero allocation, zero hashing
```

That's what makes the scroll path synchronous and stutter-free.

### The diffing system — what changed since last time?

When data updates (new posts arrive, a like count changes), VelocityUI doesn't re-do
everything. It compares the old `NodeTable` for each cell against the new one and
classifies the difference into one of four tiers:

| Tier | Meaning | What happens |
|---|---|---|
| `.none` | Nothing changed | Skip the cell entirely |
| `.appearance` | Only colors/cosmetics changed | Redraw one layer's contents, no re-measure |
| `.media` | Image URL changed, but we already know its size | Re-fetch the image, no re-measure |
| `.layout` | Size or content changed | Full re-measurement needed |

The cheaper tiers run vastly more often than the expensive ones. This is what makes
"new posts loaded" not rebuild everything.

---

## 8. Layer 3: the scroll container (the waiter)

`FeedScrollView` is a custom subclass of `UIScrollView`. It does **not** use
`UICollectionView`. The team chose to write the cell lifecycle from scratch.

### Why not UICollectionView?

UICollectionView would give us prefetch, accessibility, and animations for free. But
it would also impose:

- A UIView per cell. UIView has a heavy layout system that runs even when we don't
  need it.
- Sizing callbacks that the framework may call at awkward times on the main thread.
- An invalidation model that fights us because we already know every frame off-main.

VelocityUI already does layout off-main, ahead of time. At commit time it just needs
to set `layer.frame` and `layer.contents`. UIView would add cost without value.

The trade-offs are real and acknowledged: VoiceOver scroll semantics, RTL,
insert/delete animations are scheduled v2 work. v1 covers taps and basic
accessibility via a single transparent UIView overlay.

### What happens every frame?

`layoutSubviews()` fires on every scroll position change. Here's what runs:

```
1. updateVisibleCells()
   a. Binary search the visible index range from the cached frames
   b. Recycle cells that scrolled out of the prefetch window
   c. For each newly visible index:
        layout = workingRange.layout(at: i)   // O(1) ring buffer read
        if hit:  reuse a cell, apply geometry, add to view
        if miss: show a placeholder (rare after warmup)
   d. Update the interaction overlay (tap targets + accessibility frames)

2. updateVideoPlayback()
   a. Compute which videos should play (based on visibility threshold)
   b. Diff against current state — usually no changes → return immediately
   c. If changed: one batched Task

3. notifyPipelineIfNeeded()
   a. Did the leading visible index cross an item boundary?
      No  → return immediately
      Yes → one Task to pipeline.onIndexBoundary(...)
```

If the user is scrolling **within** a single item (most of the time), every step
returns immediately with **zero Tasks, zero allocations, zero awaits**.

### Two-phase commit: geometry first, content second

When a cell becomes visible, VelocityUI doesn't wait for the image to be ready before
showing the cell. It runs two phases:

- **Phase 1 — geometry.** Synchronous, on the scroll path. Set up the cell's
  sublayers in their correct frames, show a gray placeholder gradient. The user sees
  a correctly-sized skeleton instantly.
- **Phase 2 — content.** Asynchronous. When the media pipeline (Layer 4) delivers
  a decoded image, swap it into `layer.contents` with a 0.2 s fade.

This means scroll speed is never coupled to network speed. Slow Wi-Fi → skeletons
hang around longer, but scrolling stays at 120 fps.

### Two recycle modes

When a cell is recycled (reused for another item as it scrolls out of view):

- **Cross-item recycle** (different item now): **hard cut** — instantly clear all
  contents and show the placeholder. This is both a UX detail and a **privacy bug
  prevention**: imagine a stranger's avatar flashing inside your DM thread for one
  frame because the cell was reused from the wrong post. Not okay.
- **Same-item recycle** (same item, minor update — e.g. like count changed):
  **stale until replaced** — keep the old content visible, swap when the new content
  arrives. Otherwise you'd see a flicker for what's just a tiny data refresh.

---

## 9. Layer 4: the media pipeline (the specialty stations)

Layer 4 is the slowest part of the system — networking, image decoding, video player
setup. Every design choice here protects the scroll path from this slowness.

### Network and decode on separate "tracks"

A naive design uses one queue for both: an actor that awaits the network *inside* its
decode queue. The problem: a job that's "200 ms network + 5 ms decode" holds a queue
slot for 205 ms doing 5 ms of work — **2.5% CPU utilization** — while higher-priority
decodes pile up behind a stalled network call.

The right design separates them:

```
  network fetch:                       decode (CPU-bound):
  plain `await URLSession.data(from:)` ┌─ velocityui.image.decode (concurrent, sema=3)
  (I/O — task suspends, holds no       ├─ velocityui.gif.decode  (concurrent, sema=2)
   thread)                             └─ each on its own DispatchQueue
   uses the cooperative pool, fine
```

The semaphores (`AsyncSemaphore(3)` for images, `AsyncSemaphore(2)` for GIFs) cap how
many decodes can happen at once. Without them, a fast scroll could try to decode 50
images at the same time, exhausting memory and CPU.

### Why are image actors on **custom executors**?

Most actors in VelocityUI use the default cooperative pool. But `ImageActor`,
`GIFActor`, and a few others use a **custom executor** backed by a `DispatchQueue`
they own. Why?

Because of contract clause 3: *media never starves layout.* If image-decode threads
came out of the cooperative pool, a burst of decodes during a fast fling could
exhaust the pool right when layout needs threads to keep the ring buffer ahead of
scroll. By giving media its own queue, the cooperative pool stays free for layout.

### Two things that get baked into images at decode time

When an image is decoded, two important transformations happen **at decode time** in
the same `CGContext` blit (one pass over the pixels):

1. **Corner rounding.** Instead of using `layer.cornerRadius`, the corners are
   painted using a `CGContext` clip path. The rounded bitmap is what gets stored.
   The render path costs zero.
2. **BGRA8888 normalization.** The bitmap is converted to Core Animation's preferred
   pixel format. Without this, CA would silently convert it on the main thread at
   commit time — a hidden stall.

Both these decisions move CPU work from "every frame, on the main thread" to "once,
on a background thread." Pure win.

You can verify these are working in Instruments:

- "Color Offscreen-Rendered Yellow" should show **zero yellow** during scroll.
- "Color Copied Images" should show **zero blue**.

Those are the proof that rounding and color-conversion are not happening at draw time.

### Why download just the first 1 KB of an image?

Layout needs to know an image's aspect ratio *before* the image is fully downloaded —
otherwise the cell doesn't know how tall it should be. VelocityUI sends a ranged HTTP
request (`Range: bytes=0-1023`) to grab just the header. PNG's `IHDR` block is in the
first 33 bytes; JPEG's `SOF` is usually in the first ~500 bytes. The result goes into
a `DimensionCache`. Now layout can run with the right aspect ratio while the rest of
the image is still downloading.

### Video: two actors, one job

Video is split:

- **`VideoController`** (on `@MainActor`) owns the `AVPlayer`s and `AVPlayerLayer`s.
  These types are not `Sendable` and must live on the main thread anyway, since
  they're tied to the layer tree.
- **`VideoPreparationActor`** (on the cooperative pool) handles the slow
  `AVPlayerItem` setup — loading asset metadata, checking playability. All the slow
  off-main work happens here.

The controller asks the preparation actor for a ready item, then attaches it.
Players never leave the main thread; preparation never touches the main thread.

Hard budgets exist for both:

- **3 attached players** at a time. iPhone hardware video decode supports a small
  number of simultaneous sessions; going over silently falls back to software decode
  (CPU, battery, dropped frames). 3 is the safe portable cap.
- **8 prepared items** at a time. Preparation buffers + holds network connections;
  more than 8 wastes memory.

When memory pressure hits, GIF resident frames and prepared video items are evicted
first. Layouts are *not* evicted because they're tiny and expensive to recompute, and
losing them would cause blank-cell churn right when the system is already under
pressure.

---

## 10. No singletons — the composition root

A "singleton" is a single shared instance that lives for the entire app — e.g.
`URLSession.shared`, or `static let cache = ImageCache()`. They're tempting because
they're easy to access from anywhere, but they hide dependencies and make testing
hard.

**VelocityUI bans them** on its own types. Why?

| Problem singletons cause | Concrete cost |
|---|---|
| Two feeds in the same app share one cache | One feed pollutes the other; you can't budget memory per feed |
| Tests can't substitute fakes | Test code is forced to hit the real network |
| `AsyncFeed` deinit doesn't tear down running tasks | Leaked Tasks holding `CGImage`s, AVPlayers, GIF ring buffers |

Instead, every long-lived collaborator (caches, actors, pools, controllers) lives
inside a single `RenderEnvironment` value, **created once per `AsyncFeed`**, and
**injected by initializer** into everything that needs it:

```swift
public final class RenderEnvironment: Sendable {
    public let textPool:         TextMeasurementPool
    public let layoutCache:      LayoutCache
    public let dimensionCache:   DimensionCache
    public let imageActor:       ImageActor
    public let gifActor:         GIFActor
    public let videoController:  VideoController
    public let videoPreparation: VideoPreparationActor
}

// One environment per feed:
let env = RenderEnvironment()
AsyncFeed(items: posts, id: \.id, environment: env) { post in ... }
```

In tests you build a `RenderEnvironment` with fake actors instead:

```swift
let env = RenderEnvironment(
    textPool: .init(),
    layoutCache: .init(),
    dimensionCache: dc,
    imageActor: FakeImageActor(dimensionCache: dc),
    ...
)
```

This is called the **composition root** pattern. The whole object graph is built in
one place, at the top of the program. Nothing else reaches into a global.

The pure functions (`measureNode`, `classify`, `normaliseAndRound`, `rasterizeText`)
also follow this rule — if they need a pool or cache, it's an **argument**, not a
global. This makes them testable in isolation.

---

## 11. "Wait, but why...?" — common questions

These are the questions a new contributor usually asks. Quick answers; deeper ones
in `ARCHITECTURE_QA.md`.

### Q: Isn't `async`/`await` supposed to be cheap? Why is one `await` a problem?

It's cheap on average but not bounded by 8.3 ms. An `await` is a suspension: your
continuation gets put back on a queue and **resumes whenever the executor gets to
it** — possibly after the next frame's deadline. On a frame deadline you can't accept
"usually fast."

### Q: Why not just put layout on a background thread with one big GCD `async`?

That works, but it's serial — one cell measured at a time. VelocityUI measures cells
in parallel using `TaskGroup`, so an N-cell update finishes in `N/cores` time, not N
time. That parallelism is why off-main layout is fast enough to keep the ring buffer
ahead of scroll.

### Q: Why is `[Int: ResolvedLayout]` so bad? Dictionaries are normal in Swift.

Two real costs the scroll path can't afford:

1. **Hash overhead** — small but adds up at 120 Hz × visible-cell-count.
2. **Eviction is `.filter`** — rebuilds the whole dictionary, allocating on the main
   thread mid-scroll. That single line could drop frames every time it runs.

The ring buffer has neither problem: lookup is one subtraction, and "eviction" is just
moving where the window starts.

### Q: Why can't I use `layer.cornerRadius` for rounded corners?

Because it forces the GPU to render the layer to an off-screen buffer, clip it, then
composite it back — every frame, for every layer with `cornerRadius` set. With a 3-
column grid you're paying that cost 3+ times per frame, forever. Decode-time rounding
costs one CPU blit, once, ever.

### Q: Why ban `CATextLayer`? Text on the GPU sounds fast.

Because `CATextLayer` uses its own layout engine, not TextKit 2. The height
VelocityUI measures with TextKit 2 won't match the height CATextLayer actually draws
— so you'd see clipped text or stray padding, intermittently and unpredictably. The
rule is: **the engine that measures is the engine that draws.** Both render modes
(`asyncBitmap` and `synchronousDraw`) use TextKit 2 for drawing too.

### Q: What if two cells use the same image URL? Do they decode it twice?

`ImageActor` checks `NSCache` first, so a completed decode is shared between cells.
In-flight request coalescing (two simultaneous requests for the same URL) is being
worked on — the cache key has to account for the same URL needing different sizes /
corner radii.

### Q: What about accessibility? Doesn't a CALayer-based UI break VoiceOver?

v1 has element-level accessibility via a single transparent UIView overlay above the
layer tree. The overlay's accessibility elements are updated in the same MainActor
pass as cell mounting, so they're never stale. Full VoiceOver *scroll semantics*
(scroll-to-item, page announcements) are v2 work.

### Q: How does cancellation work? If the user scrolls fast, what stops stale work?

Three levels of cancellation:

1. **Prefetch**: only one `prefetchTask` is allowed at a time. A new index boundary
   cancels the old one. `Task.isCancelled` is checked before measuring and before
   the MainActor commit.
2. **Media**: each mounted cell holds `MediaHandle`s. When the cell is recycled,
   `prepareForReuse` cancels them — so a late image can never land in the wrong cell.
3. **Fling**: when pan velocity exceeds 800 pt/s, `cancelBelowVisible()` sheds all
   offscreen decode work immediately, freeing the decode budget for the landing zone.

---

## 12. How to read the codebase

If you've gotten this far, here's a practical reading order:

```
1. Sources/VelocityUI/DSL/
     RenderNode.swift              — the protocol developers write against
     RenderNodeBuilder.swift       — the @resultBuilder for renderBody
     Nodes/                        — VStackNode, TextNode, AsyncImageNode, ...
     NodeTable.swift               — the flat representation (Layer 1↔2 boundary)

2. Sources/VelocityUI/Pipeline/
     LayoutEngine.swift            — measureNode and friends (pure functions)
     ResolvedLayout.swift          — the output of measurement
     WorkingRange.swift            — the ring buffer (currently being edited)
     RenderPipeline.swift          — orchestrates measurement, owns LayoutCache
     TextMeasurementPool/Context   — the pooled TextKit 2 setup
     TextRasteriser.swift          — turns text into CGImages
     ImageNormaliser.swift         — the BGRA + rounding blit

3. Sources/VelocityUI/ScrollContainer/
     RenderCell.swift              — the CALayer-backed cell

4. Sources/VelocityUI/Media/
     ImageActor.swift              — fetch + decode + cache for images
```

The bead tracker (`bd ready`) shows which boundaries are still being built. Use it to
see what work is "in flight" before reading.

Tips:

- When you see `actor`, ask: *what state does this protect, and why does that need
  serialization?*
- When you see `nonisolated`, ask: *why is this pure / what shared state does it
  avoid?*
- When you see `@unchecked Sendable`, look for the comment explaining *why* it's
  safe by construction. There should always be one.
- When you see `@MainActor`, ask: *does this need to be on main, or is it just
  marking a UI boundary?*

---

## 13. Glossary

| Term | Plain-English meaning |
|---|---|
| **Actor** | A type whose state is touched by one task at a time. Like a small office with one desk: people queue to use it. |
| **`@MainActor`** | A label that pins code to the main thread (the only one allowed to draw UI). |
| **`async`/`await`** | Modern Swift's pause-and-resume syntax. `await` means "this may wait." |
| **BGRA8888** | A pixel format: 8 bits each of Blue, Green, Red, Alpha. The format Core Animation likes natively. |
| **CALayer** | The lightweight object that actually draws pixels. Every UIView is backed by one. |
| **Composition root** | The one place in the program where all dependencies are wired together. Here: `RenderEnvironment`. |
| **Cooperative pool** | Swift Concurrency's shared background thread pool, sized to your CPU. |
| **Custom executor** | A way to say "this actor uses its own dispatch queue instead of the cooperative pool." |
| **DSL** | Domain-specific language. Here: VelocityUI's SwiftUI-style cell API. |
| **Frame deadline** | The 8.3 ms (at 120 Hz) you have to draw one frame before stuttering. |
| **`NodeTable`** | A flat, Sendable, index-based representation of a cell's UI tree. |
| **`nonisolated`** | A label meaning "no actor protects me — safe to call without `await`." Used on pure functions. |
| **Pure function** | A function whose output depends only on its inputs, and which touches no shared state. Safe to call in parallel. |
| **`RenderEnvironment`** | The composition root: one bag of all the long-lived collaborators per `AsyncFeed`. |
| **Ring buffer** | A fixed-size array used as a sliding window. Replaces a dictionary on the scroll path. |
| **Scroll path** | The code that runs on the main thread every frame while the user scrolls. Must be synchronous. |
| **Sendable** | A protocol meaning "safe to pass between threads." Swift 6 enforces this at compile time. |
| **`@unchecked Sendable`** | An escape hatch — "trust me, this is safe." Used where the safety reason isn't expressible to the compiler. |
| **TaskGroup** | A way to spawn many concurrent child tasks and await them all together. |
| **Texture / AsyncDisplayKit** | The old Facebook library that pioneered off-main layout for feeds. VelocityUI is its Swift 6 spiritual successor. |
| **TextKit 2** | Apple's modern text layout engine (`NSTextLayoutManager`). VelocityUI uses it for both measurement and rendering. |
| **Two-phase commit** | The cell-mounting strategy: geometry sync on the scroll path, media async when ready. |
| **`WorkingRange`** | The ring buffer of `ResolvedLayout`s that the scroll path reads. |

---

## Next steps

You're now ready to read:

1. **`ARCHITECTURE.md`** — the structural map, with diagrams. Should now make sense.
2. **`ARCHITECTURE_QA.md`** — deeper Q&A on every topic above. Read sections as you
   need them, not cover-to-cover.
3. **`velocityui-prompt.md`** — the full engineering spec. The source of truth for
   what the library is supposed to be.
4. The code under `Sources/VelocityUI/`, in the order suggested in
   [Section 12](#12-how-to-read-the-codebase).

If anything in those docs still feels confusing, that's a doc bug, not a you bug.
Open an issue with `bd create --type=task --title="Doc clarification: ..."` and
someone will fix the wording.

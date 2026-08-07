# VelocityUI — Benchmark & Profiling Log

Running, append-as-you-go record of **real measured results** (Instruments allocations,
memory footprint, frame timing, BenchmarkHost numbers) — as opposed to `COMPARISON.md`,
which is a static qualitative architecture comparison. This doc exists to track how the
numbers actually move over time and to stop us re-litigating "was this always broken or
did we regress it" from memory.

No fixed schema — newest entries at the top, each dated, each citing the bead it came from
so the full investigation is one `bd show` away.

---

## How to reproduce (reference)

BenchmarkHost launch arguments (`BenchmarkHost/Sources/LaunchArguments.swift`):

```
--runtime <velocityui|swiftui-lazyvstack|swiftui-list|uicollectionview|texture>
--scenario <cold|warm|replay|slow-scroll-first-three-items|max-fling-no-gray>
--velocity-profile <slow|medium|max>
--items <N>            # default 100 — item count fed to BenchmarkDataset.generate(count:)
--duration <seconds>   # default 30 — measured-pass length
--live                 # skip the picker, drop straight into one runtime's hand-scroll HUD
--touch-speed <N>      # amplify direct-drag portion of a hand scroll, e.g. 3 = 3x
```

Scenario notes:
- `warm` — process warm, content fresh, no pre-visit. Decodes happen throughout; not the
  scenario to use for a clean zero-alloc read (see ah8.4 below for why).
- `replay` — the only scenario with an uncaptured warm-up pass over a **bounded, identical**
  ~30-item range before the measured pass. This is the scenario that actually isolates
  "does this settle to a steady state" from "is this still ramping." Use this one for any
  zero-alloc / convergence question.
- `--live` — manual/hand-scroll via the LiveMetricsHUD. Good for exploratory "does this feel
  right" and long paused sessions; noisy/bursty compared to the scripted profiles because
  mouse-drag-in-Simulator input isn't evenly paced — don't use it as the final word on a
  byte-count contract, but it's the best tool for "let it run a long time with pauses and
  watch what happens."

Instruments: Allocations template, "Created & Persistent" stat, filter the call tree search
box to `updateVisibleCells` to isolate the scroll-path subtree from unrelated growth (image
cache fill, etc.) — see the 2026-08-06 entry below for what happens if you don't.

---

## 2026-08-07 — VelocityUI-9lq: prepareForReuse retest + long paused hand-scroll

- **Pool convergence, real usage pattern**: `--runtime velocityui --live --items 1000`,
  scrolled ~1 minute with pauses. `RenderCell.init` stops firing after ~10s; flat afterward
  for the rest of the minute. No memory growth once converged. This closes out the "is a
  ~95-cell pool high-water-mark from bursty manual scrolling okay" question raised
  2026-08-06 (see below) — confirmed one-time burst-driven ramp, not a leak.
- **Footprint comparison, same live session**: VelocityUI caps at **~80 MiB**, Texture caps
  at **~400 MiB** for the equivalent workload. (VelocityUI's ~80 MiB matches the
  NSCache 64 MB `totalCostLimit` + ~15-20 MB baseline figure independently derived in
  VelocityUI-zgs/ah8.4 below — consistent across a static-image-focused live session.)
- **`RenderCell.prepareForReuse(for:)` retest**: **576 bytes** persistent (down from the
  original 3.53 KB / 2 baseline in the bead). Root cause still not pinned to a specific
  line — leading theory remains a one-time CoreAnimation/objc-runtime lazy-init cost
  (`CATransaction`'s per-thread transaction stack), not a per-recycle leak, since the byte
  count doesn't scale with call volume. `dequeue`/`returnToPool`'s dictionary-churn source
  (confirmed real, `_NativeDictionary.setValue -> _copyOrMoveAndResize`) was fixed this
  session — `subscript.modify`-based in-place mutation replaces
  `removeValue(forKey:)`-then-reinsert. **Still open**: a `--scenario replay` run (the one
  with the pre-visit warm-up over an identical bounded range) would give the decisive
  answer on whether the remaining 576 B is a real leak or an unavoidable one-time floor.

Tracked in: VelocityUI-9lq (open).

---

## 2026-08-06 — VelocityUI-9lq: dequeue/returnToPool dict-churn fix

- Diagnosed `FeedScrollView.returnToPool(_:)`'s `_NativeDictionary.setValue ->
  _copyOrMoveAndResize` allocation (352 B / 6 events, from the parent bead's 3.88 KB / 8
  baseline) as a genuine per-recycle bug: `CellKind` has exactly one case, so `cellPools`
  bounced between 0 and 1 keys on every single dequeue/return (remove-then-conditionally-
  reinsert). Fixed by switching both `dequeue` and `returnToPool` to `subscript`-`_modify`
  in-place mutation (`cellPools[kind]?.popLast()` / `cellPools[kind, default: []].append`),
  which never removes the dictionary key on a hit.
- Ruled out two of the bead's three candidates for `prepareForReuse`'s residual: AnyHashable
  itemID boxing happens once at `flatten()`/table-build time, not per-recycle; and the
  `Set(fragments.map { $0.id })` reconcile candidate is physically impossible —that code
  lives in `RenderCell.applyLayout`, a different method that doesn't run until after
  `prepareForReuse` returns, and `prepareForReuse`'s signature doesn't even take `fragments`.
- Noted a methodology gap: the `warm` scenario used for the original Instruments evidence has
  no pre-visit warm-up pass (unlike `replay`), so a novel-item-ID-driven one-time cost can't
  be ruled out from that evidence alone — flagged `replay` as the decisive re-test (see
  2026-08-07 above for the result).
- **Manual-scroll pool "overflow" investigation**: a `--live` session (mouse-drag in
  Simulator) showed 95 `RenderCell.init` calls against only ~20 concurrently-live cells in a
  single generation window. Traced to: the mount loop only dequeues for `visRange` (strictly
  visible), while eviction uses the wider `keepRange` (visible + `prefetchBehindCount` 3 +
  `prefetchAheadCount` 10 ≈ 15-18 cells) — and the pool has no shrink-on-idle, so its size is
  the historical high-water mark of the burstiest frame-to-frame jump ever seen. Mouse-drag
  input in Simulator is jerky/uneven compared to a real finger, which plausibly explains why
  a manual session needed far more concurrent cells at some single moment than the ~20-cell
  steady-state estimate. Confirmed non-issue by the 2026-08-07 long-session retest above.

Tracked in: VelocityUI-9lq (open), follow-up from VelocityUI-ksh.

---

## 2026-08-02 — VelocityUI-ah8.4: device validation, Q5 all pass

Physical device, `velocityui × replay × {slow,medium,max} × {idiomatic,raw}`, 1 run each
(`results/2026-08-02T20-15-31Z`):

| Metric | Result |
|---|---|
| Q5 (net alloc/frame ≤ 16 KB, tasks == 0) | **6/6 ✅** |
| Net alloc/frame | **-91 to +808 B/frame** (0.5–5% of budget; negative = eviction) |
| No-decode invariant (gray/thumbnail transitions on replay's cache-hit pass) | 0 / 0, held every run |
| Task spawns on scroll path | 0 |
| Frame time | p50 = p99 = 16.67 ms (60fps), 0 hitches |
| Burst-mean metric (`avgAllocDeltaPerFrameBytes`) | still 2.1–2.5 MB even on these zero-decode passes |

The burst-mean number staying MB-scale with net ≈ 0 and zero decodes is the final
confirmation that the *old* metric (mean size of a positive `phys_footprint` step) was
structurally the wrong tool — CA texture-staging churn produces MB-scale footprint steps
that have nothing to do with net per-frame allocation. **Net-delta
(`(last-first)/(samples-1)`) is the metric that actually reflects the Phase 1 zero-alloc
contract.** This resolved VelocityUI-zgs's "worst of the field" framing below — that
comparison was comparing step-size granularity across runtimes, not actual allocation rate.

Tracked in: VelocityUI-ah8.4 (closed).

---

## 2026-07-27 → 2026-07-28 — VelocityUI-zgs: 2-3 MB/frame → near-zero

**Pre-fix** (`results/2026-07-27T08-17-47Z`, simulator, burst-mean metric — later understood
to be an artifact, see ah8.4 above, but the cross-runtime comparison is still a useful
snapshot of relative decode-burst size):

| Runtime | avgAllocDeltaPerFrameBytes |
|---|---|
| VelocityUI | 2.1–3.3 MB/frame (all 12 combos) |
| UICollectionView | ~780 KB |
| SwiftUI `List` | ~810 KB |
| SwiftUI `LazyVStack` | ~580 KB |

Root-caused to: 3× decode scale ceiling (should be 2×), a redundant CGContext scratch blit
even when the thumbnail was already correctly formatted, no scratch-buffer pooling across
decodes, and a `Set.union + Array.sorted` allocation in `refineKnownFrames` while any index
was unrefined.

**Fixes A+B1+B2+C** (decode scale ceiling 3.0→2.0, thumbnail-already-BGRA8888 fast path,
pooled decode scratch buffer, `refineKnownFrames` scratch-array reuse) landed in `19ea3ca`.

**Post-fix** (`results/2026-07-27T21-38-49Z`):
- Thumbnail→image transitions: 86–143/run → **exactly 3–4 cold (first screenful,
  deterministic) / 0 warm**, across all 36 runs.
- Peak RSS: **74–87 MB** — the NSCache 64 MB `totalCostLimit` finally filling (faster 2×
  decodes) + ~15-20 MB baseline. Eviction-bounded, not a leak. (Matches the ~80 MiB figure
  independently observed in the 2026-08-07 live-session entry above.)
- Burst-mean metric still read 1.9–2.6 MB and printed ❌ on Q5 — this is what triggered the
  ah8.4 investigation above, which showed the fixes were real and the *metric* was wrong,
  not the library.

Tracked in: VelocityUI-zgs (closed).

---

## 2026-08-03 — VelocityUI-ksh: cell pool ~90% miss rate → converges

**Pre-fix** (`--scenario warm --velocity-profile medium --duration 30 --items 200`,
post-ramp Instruments selection):

| Symbol | Bytes | Count |
|---|---|---|
| `FeedScrollView.dequeue(kind:)` | 15.36 KB | 145 calls |
| ↳ `RenderCell.init(kind:)` (pool miss) | 10.98 KB | **131 calls — 90% miss rate** |
| `RenderCell.applyLayout(_:synchronousContent:)` | 4.67 KB | 37 calls |
| ↳ fresh `CALayer.__allocating_init()` | 3.44 KB | 20 calls |

Root cause: `rebuildFrames` seeded every unmeasured row with the flat `estimatedItemHeight`
(300pt) placeholder regardless of aspect ratio, so under sustained fast scroll with no
warm-up, every first mount triggered a large refine-delta that shifted not-yet-visited rows
by up to ~450pt — pulling a different `visRange` into view next frame than steady-state
would, forcing `RenderCell.init` on far more dequeues than the true working-range window.

**Fix**: synchronous `intrinsicHeight(for:width:)` (mirrors `measureNode`'s `.image` case,
`width / aspectRatio`) used before falling back to the flat estimate — zero-alloc, no decode,
respects the scroll-path invariants. Secondary fix: cross-item recycle now retains and clears
existing sublayers instead of removing them, so `applyLayout` reuses them instead of
CALayer-allocating fresh ones on every cross-item mount (this is what the "20/37 CALayer"
row above was — same bead, same fix).

**Post-fix**: Generation-B evidence — `updateVisibleCells` subtree down to **3.88 KB / 8**
persistent (this became VelocityUI-9lq's starting point, above). Time Profiler at max
velocity: main-thread utilization ≈ **3.6% of wall-clock** (1.09s busy / 30s wall — note the
Weight% column in Instruments' per-thread view is share-of-total-CPU-time-across-threads, NOT
share-of-wall-clock; easy to misread as 14.6%), well under the 15% budget.

Tracked in: VelocityUI-ksh (closed), parent of VelocityUI-9lq.

---

## 2026-08-0x — VelocityUI-1gw: "Color Copied Images" root cause

Initially misattributed to VelocityUI-ksh's pool-miss churn (hypothesis disproven — the wash
was **sustained even on fully static, at-rest cells**, ruling out scroll-churn/reassignment-
frequency theories).

**Root cause**: `ImageNormaliser.swift`'s decode-time redraw `CGContext` used
`CGColorSpaceCreateDeviceRGB()` — untagged. Core Animation can't recognize an untagged
DeviceRGB image as already matching the display's working color space, so it color-matches
(copies) the layer's contents on **every composite**, not just first paint. Since
`cornerRadius > 0` always takes the redraw path (per the "round at decode time via CGContext
clip" hard rule), this hit essentially the whole feed.

**Fix**: explicit `CGColorSpace(name: CGColorSpace.sRGB)` in both `ImageNormaliser`'s redraw
context and `PlaceholderDecode`'s BlurHash `makeCGImage`.

**Pre-fix RSS**: 164 MB / 184 MB peak (bead's acceptance criteria baseline). Post-fix
on-device re-verification (flash-then-clean Instruments capture, RSS drop) was flagged as
still pending the user's manual run as of the last update — **check before citing a post-fix
number for this one**.

Tracked in: VelocityUI-1gw (closed, code fix; device re-verification was the open item at
close time).

---

## OPEN — VelocityUI-x8l: ~80fps ceiling on ProMotion (need 120fps)

Hand-scroll (`--live --touch-speed 3`) on ProMotion hardware pegs at **~80fps** regardless of
drag speed/amplification — ruling out finger speed as the bottleneck. ~80fps ≈ 12.5ms/frame:
comfortably under 60Hz's 16.7ms budget, but well over 120Hz's 8.3ms budget.

2026-08-06 update: `INFOPLIST_KEY_CADisableMinimumFrameDurationOnPhone` (previously misspelled
as `INFOPLIST_KEY_CADisableMinimumFrameDuration` in both `BenchmarkHost/project.yml` and
`DeviceTestHost/project.yml`) fixed and confirmed present in the regenerated `.xcodeproj`s.
Re-tested — **still capped at ~80fps, no change**. Refined root-cause direction: the plist key
is a permission *gate*, not a *request* — CoreAnimation infers the granted frame rate from
active `CADisplayLink.preferredFrameRateRange` hinting or a CAAnimation frame-rate hint,
neither of which VelocityUI currently sets explicitly. Next step per the bead: investigate
explicit `preferredFrameRateRange` wiring.

Possible relation to VelocityUI-ksh's pool-miss churn flagged but not confirmed either way —
needs its own Time Profiler pass under this specific moderate-load scenario.

Tracked in: VelocityUI-x8l (open).

---

## Cross-runtime architecture comparison (qualitative, not measured)

See `COMPARISON.md` for the full structural comparison (rendering model, layout thread,
scroll path, image/text/GIF/video pipelines, memory model) against SwiftUI
`LazyVStack`/`List` and Texture (`AsyncDisplayKit`). This log is for numbers; that doc is for
"why" the numbers come out the way they do.

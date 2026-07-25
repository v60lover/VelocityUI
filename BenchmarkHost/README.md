# BenchmarkHost

Multi-runtime scroll benchmark comparing SwiftUI (LazyVStack + List), UICollectionView, Texture, and VelocityUI.

## Setup

`BenchmarkHost.xcodeproj` is a **generated build artifact** — it is not checked in
(see `.gitignore`). The checked-in source of truth is `project.yml`
([XcodeGen](https://github.com/yonaskolb/XcodeGen) spec). Generate the project
before opening it in Xcode or building from the command line:

```sh
brew install xcodegen   # once
cd BenchmarkHost
xcodegen generate
```

Re-run `xcodegen generate` any time a file is added, removed, or moved under
`Sources/` or `Tests/` — the project picks it up automatically, no manual
pbxproj editing. `scripts/run.sh` and `scripts/ci.sh` regenerate it for you.

## Launch Arguments

| Argument | Values | Default |
|----------|--------|---------|
| `--runtime` | `velocityui`, `swiftui-lazyvstack`, `swiftui-list`, `uicollectionview`, `texture` | (picker shown) |
| `--image-mode` | `idiomatic`, `same-pipeline` | `idiomatic` |
| `--velocity-profile` | `slow`, `medium`, `max` | `medium` |
| `--scenario` | `cold`, `warm`, `slow-scroll-first-three-items` | `warm` |
| `--items` | integer | `100` |

## Scenarios

| Scenario | Description |
|----------|-------------|
| `cold` | Fresh process, no warm-up, measurement starts immediately |
| `warm` | 1s process-settle delay; first 1s of frames discarded from stats |
| `slow-scroll-first-three-items` | Slow-read (300 pt/s) scroll from offset 0. Measures gray→image transitions for the first 3 items. VelocityUI should show `grayToImageTransitionCount = 0` once prefetch lands. Run with `--scenario slow-scroll-first-three-items --runtime velocityui`. |

## Known Asymmetries

The following asymmetries cannot be removed by the harness and must be accounted for when interpreting results:

- **SwiftUI List** performs its own diffing on each update; UICollectionView and VelocityUI do not.
- **UICollectionView prefetch** is enabled by default; Texture's prefetch is controlled by ASRangeController with different heuristics.
- **Idiomatic image pipeline** differs per runtime: Nuke (SwiftUI/UICollectionView), PINRemoteImage (Texture), ImageActor (VelocityUI). Same-pipeline mode removes this variable.
- **ProMotion (120Hz)** devices may show different hitches-per-1000-frames vs 60Hz devices; always report device SKU with results.
- Simulator numbers are diagnostic only — not reportable.

# BenchmarkHost

Multi-runtime scroll benchmark comparing SwiftUI (LazyVStack + List), UICollectionView, Texture, and VelocityUI.

## Launch Arguments

| Argument | Values | Default |
|----------|--------|---------|
| `--runtime` | `velocityui`, `swiftui-lazyvstack`, `swiftui-list`, `uicollectionview`, `texture` | (picker shown) |
| `--image-mode` | `idiomatic`, `same-pipeline` | `idiomatic` |
| `--velocity-profile` | `slow`, `medium`, `max` | `medium` |
| `--scenario` | `cold`, `warm` | `warm` |
| `--items` | integer | `100` |

## Known Asymmetries

The following asymmetries cannot be removed by the harness and must be accounted for when interpreting results:

- **SwiftUI List** performs its own diffing on each update; UICollectionView and VelocityUI do not.
- **UICollectionView prefetch** is enabled by default; Texture's prefetch is controlled by ASRangeController with different heuristics.
- **Idiomatic image pipeline** differs per runtime: Nuke (SwiftUI/UICollectionView), PINRemoteImage (Texture), ImageActor (VelocityUI). Same-pipeline mode removes this variable.
- **ProMotion (120Hz)** devices may show different hitches-per-1000-frames vs 60Hz devices; always report device SKU with results.
- Simulator numbers are diagnostic only — not reportable.

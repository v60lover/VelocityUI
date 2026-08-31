// BenchmarkDataset.swift

import Foundation

enum BenchmarkDataset {
    static func generate(count: Int, seed: UInt64 = 0) -> [BenchmarkItem] {
        var rng = LCG(state: seed)
        return (0..<count).map { i in
            let aspectRatios: [Double] = [0.5, 0.75, 1.0, 1.33, 1.5, 2.0]
            let cornerRadii: [Double] = [0, 8, 16]

            let aspectRatio = aspectRatios[Int(rng.next() % UInt64(aspectRatios.count))]
            let cornerRadius = cornerRadii[Int(rng.next() % UInt64(cornerRadii.count))]

            // 800px wide covers full-width display up to 2× retina on most iPhones.
            // picsum.photos has been down (503s, VelocityUI benchmark outage) — pull a fixed
            // photo straight from Unsplash's CDN instead, sized/cropped via imgix query params.
            let pxWidth = 800
            let pxHeight = max(1, Int(Double(pxWidth) / aspectRatio))
            let photoID = BenchmarkPhotoIDs.table[i % BenchmarkPhotoIDs.table.count]
            let url = URL(string: "https://images.unsplash.com/photo-\(photoID)?w=\(pxWidth)&h=\(pxHeight)&fit=crop&q=80")!

            return BenchmarkItem(
                id: i,
                imageURL: url,
                aspectRatio: aspectRatio,
                cornerRadius: cornerRadius,
                caption: "",
                thumbnailData: nil,
                // Real per-item BlurHash (VelocityUI-9x0), keyed by id — see
                // PrecomputedBlurHashes.swift's header for how/why this table exists and
                // how to regenerate it. Wraps past the table's own bound rather than
                // crashing on a larger --items override; still per-item-derived data below
                // that bound, reused (not cycled-from-a-tiny-sample) above it.
                blurHash: PrecomputedBlurHashes.table[i % PrecomputedBlurHashes.table.count]
            )
        }
    }
}

private struct LCG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// BenchmarkDataset.swift

import Foundation

enum BenchmarkDataset {
    /// Known-valid canonical BlurHash strings (public examples from https://blurha.sh).
    /// Producer-side BlurHash ENCODING is out of scope for VelocityUI (VelocityUI-1su.3) —
    /// items cycle through this fixed set instead of encoding one per photo.
    private static let sampleBlurHashes = [
        "L6PZfSi_.AyE_3t7t7R**0o#DgR4",
        "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
        "LKO2?U%2Tw=w]~RBVZRi};RPxuwH",
        "L5H2EC=PM+yV0g-mq.wG9c010J}I",
        "LGF5]+Yk^6#M@-5c,1J5@[or[Q6.",
        "LlMF%n00%#MwS|WCWEM{R*bbWBbH",
    ]

    static func generate(count: Int, seed: UInt64 = 0) -> [BenchmarkItem] {
        var rng = LCG(state: seed)
        return (0..<count).map { i in
            let aspectRatios: [Double] = [0.5, 0.75, 1.0, 1.33, 1.5, 2.0]
            let cornerRadii: [Double] = [0, 8, 16]

            let aspectRatio = aspectRatios[Int(rng.next() % UInt64(aspectRatios.count))]
            let cornerRadius = cornerRadii[Int(rng.next() % UInt64(cornerRadii.count))]

            // 800px wide covers full-width display up to 2× retina on most iPhones.
            // Picsum serves deterministic photos by seed.
            let pxWidth = 800
            let pxHeight = max(1, Int(Double(pxWidth) / aspectRatio))
            let url = URL(string: "https://picsum.photos/seed/\(i)/\(pxWidth)/\(pxHeight)")!

            return BenchmarkItem(
                id: i,
                imageURL: url,
                aspectRatio: aspectRatio,
                cornerRadius: cornerRadius,
                caption: "",
                thumbnailData: nil,
                blurHash: sampleBlurHashes[i % sampleBlurHashes.count]
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

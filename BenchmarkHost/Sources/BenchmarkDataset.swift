// BenchmarkDataset.swift

import Foundation

enum BenchmarkDataset {
    static func generate(count: Int, seed: UInt64 = 0) -> [BenchmarkItem] {
        var rng = LCG(state: seed)
        return (0..<count).map { i in
            let aspectRatios: [Double] = [0.5, 0.75, 1.0, 1.33, 1.5, 2.0]
            let cornerRadii: [Double] = [0, 8, 16]
            let captions = ["", "Short caption.", "Medium length caption text here.", "A longer caption that spans multiple words and gives a better sense of real feed content."]

            let aspectRatio = aspectRatios[Int(rng.next() % UInt64(aspectRatios.count))]
            let cornerRadius = cornerRadii[Int(rng.next() % UInt64(cornerRadii.count))]
            let caption = captions[Int(rng.next() % UInt64(captions.count))]
            let url = URL(string: "benchmark://fixture/\(i)")!

            return BenchmarkItem(
                id: i,
                imageURL: url,
                aspectRatio: aspectRatio,
                cornerRadius: cornerRadius,
                caption: caption
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

// RawImageSource.swift

import Foundation

// Lazy-fetches image bytes from the item's URL and caches them in memory.
// All non-VelocityUI runtimes share this single actor so they bypass their idiomatic loaders
// (Nuke pipeline, PINRemoteImage, LazyImage) and decode from the same raw data —
// simulating a naive hand-rolled implementation with no resizing, caching, or coalescing.
actor RawImageSource: ImageSource {
    private var cache: [Int: Data] = [:]

    func imageData(for item: BenchmarkItem) async -> Data? {
        if let cached = cache[item.id] { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: item.imageURL) else { return nil }
        cache[item.id] = data
        return data
    }
}

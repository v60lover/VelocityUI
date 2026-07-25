// IdiomaticImageSource.swift

import Foundation
import Nuke

struct IdiomaticImageSource: ImageSource {
    // Fallback for UIKit runtimes (UICollectionView, Texture) that use imageData(for:).
    // SwiftUI cells in LazyVStack/List use LazyImage directly and bypass this path.
    func imageData(for item: BenchmarkItem) async -> Data? {
        guard let (data, _) = try? await ImagePipeline.benchmark.data(for: item.imageURL) else { return nil }
        return data
    }
}

// MARK: - Shared benchmark pipeline

extension ImagePipeline {
    // Standard Nuke pipeline with URL cache. Used by IdiomaticImageSource and LazyImage
    // cells via .pipeline(.benchmark). No-singletons rule applies to VelocityUI library
    // types — this is a BenchmarkHost-owned extension on Nuke's type.
    static let benchmark: ImagePipeline = {
        ImagePipeline(configuration: .withURLCache)
    }()
}

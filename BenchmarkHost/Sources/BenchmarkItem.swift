// BenchmarkItem.swift

import Foundation

struct BenchmarkItem: Sendable, Identifiable, Equatable {
    let id: Int
    let imageURL: URL
    let aspectRatio: Double
    let cornerRadius: Double
    let caption: String
    /// Small (~4KB) JPEG bytes for a decode-guaranteed first paint (VelocityUI-1su.3).
    /// nil in the standard synthetic dataset — producer-side thumbnail encoding is out
    /// of scope for VelocityUI; see BenchmarkDataset.
    let thumbnailData: Data?
    /// Compact BlurHash string for a decode-guaranteed first paint (VelocityUI-1su.3).
    let blurHash: String?

    static let thumbWidth: CGFloat = 80
    var thumbHeight: CGFloat { BenchmarkItem.thumbWidth / CGFloat(aspectRatio) }
    var placeholderHue: Double { Double(id % 12) / 12 }
}

// BenchmarkItem.swift

import Foundation

struct BenchmarkItem: Sendable, Identifiable, Equatable {
    let id: Int
    let imageURL: URL
    let aspectRatio: Double
    let cornerRadius: Double
    let caption: String

    static let thumbWidth: CGFloat = 80
    var thumbHeight: CGFloat { BenchmarkItem.thumbWidth / CGFloat(aspectRatio) }
    var placeholderHue: Double { Double(id % 12) / 12 }
}

// ImageSource.swift

import Foundation

protocol ImageSource: Sendable {
    func imageData(for item: BenchmarkItem) async -> Data?
}

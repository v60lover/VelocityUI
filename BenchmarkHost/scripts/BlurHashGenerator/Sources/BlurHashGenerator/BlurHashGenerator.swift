// BlurHashGenerator.swift

import CoreGraphics
import Foundation
import ImageIO
import VelocityUI

/// Offline dev tool (VelocityUI-9x0) — see Package.swift header for the full rationale.
/// Downloads BenchmarkDataset's picsum.photos seed images and encodes each into a real
/// per-item BlurHash via VelocityUI.encodeBlurHash, then writes a checked-in Swift table
/// consumed by BenchmarkDataset.generate().
@main
struct BlurHashGenerator {
    /// Must cover BenchmarkHost's default --items (100) with headroom for manual overrides.
    /// BenchmarkDataset.generate() wraps (id % table.count) for ids beyond this bound, so a
    /// larger --items run degrades to reusing entries rather than crashing — still real,
    /// per-item-derived data, just reused past the table's own size.
    static let itemCount = 256
    static let maxConcurrentDownloads = 8
    static let fetchPixelSize = 400

    /// Known-valid canonical BlurHash (public example from https://blurha.sh) — used only as
    /// a last-resort fallback for a seed whose download/encode failed, so one flaky fetch
    /// can't abort the whole table.
    static let fallbackBlurHash = "L6PZfSi_.AyE_3t7t7R**0o#DgR4"

    static func main() async throws {
        var hashesByID = [Int: String]()
        var failedIDs = [Int]()

        await withTaskGroup(of: (Int, String?).self) { group in
            var nextID = 0
            func spawn(_ id: Int) {
                group.addTask {
                    do {
                        let image = try await fetchImage(seed: id, pixelSize: fetchPixelSize)
                        guard let hash = encodeBlurHash(image, componentsX: 4, componentsY: 3) else {
                            return (id, nil)
                        }
                        return (id, hash)
                    } catch {
                        FileHandle.standardError.write(Data("seed \(id) failed: \(error)\n".utf8))
                        return (id, nil)
                    }
                }
            }

            let initialBatch = min(maxConcurrentDownloads, itemCount)
            for id in 0..<initialBatch { spawn(id) }
            nextID = initialBatch

            while let (id, hash) = await group.next() {
                if let hash {
                    hashesByID[id] = hash
                } else {
                    failedIDs.append(id)
                }
                if nextID < itemCount {
                    spawn(nextID)
                    nextID += 1
                }
            }
        }

        if !failedIDs.isEmpty {
            let sorted = failedIDs.sorted()
            FileHandle.standardError.write(Data(
                "\(sorted.count)/\(itemCount) seeds failed, using fallback hash: \(sorted)\n".utf8
            ))
        }

        let table = (0..<itemCount).map { hashesByID[$0] ?? fallbackBlurHash }
        try writeTable(table, to: outputURL())
        print("Wrote \(table.count) BlurHashes to \(outputURL().path)")
    }

    private static func fetchImage(seed: Int, pixelSize: Int) async throws -> CGImage {
        let url = URL(string: "https://picsum.photos/seed/\(seed)/\(pixelSize)/\(pixelSize)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeneratorError.badResponse(seed: seed)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw GeneratorError.decodeFailed(seed: seed)
        }
        return image
    }

    /// BlurHashGenerator.swift lives at BlurHashGenerator/Sources/BlurHashGenerator/ — five
    /// levels up from this file is scripts/'s parent, BenchmarkHost/.
    private static func outputURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BlurHashGenerator/Sources/BlurHashGenerator
            .deletingLastPathComponent() // BlurHashGenerator/Sources
            .deletingLastPathComponent() // BlurHashGenerator (package root)
            .deletingLastPathComponent() // scripts
            .deletingLastPathComponent() // BenchmarkHost
            .appendingPathComponent("Sources/PrecomputedBlurHashes.swift")
    }

    private static func writeTable(_ table: [String], to url: URL) throws {
        var lines = [
            "// PrecomputedBlurHashes.swift",
            "//",
            "// GENERATED FILE — do not hand-edit. Produced by BlurHashGenerator",
            "// (BenchmarkHost/scripts/BlurHashGenerator) via VelocityUI's public",
            "// encodeBlurHash(_:componentsX:componentsY:) API (VelocityUI-9x0). Each entry is the",
            "// REAL BlurHash of BenchmarkDataset's picsum.photos seed-<id> image, not a cycled",
            "// sample — regenerate with:",
            "//   cd BenchmarkHost/scripts/BlurHashGenerator && swift run",
            "",
            "enum PrecomputedBlurHashes {",
            "    static let table: [String] = [",
        ]
        for hash in table {
            lines.append("        \"\(hash)\",")
        }
        lines.append("    ]")
        lines.append("}")
        lines.append("")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

enum GeneratorError: Error {
    case badResponse(seed: Int)
    case decodeFailed(seed: Int)
}

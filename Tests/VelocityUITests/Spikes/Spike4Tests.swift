// Spike4Tests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Spike 4: validates TextKit 2 measure == render within 1pt,
/// zero CATextLayer in source tree, concurrent rasterization is race-free,
/// and rendering is deterministic across two calls.
/// @MainActor: TextMeasurementContext created on main, rasterizeText is nonisolated.
@MainActor
final class Spike4Tests: XCTestCase {

    /// One-time settle window after the whole class finishes — exercises a withTaskGroup
    /// rasterizing 100 TextDescriptors concurrently. See VelocityUI-1su.6.
    nonisolated override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    // MARK: - Corpus

    private func makeCorpus() -> [TextDescriptor] {
        let contents: [String] = [
            "Hello",
            "The quick brown fox jumps over the lazy dog.",
            "Short.",
            String(repeating: "Longer wrapping text. ", count: 4),
            "Line 1\nLine 2\nLine 3",
            "مرحبا بالعالم",
            "日本語テキスト",
            "Emoji: 🚀🎯🔥💯",
            "UPPERCASE TEXT ONLY",
            "mixed CASE with digits 1234567890",
        ]
        return (0..<100).map { i in
            let size: CGFloat = 12 + CGFloat((i % 4) * 4)  // 12, 16, 20, 24
            return TextDescriptor(
                content: contents[i % contents.count],
                font: VFontDescriptor(size: size, weight: 0),
                color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                lineLimit: nil,
                lineBreakMode: 0,
                layoutHash: i,
                appearanceHash: 0
            )
        }
    }

    // MARK: - Helper: pixel-scan ink height

    /// Scans from the bottom of the image upward and returns the height (in pixels)
    /// of the last row that contains any non-transparent pixel. Returns 0 if fully
    /// transparent. CGImage row 0 = top, so scanning bottom-to-top finds the ink bottom.
    private func actualContentHeight(in image: CGImage) -> CGFloat {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue  // RGBA8888
              ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for row in stride(from: h - 1, through: 0, by: -1) {
            for col in 0..<w {
                let alpha = bytes[(row * w + col) * 4 + 3]
                if alpha > 0 { return CGFloat(row + 1) }
            }
        }
        return 0
    }

    // MARK: - Test 1: Measure == render within 1pt

    func testMeasureEqualsRenderWithin1pt() {
        let corpus = makeCorpus()
        let measureCtx = TextMeasurementContext()
        var failures = 0

        for (i, descriptor) in corpus.enumerated() {
            let measured = measureCtx.measure(descriptor, width: 320)
            guard measured.height > 0, measured.width > 0 else {
                XCTFail("Zero measurement at index \(i)"); continue
            }
            guard let image = rasterizeText(descriptor, size: measured) else {
                XCTFail("rasterizeText returned nil at index \(i)"); continue
            }
            let inkH = actualContentHeight(in: image)
            // ink must not overflow measured height by more than 1pt (scale=1 → 1px=1pt)
            if inkH > measured.height + 1 {
                failures += 1
                XCTFail("Index \(i) '\(descriptor.content.prefix(30))': ink \(inkH)pt > measured \(measured.height)pt + 1")
            }
        }
        print("[Spike4] measure≈render: \(corpus.count - failures)/\(corpus.count) passed")
    }

    // MARK: - Test 2: No CATextLayer in Sources

    func testNoCATextLayerInSources() {
        // Architecture mandates zero CATextLayer. Text must be rasterised to CGImage
        // via NSTextLayoutManager and assigned to plain CALayer.contents.
        let sourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Spikes/
            .deletingLastPathComponent()  // VelocityUITests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Sources")

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { XCTFail("Cannot enumerate Sources/"); return }

        var hits: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift",
                  let src = try? String(contentsOf: url, encoding: .utf8),
                  src.contains("CATextLayer") else { continue }
            hits.append(url.lastPathComponent)
        }
        XCTAssertTrue(hits.isEmpty,
            "CATextLayer found in: \(hits.joined(separator: ", ")). Use CGImage → CALayer.contents.")
    }

    // MARK: - Test 3: Concurrent rasterization is race-free

    func testConcurrentRasterizationRaceFree() async {
        let corpus = makeCorpus()
        let measureCtx = TextMeasurementContext()
        // Measure all sizes serially first (TextMeasurementContext is not safe to share concurrently)
        let sizes = corpus.map { measureCtx.measure($0, width: 320) }

        // rasterizeText is nonisolated — must survive concurrent calls
        let pairs: [(Int, Bool)] = await withTaskGroup(of: (Int, Bool).self) { group in
            for i in 0..<corpus.count {
                let desc = corpus[i]
                let size = sizes[i]
                group.addTask {
                    (i, rasterizeText(desc, size: size) != nil)
                }
            }
            var out = [(Int, Bool)]()
            for await p in group { out.append(p) }
            return out
        }

        let nils = pairs.filter { !$0.1 }
        XCTAssertTrue(nils.isEmpty,
            "rasterizeText returned nil for \(nils.count) descriptors under concurrent load")
        print("[Spike4] Concurrent rasterization: \(pairs.count) images, \(nils.count) nil")
    }

    // MARK: - Test 4: Rendering is deterministic (same input → same pixels)

    func testRenderingIsDeterministic() {
        let descriptor = TextDescriptor(
            content: "Determinism check: same descriptor → identical pixels each call.",
            font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: 999,
            appearanceHash: 0
        )
        let size = TextMeasurementContext().measure(descriptor, width: 320)
        guard size.width > 0, size.height > 0 else { XCTFail("Zero measurement"); return }

        guard let img1 = rasterizeText(descriptor, size: size),
              let img2 = rasterizeText(descriptor, size: size) else {
            XCTFail("rasterizeText returned nil"); return
        }
        XCTAssertEqual(img1.width, img2.width)
        XCTAssertEqual(img1.height, img2.height)

        // Render both into the same format for byte-level comparison
        let w = img1.width, h = img1.height
        func toBytes(_ img: CGImage) -> Data? {
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let ptr = ctx.data else { return nil }
            return Data(bytes: ptr, count: w * h * 4)
        }
        guard let d1 = toBytes(img1), let d2 = toBytes(img2) else {
            XCTFail("Cannot extract pixel data"); return
        }
        XCTAssertEqual(d1, d2, "Two rasterizations of the same descriptor must be pixel-identical")
    }
}
#endif

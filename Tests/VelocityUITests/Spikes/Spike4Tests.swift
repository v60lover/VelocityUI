// Spike4Tests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Spike 4: validates TextKit 2 measure == render within 1pt, zero CATextLayer in source tree,
/// concurrent rasterization is race-free, and rendering is deterministic across two calls.
/// `@MainActor`: TextMeasurementContext created on main, rasterizeText is nonisolated.
///
/// VelocityUI-ezo.2.9 extends the corpus to the full parity matrix: ZWJ emoji sequences and
/// dynamic-type variants (velocityui-prompt.md's Spike 4 spec), the attribute catalog (ezo.2.3),
/// line-break/truncation modes (ezo.2.4), and content-size categories (ezo.2.5). RTL
/// base-writing-direction (ezo.2.6) is NOT exercised — that bead is still open, so this corpus
/// only covers the glyph-level bidi that already worked (Arabic/Japanese strings below). Test 5
/// additionally proves parity holds for text inside a mixed text+image tree through the real
/// Phase 1 pipeline, not just isolated TextMeasurementContext/rasterizeText calls.
@MainActor
final class Spike4Tests: XCTestCase {

    /// One-time settle window after the whole class finishes — exercises a withTaskGroup
    /// rasterizing 100 TextDescriptors concurrently. See VelocityUI-1su.6.
    nonisolated override class func tearDown() {
        Thread.sleep(forTimeInterval: 1.0)
        super.tearDown()
    }

    // MARK: - Corpus

    /// Content-size categories cycled across the corpus — ezo.2.5 dynamic-type parity.
    /// `.unspecified` is included so the no-scaling path stays covered alongside scaling.
    private static let corpusCategories: [VContentSizeCategory] = [
        .unspecified, .extraSmall, .large, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityExtraExtraExtraLarge,
    ]

    /// NSLineBreakMode raw values cycled across the corpus — ezo.2.4 line-break parity.
    private static let corpusLineBreakModes: [Int] = [
        NSLineBreakMode.byWordWrapping.rawValue, NSLineBreakMode.byCharWrapping.rawValue,
        NSLineBreakMode.byClipping.rawValue, NSLineBreakMode.byTruncatingHead.rawValue,
        NSLineBreakMode.byTruncatingTail.rawValue, NSLineBreakMode.byTruncatingMiddle.rawValue,
    ]

    /// Font/attribute variant cycled across the corpus — ezo.2.3 attribute-catalog parity.
    /// Returns (font, underlineStyle, strikethroughStyle, kerning, lineSpacing).
    private func attributeVariant(_ i: Int) -> (VFontDescriptor, Int, Int, CGFloat, CGFloat) {
        let base = VFontDescriptor(size: 12 + CGFloat((i % 4) * 4), weight: 0)  // 12, 16, 20, 24
        switch i % 8 {
        case 0: return (base, 0, 0, 0, 0)
        case 1: return (base.italic, 0, 0, 0, 0)
        case 2: return (base.family("Georgia"), 0, 0, 0, 0)
        case 3: return (base, NSUnderlineStyle.single.rawValue, 0, 0, 0)
        case 4: return (base, 0, NSUnderlineStyle.single.rawValue, 0, 0)
        case 5: return (base, 0, 0, 2.5, 0)
        case 6: return (base, 0, 0, 0, 6)
        default: return (base.family("Georgia").italic, NSUnderlineStyle.single.rawValue, NSUnderlineStyle.single.rawValue, 2, 6)
        }
    }

    private func corpusColor(_ i: Int) -> VColorDescriptor {
        switch i % 3 {
        case 0: return .primary
        case 1: return VColorDescriptor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        default: return VColorDescriptor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)
        }
    }

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
            // ZWJ sequences — velocityui-prompt.md Spike 4 spec-required item, previously missing.
            "Family ZWJ: 👨‍👩‍👧‍👦",
            "Profession ZWJ: 👩‍💻 🧑‍🚀",
            "Rainbow flag ZWJ: 🏳️‍🌈",
            "Couple kiss ZWJ: 👨‍❤️‍💋‍👨",
        ]
        return (0..<100).map { i in
            let (font, underline, strikethrough, kerning, lineSpacing) = attributeVariant(i)
            let mode = Self.corpusLineBreakModes[i % Self.corpusLineBreakModes.count]
            let category = Self.corpusCategories[i % Self.corpusCategories.count]
            // Truncation coverage (ezo.2.4): every 3rd item gets a tight line limit paired
            // with content long enough to overflow it.
            let lineLimit: Int? = i % 3 == 0 ? 2 : nil
            return TextDescriptor(
                content: contents[i % contents.count],
                font: font,
                color: corpusColor(i),
                lineLimit: lineLimit,
                lineBreakMode: mode,
                underlineStyle: underline,
                strikethroughStyle: strikethrough,
                kerning: kerning,
                lineSpacing: lineSpacing,
                contentSizeCategory: category,
                layoutHash: i,
                appearanceHash: 0
            )
        }
    }

    /// Renders a TextDescriptor's key fields into a single line so a failing assertion names
    /// the exact descriptor — corpus-based tests no longer need to fail with just an index.
    private func describe(_ d: TextDescriptor, index: Int? = nil) -> String {
        var parts: [String] = []
        if let index { parts.append("index=\(index)") }
        parts.append("content='\(d.content.prefix(24))'")
        var font = "font=\(d.font.size)pt/w\(d.font.weight)"
        if let family = d.font.family { font += "/\(family)" }
        if d.font.traits.contains(.italic) { font += "/italic" }
        parts.append(font)
        parts.append("category=\(d.contentSizeCategory)")
        parts.append("lineBreakMode=\(d.lineBreakMode)")
        parts.append("lineLimit=\(String(describing: d.lineLimit))")
        if d.underlineStyle != 0 { parts.append("underline=\(d.underlineStyle)") }
        if d.strikethroughStyle != 0 { parts.append("strikethrough=\(d.strikethroughStyle)") }
        if d.kerning != 0 { parts.append("kerning=\(d.kerning)") }
        if d.lineSpacing != 0 { parts.append("lineSpacing=\(d.lineSpacing)") }
        return parts.joined(separator: " ")
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
                XCTFail("\(describe(descriptor, index: i)): ink \(inkH)pt > measured \(measured.height)pt + 1")
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

    // MARK: - Test 5: Mixed text + image Phase 1 stack (epic acceptance criterion)

    /// VelocityUI-ezo.2's epic acceptance criterion: Spike 4 parity must hold with text and
    /// image nodes mixed, on the real Phase 1 stack, not just the isolated
    /// TextMeasurementContext/rasterizeText calls above. Builds NodeTables interleaving `.image`
    /// and `.text` under a vstack, runs them through the real RenderPipeline -> WorkingRange, and
    /// reads back `CellEntry.fragments` — the exact structure FeedScrollView's scroll path
    /// consumes — rather than recomputing extractFragments itself. Each text fragment's frame
    /// must still satisfy the 1pt ink-height contract; each image fragment must be non-degenerate.
    func testMixedTextAndImageStackMaintainsParity() async {
        let corpus = makeCorpus()
        let pipeline = RenderPipeline()
        let width: CGFloat = 320
        let tableCount = 30

        func makeMixedTable(id: Int) -> NodeTable {
            let textA = corpus[id % corpus.count]
            let textB = corpus[(id + corpus.count / 2) % corpus.count]
            return NodeTable(
                itemID: id,
                nodes: [
                    .vstack(VStackDescriptor.test(alignment: 0, spacing: 4)),
                    .image(ImageDescriptor(
                        url: nil, aspectRatio: 1.5, contentMode: 0,
                        cornerRadius: 0, layoutHash: id, appearanceHash: 0
                    )),
                    .text(textA),
                    .image(ImageDescriptor(
                        url: nil, aspectRatio: 0.75, contentMode: 0,
                        cornerRadius: 0, layoutHash: id + 1, appearanceHash: 0
                    )),
                    .text(textB),
                ],
                parentIndices: [-1, 0, 0, 0, 0],
                layoutHash: id,
                appearanceHash: 0
            )
        }

        let tables = (0..<tableCount).map(makeMixedTable)
        let range = WorkingRange(capacity: tableCount)

        // Old default (ahead=60, behind=3) covered the full 30-row table from leadingIndex=0;
        // pass the full range directly now that the caller computes it explicitly.
        await pipeline.onIndexBoundary(
            warmRange: 0..<tables.count, leadingIndex: 0,
            workingRange: range, tables: tables, availableWidth: width, scale: 1)
        await pipeline.waitForCurrentPrefetch()

        var textFragmentCount = 0
        var imageFragmentCount = 0
        var failures = 0

        for tableIndex in tables.indices {
            guard let entry = range.entry(at: tableIndex) else {
                failures += 1
                XCTFail("table \(tableIndex): missing CellEntry after pipeline drain")
                continue
            }
            for fragment in entry.fragments {
                switch fragment.content {
                case .text(let descriptor):
                    textFragmentCount += 1
                    guard fragment.frame.width > 0, fragment.frame.height > 0 else {
                        failures += 1
                        XCTFail("table \(tableIndex) fragment \(fragment.id): \(describe(descriptor)) produced an empty frame in the mixed stack")
                        continue
                    }
                    guard let image = rasterizeText(descriptor, size: fragment.frame.size) else {
                        failures += 1
                        XCTFail("table \(tableIndex) fragment \(fragment.id): \(describe(descriptor)) rasterizeText returned nil in the mixed stack")
                        continue
                    }
                    let inkHeight = actualContentHeight(in: image)
                    if inkHeight > fragment.frame.height + 1 {
                        failures += 1
                        XCTFail("table \(tableIndex) fragment \(fragment.id): \(describe(descriptor)) ink \(inkHeight)pt > pipeline frame \(fragment.frame.height)pt + 1")
                    }
                case .image:
                    imageFragmentCount += 1
                    if fragment.frame.width <= 0 || fragment.frame.height <= 0 {
                        failures += 1
                        XCTFail("table \(tableIndex) fragment \(fragment.id): image fragment has a degenerate frame \(fragment.frame) in the mixed stack")
                    }
                case .codeBlockBackground, .table, .mathBlock, .geometry:
                    break
                }
            }
        }

        XCTAssertEqual(textFragmentCount, tableCount * 2, "expected 2 text fragments per mixed table")
        XCTAssertEqual(imageFragmentCount, tableCount * 2, "expected 2 image fragments per mixed table")
        print("[Spike4] mixed text+image stack: \(tableCount) tables, \(textFragmentCount) text fragments, \(imageFragmentCount) image fragments, \(failures) failures")
    }
}
#endif

// HotBlockRasterizerTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Acceptance tests for VelocityUI-x4q0's `HotBlockRasterizer`/`HotBlockRasterizerStore` — the
/// production stateful, cell-owned incremental text rasterizer and its per-`BlockKey` lifecycle
/// owner. Exercises the same shapes the VelocityUI-q87l spike validated
/// (`HotBlockRasterizerSpikeTests.swift`), against real production types instead of the spike's
/// probe.
///
/// Every assertion is count/pixel/exact-value based — never wall-clock (flakes on shared/loaded
/// hardware).
///
/// | Invariant (ledger's Testable criteria)                                          | Assertion |
/// |-----------------------------------------------------------------------------------|-----------|
/// | First call (no prior state) produces a full rasterize                            | `testFirstCall_ProducesFullRasterize_MatchingRasterizeText` |
/// | Per-token glyph-rasterized line count stays flat as the fence grows               | `testFlatRedrawnFragmentCount_CodeFenceStream`: self-calibrating equal-to-first-observed `_debugLastRedrawnFragmentCount`, per token-kind |
/// | Composite seam correct under a ligature-font + emoji-at-seam case                 | `testLigatureAndEmojiAtSeam`: pixel-identical to a fresh single-shot `rasterizeText` of the final string |
/// | Retained top region is cropped, not scaled, when stableTopY > 0                   | `testMultiFragmentBlit_GrowingLastLineMatchesGroundTruth`: pixel-identical to a fresh single-shot `rasterizeText` of the final string |
/// | `finish()` is `nil` before any append, returns the last composite after           | `testFinish_NilBeforeAppend_ReturnsLastCompositeAfter` |
/// | `HotBlockRasterizerStore.append` creates-then-reuses one entry per key            | `testStoreAppend_CreatesThenReusesEntryPerKey` |
/// | `finalize` returns `nil` for a missing key                                        | `testStoreFinalize_ReturnsNilForMissingKey` |
/// | `finalize` on a hash mismatch returns `nil` AND removes the entry                 | `testStoreFinalize_HashMismatch_ReturnsNilAndRemovesEntry` |
/// | `finalize` on a hash match returns the bitmap+size AND removes the entry          | `testStoreFinalize_HashMatch_ReturnsBitmapAndRemovesEntry` |
/// | `evict` tears down only the given keys                                            | `testStoreEvict_TearsDownOnlyGivenKeys` |
@MainActor
final class HotBlockRasterizerTests: XCTestCase {

    // MARK: - Fixtures

    /// Mirrors `HotBlockMeasurerTests.makeDescriptor` — layoutHash/appearanceHash are
    /// irrelevant to `HotBlockRasterizer`/`HotBlockMeasurer` (they compare individual
    /// `TextDescriptor` fields, never these hashes), so placeholder values are fine here.
    private func makeDescriptor(
        content: String,
        fontSize: CGFloat = 15,
        lineLimit: Int? = nil,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: VFontDescriptor(size: fontSize, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: lineLimit,
            lineBreakMode: lineBreakMode.rawValue,
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    /// Mirrors `BlockReuseTests.pixelBytes(of:)` / the spike's local `bytes(_:)` — decodes a
    /// `CGImage` into raw RGBA8 bytes for exact pixel comparison.
    private func pixelBytes(of image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        return Data(bytes: data, count: w * h * 4)
    }

    // MARK: - Acceptance: first call is a full rasterize matching rasterizeText

    /// `HotBlockRasterizer.append` on a fresh instance (no prior `image`) has no composite to
    /// build on, so it MUST fall to the full-`rasterizeText` branch — pixel-identical to a
    /// direct `rasterizeText` call at the same size/scale, not merely "close."
    func testFirstCall_ProducesFullRasterize_MatchingRasterizeText() {
        let rasterizer = HotBlockRasterizer()
        let descriptor = makeDescriptor(content: "hello world, this is the very first call")
        let width: CGFloat = 220
        let scale: CGFloat = 2

        let (height, image) = rasterizer.append(descriptor, width: width, scale: scale)
        guard let image else { return XCTFail("expected a non-nil image on the first append call") }
        XCTAssertGreaterThan(height, 0, "precondition: non-empty content must measure a positive height")

        guard let groundTruth = rasterizeText(descriptor, size: CGSize(width: width, height: height), scale: scale) else {
            return XCTFail("rasterizeText must succeed for the ground-truth comparison")
        }

        XCTAssertEqual(image.width, groundTruth.width, "first-call image width must match a direct rasterizeText call")
        XCTAssertEqual(image.height, groundTruth.height, "first-call image height must match a direct rasterizeText call")
        XCTAssertEqual(pixelBytes(of: image), pixelBytes(of: groundTruth),
            "first call has no prior composite to build on, so it must be pixel-identical to a full rasterizeText pass")

        // Supporting smoke check: the debug counter must reflect "this was a full rasterize"
        // (every fragment counted as redrawn), not a composite with a stable prefix.
        XCTAssertGreaterThan(rasterizer._debugLastRedrawnFragmentCount, 0,
            "first call must report at least one redrawn fragment (the whole block)")
    }

    // MARK: - Acceptance: flat per-token redrawn-fragment count (direction (b) core claim)

    /// Streams 60 "sealed paragraph" tokens (occasionally forcing an internal wrap) into ONE
    /// production `HotBlockRasterizer`, mirroring `HotBlockRasterizerSpikeTests
    /// .testStableOriginAndFlatReLayout_CodeFenceStream`'s pattern, reading
    /// `_debugLastRedrawnFragmentCount` after each call. Flatness is self-calibrating: the first
    /// wrapping token and first plain token (after call 1, which always full-rasterizes) each
    /// establish a constant, and every LATER token of that kind must match it EXACTLY — this only
    /// fails on a genuine cost regression, not an arbitrarily-tight guessed ceiling.
    func testFlatRedrawnFragmentCount_CodeFenceStream() {
        let rasterizer = HotBlockRasterizer()
        let width: CGFloat = 220
        let tokenCount = 60
        var accumulated = ""

        var wrappingConstant: Int?
        var plainConstant: Int?

        for t in 0..<tokenCount {
            let isWrapping = t % 5 == 0
            let body = isWrapping
                ? "line \(t) with enough words to wrap once inside this narrow column "
                : "line \(t) short"
            accumulated += body + "\n"

            let descriptor = makeDescriptor(content: accumulated)
            _ = rasterizer.append(descriptor, width: width, scale: 1)

            // The very first call always takes the full-rasterize branch (no prior composite to
            // redraw against) — it isn't part of either kind's steady-state constant.
            guard t > 0 else { continue }

            let count = rasterizer._debugLastRedrawnFragmentCount
            if isWrapping {
                if let expected = wrappingConstant {
                    XCTAssertEqual(count, expected, "token \(t): wrapping-token redrawn-fragment count drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    wrappingConstant = count
                }
            } else {
                if let expected = plainConstant {
                    XCTAssertEqual(count, expected, "token \(t): plain-token redrawn-fragment count drifted from the first-observed constant \(expected) — cost is changing with N")
                } else {
                    plainConstant = count
                }
            }
        }

        XCTAssertNotNil(wrappingConstant, "precondition: at least one later wrapping token must have run")
        XCTAssertNotNil(plainConstant, "precondition: at least one later plain token must have run")
        print("[x4q0] code-fence stream: \(tokenCount) tokens. Observed flat constants — wrapping: \(wrappingConstant ?? -1), plain: \(plainConstant ?? -1)")
    }

    // MARK: - Acceptance: composite seam correct under ligature font + emoji-at-seam

    /// Mirrors `HotBlockRasterizerSpikeTests.testLigatureAndEmojiAtSeam` (same width, font size,
    /// streamed parts — a ZWJ emoji sequence appended right after a still-open paragraph), but
    /// against the PRODUCTION `HotBlockRasterizer.append`/`finish()` instead of the spike's private
    /// `IncrementalTextProbe`. Confirms the composited final image is pixel-identical to a fresh
    /// single-shot `rasterizeText` of the same string — a mismatch means the seam left a
    /// stale/partial glyph (research §6.5).
    ///
    /// `HotBlockRasterizer.append` takes the block's FULL accumulated content each call (delta is
    /// computed internally by `HotBlockMeasurer`), unlike the spike's probe which took a raw delta —
    /// so each call below passes the ACCUMULATED string, not just the new part.
    func testLigatureAndEmojiAtSeam() {
        let width: CGFloat = 260
        let fontSize: CGFloat = 16
        let rasterizer = HotBlockRasterizer()

        let parts = ["The team waffle ", "shipped: ", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"] // family emoji ZWJ sequence
        var accumulated = ""
        var lastHeight: CGFloat = 0
        var lastImage: CGImage?

        for part in parts {
            accumulated += part
            let descriptor = makeDescriptor(content: accumulated, fontSize: fontSize)
            let (height, image) = rasterizer.append(descriptor, width: width, scale: 1)
            lastHeight = height
            lastImage = image
        }

        guard let composite = lastImage else {
            return XCTFail("expected a composite image after streaming all parts")
        }

        let finalDescriptor = makeDescriptor(content: accumulated, fontSize: fontSize)
        let groundTruthSize = CGSize(width: width, height: lastHeight)
        guard let groundTruth = rasterizeText(finalDescriptor, size: groundTruthSize) else {
            return XCTFail("rasterizeText returned nil for the ground-truth comparison")
        }

        XCTAssertEqual(composite.width, groundTruth.width, "composite/ground-truth width mismatch")
        XCTAssertEqual(composite.height, groundTruth.height, "composite/ground-truth height mismatch")
        XCTAssertEqual(pixelBytes(of: composite), pixelBytes(of: groundTruth),
            "incrementally-composited image must be pixel-identical to a single-shot rasterize of the same final string — a mismatch means the seam left a stale/partial glyph")

        // Also confirm finish() hands back exactly this same composite (no extra rasterize).
        guard let final = rasterizer.finish() else {
            return XCTFail("finish() must return a value once at least one successful append happened")
        }
        XCTAssertEqual(final.size, groundTruthSize)
        XCTAssertEqual(pixelBytes(of: final.image), pixelBytes(of: composite), "finish() must hand back exactly the last composite, not a fresh rasterize")

        print("[x4q0] ligature/emoji seam: composite (\(composite.width)x\(composite.height)) pixel-identical to ground truth")
    }

    // MARK: - Acceptance: finish() nil before append, returns last composite after

    func testFinish_NilBeforeAppend_ReturnsLastCompositeAfter() {
        let rasterizer = HotBlockRasterizer()
        XCTAssertNil(rasterizer.finish(), "finish() before any append call must return nil")

        let d1 = makeDescriptor(content: "first line\n")
        let (h1, img1) = rasterizer.append(d1, width: 200, scale: 1)
        guard let img1 else { return XCTFail("expected a non-nil image after the first append") }
        guard let f1 = rasterizer.finish() else { return XCTFail("finish() must be non-nil after a successful append") }
        XCTAssertEqual(f1.size, CGSize(width: 200, height: h1))
        XCTAssertEqual(pixelBytes(of: f1.image), pixelBytes(of: img1))

        let d2 = makeDescriptor(content: "first line\nsecond line grows the block\n")
        let (h2, img2) = rasterizer.append(d2, width: 200, scale: 1)
        guard let img2 else { return XCTFail("expected a non-nil image after the second append") }
        guard let f2 = rasterizer.finish() else { return XCTFail("finish() must be non-nil after the second append") }
        XCTAssertEqual(f2.size, CGSize(width: 200, height: h2))
        XCTAssertEqual(pixelBytes(of: f2.image), pixelBytes(of: img2))
        XCTAssertNotEqual(pixelBytes(of: f2.image), pixelBytes(of: f1.image),
            "finish() after growth must reflect the NEW composite, not the stale first one")
    }

    // MARK: - Acceptance: multi-fragment crop/blit correctness (stableTopY > 0)

    /// Grows the LAST line of a 3-line block across three `append` calls (no wraps, fragment count
    /// stays exactly 3, height never changes). On calls 2 and 3, `stableCount = previousFragmentCount
    /// - 1 = 2` and `stableTopY` is strictly LESS than `previousImage`'s full height — the composite
    /// branch's `stableTopY > 0` blit crops a real sub-region, not the whole image. Neither
    /// `testFlatRedrawnFragmentCount_CodeFenceStream` (trailing fragment always empty) nor
    /// `testLigatureAndEmojiAtSeam` (single wrapped line) exercises this shape.
    ///
    /// Compares against a fresh single-shot `rasterizeText` rather than a second incrementally-driven
    /// rasterizer — a squash bug reproduces identically on both sides of a same-code-path comparison,
    /// so only a from-scratch ground truth catches it.
    func testMultiFragmentBlit_GrowingLastLineMatchesGroundTruth() {
        let rasterizer = HotBlockRasterizer()
        let width: CGFloat = 400
        let scale: CGFloat = 2

        let parts = [
            "line one\nline two\nline three",
            "line one\nline two\nline three grows",
            "line one\nline two\nline three grows more and more"
        ]

        var lastHeight: CGFloat = 0
        var lastImage: CGImage?
        var finalContent = ""

        for content in parts {
            finalContent = content
            let descriptor = makeDescriptor(content: content)
            let (height, image) = rasterizer.append(descriptor, width: width, scale: scale)
            lastHeight = height
            lastImage = image
        }

        guard let composite = lastImage else {
            return XCTFail("expected a composite image after streaming all parts")
        }

        let finalDescriptor = makeDescriptor(content: finalContent)
        guard let groundTruth = rasterizeText(finalDescriptor, size: CGSize(width: width, height: lastHeight), scale: scale) else {
            return XCTFail("rasterizeText returned nil for the ground-truth comparison")
        }

        XCTAssertEqual(composite.width, groundTruth.width, "composite/ground-truth width mismatch")
        XCTAssertEqual(composite.height, groundTruth.height, "composite/ground-truth height mismatch")
        XCTAssertEqual(pixelBytes(of: composite), pixelBytes(of: groundTruth),
            "the retained top region (lines one and two) must be cropped verbatim into the new composite, not scaled to fit stableTopY — a squash bug here reproduces identically on both sides of a same-code-path comparison, so this asserts against a fresh single-shot rasterizeText instead")
    }

    // MARK: - HotBlockRasterizerStore: creates-then-reuses an entry per key

    /// Black-box proxy for "creates-then-reuses": a Store that (incorrectly) built a fresh
    /// `HotBlockRasterizer` per call for the same key would still converge on a pixel-CORRECT final
    /// image (`append` always gets the FULL accumulated content, and the non-append fallback does a
    /// correct if less efficient full re-measure). So pixel/CGImage identity alone can't distinguish
    /// "reused" from "recreated" — only redrawn-fragment COST can, and the Store doesn't surface
    /// `_debugLastRedrawnFragmentCount` (`entries` is `private`, unreachable via `@testable`).
    ///
    /// What IS testable black-box: the Store's per-key entry, driven through two calls, must behave
    /// EXACTLY like a directly-driven `HotBlockRasterizer` fed the same two-call sequence — proving
    /// the public per-key contract holds even though reuse-vs-recreate isn't independently observable.
    func testStoreAppend_CreatesThenReusesEntryPerKey() {
        let store = HotBlockRasterizerStore()
        let key = BlockKey(itemID: "msg", index: 0)
        let width: CGFloat = 200

        let d1 = makeDescriptor(content: "hello")
        let (h1, img1) = store.append(d1, width: width, scale: 1, contentHash: 1, for: key)
        XCTAssertNotNil(img1, "first append for a new key must create an entry and produce an image")

        let d2 = makeDescriptor(content: "hello world, this grew")
        let (h2, img2) = store.append(d2, width: width, scale: 1, contentHash: 2, for: key)
        XCTAssertNotNil(img2, "second append for the SAME key must succeed using the existing entry")
        XCTAssertGreaterThanOrEqual(h2, h1, "growing content for the same key must extend, not restart, the accumulated height")

        guard let sealed = store.finalize(key, expectedContentHash: 2) else {
            return XCTFail("finalize must succeed for a matching hash")
        }

        let direct = HotBlockRasterizer()
        _ = direct.append(d1, width: width, scale: 1)
        _ = direct.append(d2, width: width, scale: 1)
        guard let directFinal = direct.finish() else {
            return XCTFail("directly-driven rasterizer must also produce a final image")
        }

        XCTAssertEqual(sealed.size, directFinal.size, "the store's per-key entry must behave like one continuously-driven rasterizer")
        XCTAssertEqual(pixelBytes(of: sealed.image), pixelBytes(of: directFinal.image),
            "the store's per-key entry, across two calls, must be pixel-identical to a directly-driven rasterizer fed the identical two-call sequence")
    }

    // MARK: - HotBlockRasterizerStore: finalize

    func testStoreFinalize_ReturnsNilForMissingKey() {
        let store = HotBlockRasterizerStore()
        let key = BlockKey(itemID: "msg", index: 0)
        XCTAssertNil(store.finalize(key, expectedContentHash: 0), "finalize on a key that was never appended to must return nil")
    }

    /// A mismatched hash means the block grew further within the same round it closed — the
    /// entry must ALWAYS be removed (match or mismatch alike), never linger stale. Verified via
    /// a second `finalize` call on the same key: if the first call's mismatch had left the entry
    /// in place, the second call (even with the SAME wrong hash) would still find it; instead it
    /// must also return nil, proving the entry is genuinely gone.
    func testStoreFinalize_HashMismatch_ReturnsNilAndRemovesEntry() {
        let store = HotBlockRasterizerStore()
        let key = BlockKey(itemID: "msg", index: 0)
        let descriptor = makeDescriptor(content: "still growing")
        _ = store.append(descriptor, width: 200, scale: 1, contentHash: 1, for: key)

        XCTAssertNil(store.finalize(key, expectedContentHash: 999), "finalize with a mismatched hash must return nil")
        XCTAssertNil(store.finalize(key, expectedContentHash: 1), "a second finalize call (even with the ORIGINAL matching hash) must also return nil — the mismatch already removed the entry")
    }

    /// A matching hash returns the cached bitmap+size AND removes the entry (ARC then drops the
    /// `HotBlockRasterizer`/`HotBlockMeasurer`/live `NSTextLayoutManager` once no other reference
    /// exists). Verified the same way: a second `finalize` call for the same key must return nil.
    func testStoreFinalize_HashMatch_ReturnsBitmapAndRemovesEntry() {
        let store = HotBlockRasterizerStore()
        let key = BlockKey(itemID: "msg", index: 0)
        let descriptor = makeDescriptor(content: "closing content")
        let (height, image) = store.append(descriptor, width: 200, scale: 1, contentHash: 7, for: key)
        XCTAssertNotNil(image)

        guard let sealed = store.finalize(key, expectedContentHash: 7) else {
            return XCTFail("finalize with a matching hash must return the cached bitmap+size")
        }
        XCTAssertEqual(sealed.size, CGSize(width: 200, height: height))
        XCTAssertEqual(pixelBytes(of: sealed.image), pixelBytes(of: image!))

        XCTAssertNil(store.finalize(key, expectedContentHash: 7), "a second finalize call for the same key must return nil — proves the entry is really gone, not just logically sealed")
    }

    // MARK: - HotBlockRasterizerStore: evict

    func testStoreEvict_TearsDownOnlyGivenKeys() {
        let store = HotBlockRasterizerStore()
        let keyA = BlockKey(itemID: "msg", index: 0)
        let keyB = BlockKey(itemID: "msg", index: 1)

        _ = store.append(makeDescriptor(content: "block A content"), width: 200, scale: 1, contentHash: 1, for: keyA)
        _ = store.append(makeDescriptor(content: "block B content"), width: 200, scale: 1, contentHash: 2, for: keyB)

        store.evict([keyA])

        XCTAssertNil(store.finalize(keyA, expectedContentHash: 1), "keyA was evicted — finalize must return nil even with the correct hash")
        XCTAssertNotNil(store.finalize(keyB, expectedContentHash: 2), "keyB was NOT evicted — finalize must still succeed for it")
    }

    // MARK: - VelocityUI-fzvf.4: sealed-block raster stability with inline runs present

    /// Raster-layer counterpart to `IncrementalMarkdownParserTests
    /// .testSealedBlocks_StableRunsAcrossLaterAppends_WithInlineMarkup`. A sealed block carrying
    /// bold/code/link inline runs must keep producing the exact same rasterized bitmap after a
    /// long, unrelated stream of further markdown appends below it — not merely the same
    /// `TextDescriptor` fields, but pixel-identical output when independently rasterized.
    func testSealedBlockDescriptor_WithInlineRuns_ProducesByteIdenticalRasterAcrossAppends() {
        var parser = IncrementalMarkdownParser()
        parser.append("A **bold** word, `inline code`, and a [link](https://example.com).\n\n")
        XCTAssertEqual(parser.frontier, 1)

        guard case .text(let descriptorBefore) = parser.blockList(itemID: "msg", width: 300)[0].fragment.content else {
            return XCTFail("sealed block must render as a .text fragment")
        }
        XCTAssertGreaterThan(descriptorBefore.runs.count, 1, "precondition: the sealed block must actually carry multiple inline runs")

        parser.append(
            "Second **paragraph** with `more code`.\n\n# Heading\n\n```\ncode\n```\n\n"
            + "- item with *emphasis*\n\nmore text with a [link](https://other.example)"
        )

        guard case .text(let descriptorAfter) = parser.blockList(itemID: "msg", width: 300)[0].fragment.content else {
            return XCTFail("still-sealed block must still render as a .text fragment")
        }

        XCTAssertEqual(descriptorBefore.content, descriptorAfter.content, "sealed descriptor content must not change")
        XCTAssertEqual(descriptorBefore.runs, descriptorAfter.runs, "sealed descriptor's inline runs must not change")
        XCTAssertEqual(descriptorBefore.layoutHash, descriptorAfter.layoutHash, "sealed descriptor's layoutHash must not change")
        XCTAssertEqual(descriptorBefore.appearanceHash, descriptorAfter.appearanceHash, "sealed descriptor's appearanceHash must not change")

        let width: CGFloat = 300
        let (heightBefore, imageBefore) = HotBlockRasterizer().append(descriptorBefore, width: width, scale: 2)
        let (heightAfter, imageAfter) = HotBlockRasterizer().append(descriptorAfter, width: width, scale: 2)
        guard let imageBefore, let imageAfter else {
            return XCTFail("both independent rasterize calls must succeed")
        }
        XCTAssertEqual(heightBefore, heightAfter, "identical descriptors must measure to the identical height")
        XCTAssertEqual(imageBefore.width, imageAfter.width)
        XCTAssertEqual(imageBefore.height, imageAfter.height)
        XCTAssertEqual(pixelBytes(of: imageBefore), pixelBytes(of: imageAfter),
            "a sealed block carrying inline runs must rasterize to byte-identical output before and after unrelated content appends below it")
    }
}
#endif

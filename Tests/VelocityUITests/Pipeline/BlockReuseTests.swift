// BlockReuseTests.swift

import XCTest
import Foundation
import CoreGraphics
@testable import VelocityUI

/// Covers VelocityUI-0wi (hybrid reuse Phase A): the pure block model, freeze state, per-block
/// diff, and reuseDecision.
///
/// - Pure sections (Block/BlockKey/reuseDecision/diff/freeze via an injected spy) run WITHOUT
///   UIKit — `measure`/`rasterize` are injected closures, never the real
///   `TextMeasurementContext`/`rasterizeText`, so call-count assertions run on plain `swift test`.
/// - The trailing `#if canImport(UIKit)` section reproduces VelocityUI-6qd's anti-jank trend
///   through the real production types (not the spike's ad hoc dictionaries) — only
///   compiles/runs on a UIKit host (DeviceTestHost).
final class BlockReuseTests: XCTestCase {

    // MARK: - Fixture builders

    private func contentHash(_ content: String) -> Int {
        var hasher = Hasher()
        hasher.combine(content)
        return hasher.finalize()
    }

    private func textDescriptor(_ content: String) -> TextDescriptor {
        let hash = contentHash(content)
        return TextDescriptor(
            content: content,
            font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: nil,
            lineBreakMode: 0,
            layoutHash: hash,
            appearanceHash: hash
        )
    }

    private func textFragment(index: Int, content: String, width: CGFloat = 300) -> Fragment {
        Fragment(id: index, content: .text(textDescriptor(content)), frame: CGRect(x: 0, y: 0, width: width, height: 20))
    }

    private func textBlock(itemID: String = "msg", index: Int, content: String, width: CGFloat = 300) -> Block {
        let fragment = textFragment(index: index, content: content, width: width)
        return Block(key: BlockKey(itemID: itemID, index: index), fragment: fragment, layout: ResolvedLayout(totalFrame: fragment.frame))
    }

    private func imageBlock(itemID: String = "msg", index: Int, hash: Int) -> Block {
        let desc = ImageDescriptor(url: nil, aspectRatio: 1, contentMode: 0, cornerRadius: 0, layoutHash: hash, appearanceHash: hash)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let fragment = Fragment(id: index, content: .image(desc), frame: frame)
        return Block(key: BlockKey(itemID: itemID, index: index), fragment: fragment, layout: ResolvedLayout(totalFrame: frame))
    }

    private func geometryBlock(itemID: String = "msg", index: Int) -> Block {
        let frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        let fragment = Fragment(id: index, content: .geometry, frame: frame)
        return Block(key: BlockKey(itemID: itemID, index: index), fragment: fragment, layout: ResolvedLayout(totalFrame: frame))
    }

    /// Renders a real CGImage without UIKit (pure CoreGraphics) so the freeze-state spy below
    /// can hand back a genuine bitmap on plain `swift test`.
    fileprivate static func makeFakeCGImage(width: Int, height: Int) -> CGImage {
        let w = max(1, width), h = max(1, height)
        let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Re-renders a CGImage into a fixed premultiplied byte buffer for byte-level equality —
    /// same technique HybridReuseSpikeTests.pixelBytes(of:) uses (pure CoreGraphics, no UIKit).
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

    // MARK: - Spy (no UIKit — proves call-count assertions run without linking it)

    /// Internal (not `private`) so `IncrementalMarkdownParserTests` can reuse this exact spy for
    /// its own call-count assertions instead of inventing a parallel one.
    final class MeasureRasterizeSpy {
        private(set) var measureCallCount = 0
        private(set) var rasterizeCallCount = 0
        private(set) var measuredContents: [String] = []

        func measure(_ descriptor: TextDescriptor, width: CGFloat) -> CGSize {
            measureCallCount += 1
            measuredContents.append(descriptor.content)
            return CGSize(width: width, height: CGFloat(max(1, descriptor.content.count)))
        }

        func rasterize(_ descriptor: TextDescriptor, size: CGSize, scale: CGFloat) -> CGImage? {
            rasterizeCallCount += 1
            return BlockReuseTests.makeFakeCGImage(width: Int(size.width), height: Int(size.height))
        }
    }

    // MARK: - Acceptance 1: Block/BlockKey/FreezeState/BlockDiff wrap existing vocabulary

    func testBlock_WrapsTextFragmentAndResolvedLayout() {
        let fragment = textFragment(index: 0, content: "hello")
        let layout = ResolvedLayout(totalFrame: fragment.frame)
        let block = Block(key: BlockKey(itemID: "msg", index: 0), fragment: fragment, layout: layout)

        guard case .text(let descriptor) = block.fragment.content else {
            return XCTFail("Block must wrap the ORIGINAL FragmentContent.text case, not a parallel enum")
        }
        XCTAssertEqual(descriptor.content, "hello")
        XCTAssertEqual(block.layout.totalFrame, layout.totalFrame)
        XCTAssertEqual(block.width, fragment.frame.width)
    }

    func testBlock_WrapsImageAndGeometryFragmentContent_NoParallelEnum() {
        let image = imageBlock(index: 0, hash: 5)
        guard case .image = image.fragment.content else {
            return XCTFail("Block must wrap FragmentContent.image directly")
        }
        let geometry = geometryBlock(index: 1)
        guard case .geometry = geometry.fragment.content else {
            return XCTFail("Block must wrap FragmentContent.geometry directly")
        }
    }

    func testBlock_ContentHash_ReflectsDescriptorHashes_GeometryIsConstant() {
        let a = textBlock(index: 0, content: "same")
        let b = textBlock(index: 0, content: "same")
        XCTAssertEqual(a.contentHash, b.contentHash, "Equal text content must produce equal contentHash")

        let c = textBlock(index: 0, content: "different")
        XCTAssertNotEqual(a.contentHash, c.contentHash, "Different text content must produce different contentHash")

        let g1 = geometryBlock(index: 2)
        let g2 = geometryBlock(index: 3)
        XCTAssertEqual(g1.contentHash, g2.contentHash, "Geometry blocks carry no descriptor to hash — always diff-equivalent")
    }

    func testBlockKey_IdentityIgnoresContent() {
        let key = BlockKey(itemID: "msg", index: 0)
        let a = Block(key: key, fragment: textFragment(index: 0, content: "v1"), layout: .placeholder)
        let b = Block(key: key, fragment: textFragment(index: 0, content: "v2, much longer than v1"), layout: .placeholder)
        XCTAssertEqual(a.key, b.key, "BlockKey identity persists across content growth — it is not content-derived")
        XCTAssertNotEqual(a.contentHash, b.contentHash, "...but contentHash still tracks the content change")
    }

    // MARK: - Acceptance 2: reuseDecision

    func testReuseDecision_SameID_ReturnsInPlace() {
        XCTAssertEqual(reuseDecision(oldID: "msg-1", newID: "msg-1"), .inPlace)
    }

    func testReuseDecision_DifferentID_ReturnsPool() {
        XCTAssertEqual(reuseDecision(oldID: "msg-1", newID: "msg-2"), .pool)
    }

    func testReuseDecision_NilOldID_ReturnsPool() {
        let oldID: String? = nil
        XCTAssertEqual(reuseDecision(oldID: oldID, newID: "msg-1"), .pool)
    }

    func testReuseDecision_ComposesWithAnyHashableItemID() {
        // NodeTable.itemID is AnyHashable, not a concrete type — reuseDecision must compose
        // directly with that vocabulary (it is generic over Hashable, not AnyHashable-specific).
        let old: AnyHashable = "msg-1"
        XCTAssertEqual(reuseDecision(oldID: old, newID: AnyHashable("msg-1")), .inPlace)
        XCTAssertEqual(reuseDecision(oldID: old, newID: AnyHashable("msg-2")), .pool)
    }

    func testReuseDecision_ScrollFeedNeverProducesInPlace() {
        // A pure scroll/image feed: every new visible id differs from whatever occupied the
        // slot before — reuseDecision must always return .pool for that pattern.
        let slotHistory: [String] = ["a", "b", "c", "d"]
        for i in 1..<slotHistory.count {
            XCTAssertEqual(reuseDecision(oldID: slotHistory[i - 1], newID: slotHistory[i]), .pool)
        }
    }

    // MARK: - Acceptance 3: diff (VelocityUI-k8qe generalized this to split at a `frontier`
    // argument instead of hard-coding "only previous.count-1 can be hot" — see BlockDiff.swift's
    // doc. `frontier: new.count - 1` reproduces the original single-hot-tail model exactly.)

    func testDiff_AllBlocksSealedAndIdentical_AllUnchanged() {
        let previous = [textBlock(index: 0, content: "a"), textBlock(index: 1, content: "b")]
        let new = [textBlock(index: 0, content: "a"), textBlock(index: 1, content: "b")]
        let d = diff(previous: previous, new: new, frontier: new.count)
        XCTAssertEqual(d.unchanged, [0, 1])
        XCTAssertEqual(d.sealedChanged, [])
        XCTAssertEqual(d.volatile, new.count..<new.count, "frontier == new.count means the volatile range is empty")
    }

    func testDiff_TrailingBlockAtFrontier_ReportsVolatile() {
        let previous = [textBlock(index: 0, content: "frozen"), textBlock(index: 1, content: "grow")]
        let new = [textBlock(index: 0, content: "frozen"), textBlock(index: 1, content: "growing more")]
        let d = diff(previous: previous, new: new, frontier: new.count - 1)
        XCTAssertEqual(d.unchanged, [0])
        XCTAssertEqual(d.sealedChanged, [])
        XCTAssertEqual(d.volatile, 1..<2)
    }

    func testDiff_NewBlockSpawnedBeforeFrontier_DetectsSealedChanged() {
        let previous = [textBlock(index: 0, content: "frozen"), textBlock(index: 1, content: "final content")]
        let new = [
            textBlock(index: 0, content: "frozen"),
            textBlock(index: 1, content: "final content, now closed out"),
            textBlock(index: 2, content: ""),
        ]
        let d = diff(previous: previous, new: new, frontier: new.count - 1)
        XCTAssertEqual(d.unchanged, [0])
        XCTAssertEqual(d.sealedChanged, [1])
        XCTAssertEqual(d.volatile, 2..<3)
    }

    func testDiff_SealedBlockChanges_ReportedAsSealedChangedNotUnchanged() {
        // The sealed prefix [0, frontier) IS still compared against `previous` (unlike the hot
        // region, which is never compared at all) — an out-of-model edit to already-sealed
        // content must still be caught, not silently classified as unchanged.
        let previous = [textBlock(index: 0, content: "a"), textBlock(index: 1, content: "b")]
        let new = [textBlock(index: 0, content: "a-EDITED"), textBlock(index: 1, content: "b")]
        let d = diff(previous: previous, new: new, frontier: new.count)
        XCTAssertEqual(d.unchanged, [1], "Index 1 (truly unchanged) must still be reported")
        XCTAssertEqual(d.sealedChanged, [0], "Index 0 differing must be reported, not silently trusted as unchanged")
    }

    func testDiff_FrontierZero_EverythingVolatileEvenIfIdentical() {
        // frontier 0 means nothing is sealed yet — the hot region is never compared/trusted for
        // reuse, so even byte-identical content must stay volatile (always re-rendered), never
        // frozen. This is the sealed/hot contract itself, not an edge-case bug.
        let previous = [textBlock(index: 0, content: "a")]
        let new = [textBlock(index: 0, content: "a")]
        let d = diff(previous: previous, new: new, frontier: 0)
        XCTAssertEqual(d.unchanged, [])
        XCTAssertEqual(d.sealedChanged, [])
        XCTAssertEqual(d.volatile, 0..<1)
    }

    // MARK: - T1: volatile region block-COUNT changes across a diff step (grow / shrink)

    /// The volatile region can gain blocks in one step (a paragraph re-segments into a multi-item
    /// list) — `diff` must still report `volatile == frontier..<new.count` and classify the
    /// stable sealed prefix correctly, even though `new.count != previous.count`.
    func testDiff_VolatileRegionGrows_ParagraphToListInOneStep() {
        let previous = [
            textBlock(index: 0, content: "sealed zero"),
            textBlock(index: 1, content: "sealed one"),
            textBlock(index: 2, content: "a paragraph that will become a list"),
        ]
        let new = [
            textBlock(index: 0, content: "sealed zero"),
            textBlock(index: 1, content: "sealed one"),
            textBlock(index: 2, content: "- item one"),
            textBlock(index: 3, content: "- item two"),
        ]
        let frontier = 2
        let d = diff(previous: previous, new: new, frontier: frontier)

        XCTAssertEqual(d.unchanged, [0, 1], "the stable sealed prefix must be reported unchanged")
        XCTAssertEqual(d.sealedChanged, [])
        XCTAssertEqual(d.volatile, frontier..<new.count,
            "volatile must span the new, LARGER tail — split is by frontier, not by a fixed count")
        XCTAssertEqual(d.volatile.count, 2, "the volatile region grew from 1 block to 2")
    }

    /// The volatile region can also lose blocks in one step (a two-row table collapses into a
    /// single paragraph) — same split-at-frontier contract, shrink direction. Also exercises a
    /// sealed-prefix block that genuinely changed (`sealedChanged`), alongside one that didn't
    /// (`unchanged`), to prove the sealed-prefix classification is independent of what happens to
    /// the volatile region's block count.
    func testDiff_VolatileRegionShrinks_TableToParagraphInOneStep() {
        let previous = [
            textBlock(index: 0, content: "sealed zero"),
            textBlock(index: 1, content: "sealed one OLD"),
            textBlock(index: 2, content: "| a | b |"),
            textBlock(index: 3, content: "| 1 | 2 |"),
        ]
        let new = [
            textBlock(index: 0, content: "sealed zero"),
            textBlock(index: 1, content: "sealed one NEW"),
            textBlock(index: 2, content: "actually just a paragraph now"),
        ]
        let frontier = 2
        let d = diff(previous: previous, new: new, frontier: frontier)

        XCTAssertEqual(d.unchanged, [0], "index 0 is genuinely unchanged")
        XCTAssertEqual(d.sealedChanged, [1], "index 1 differs from previous and must be reported sealedChanged")
        XCTAssertEqual(d.volatile, frontier..<new.count,
            "volatile must span the new, SMALLER tail — split is by frontier, not by a fixed count")
        XCTAssertEqual(d.volatile.count, 1, "the volatile region shrank from 2 blocks to 1")
    }

    // MARK: - Acceptance 3 (freeze): measures + rasterizes exactly once, caches under BlockKey

    func testFreeze_FirstCall_MeasuresAndRasterizesExactlyOnce() {
        let spy = MeasureRasterizeSpy()
        var cache: [BlockKey: FreezeState] = [:]
        let block = textBlock(index: 0, content: "hello world")

        let state = freeze(block, scale: 2, cache: &cache, measure: spy.measure, rasterize: spy.rasterize)

        XCTAssertEqual(spy.measureCallCount, 1)
        XCTAssertEqual(spy.rasterizeCallCount, 1)
        guard case .frozen = state else { return XCTFail("Expected .frozen after a successful freeze") }
        guard case .frozen = cache[block.key] else { return XCTFail("freeze must cache the result under block.key") }
    }

    func testFreeze_SecondCallSameKey_DoesNotRecompute() {
        let spy = MeasureRasterizeSpy()
        var cache: [BlockKey: FreezeState] = [:]
        let block = textBlock(index: 0, content: "hello world")

        let first = freeze(block, scale: 2, cache: &cache, measure: spy.measure, rasterize: spy.rasterize)
        let second = freeze(block, scale: 2, cache: &cache, measure: spy.measure, rasterize: spy.rasterize)

        XCTAssertEqual(spy.measureCallCount, 1, "A second freeze of an already-frozen key must not re-measure")
        XCTAssertEqual(spy.rasterizeCallCount, 1, "A second freeze of an already-frozen key must not re-rasterize")

        guard case .frozen(let size1, let bitmap1) = first, case .frozen(let size2, let bitmap2) = second else {
            return XCTFail("Both calls must return .frozen")
        }
        XCTAssertEqual(size1, size2)
        XCTAssertTrue(bitmap1 === bitmap2, "The cached bitmap must be the SAME instance, not a re-render")
    }

    // MARK: - Acceptance 4: diff + freeze integration — zero-recompute, sealedChanged-once, LB4

    /// Drives `diff`/`freeze` the way the bind site does: freeze exactly `d.sealedChanged`
    /// (everything in `d.volatile`, including the current trailing block, is never frozen — by
    /// construction it always lies at/after `frontier`, which the caller below always passes as
    /// `new.count - 1`, the trailing index). Mirrors VelocityUI-6qd's block-freeze model exactly,
    /// now through the production Block/BlockKey/FreezeState/diff/freeze types instead of the
    /// spike's ad hoc dictionaries.
    @discardableResult
    private func applyDiffFreezing(
        diff d: BlockDiff,
        new: [Block],
        scale: CGFloat,
        cache: inout [BlockKey: FreezeState],
        spy: MeasureRasterizeSpy
    ) -> BlockDiff {
        for i in d.sealedChanged {
            freeze(new[i], scale: scale, cache: &cache, measure: spy.measure, rasterize: spy.rasterize)
        }
        return d
    }

    func testDiffFreeze_UnchangedZeroCalls_SealedChangedRecomputes_VolatileNeverCached() {
        let spy = MeasureRasterizeSpy()
        var cache: [BlockKey: FreezeState] = [:]

        // Round 1: block0 completes and block1 spawns — block0 must be frozen this round.
        var previous = [textBlock(index: 0, content: "")]
        var new: [Block] = [textBlock(index: 0, content: "block zero final content"), textBlock(index: 1, content: "")]
        var d = diff(previous: previous, new: new, frontier: new.count - 1)
        applyDiffFreezing(diff: d, new: new, scale: 2, cache: &cache, spy: spy)
        XCTAssertEqual(spy.measureCallCount, 1)
        XCTAssertEqual(spy.rasterizeCallCount, 1)
        guard case .frozen = cache[new[0].key] else { return XCTFail("block0 must be frozen after round 1") }

        // Round 2: block0 unchanged (must be ZERO additional calls); block1 grows — it is
        // volatile (at the frontier) and recomputes on the caller's own measurement path, but it
        // is still trailing so it must NOT be cached by this helper.
        previous = new
        new = [previous[0], textBlock(index: 1, content: "growing")]
        d = diff(previous: previous, new: new, frontier: new.count - 1)
        XCTAssertEqual(d.unchanged, [0])
        XCTAssertEqual(d.volatile, 1..<2)
        applyDiffFreezing(diff: d, new: new, scale: 2, cache: &cache, spy: spy)
        XCTAssertEqual(spy.measureCallCount, 1, "block0 is unchanged — ZERO additional measure calls")
        XCTAssertEqual(spy.rasterizeCallCount, 1, "block0 is unchanged — ZERO additional rasterize calls")
        XCTAssertNil(cache[new[1].key], "block1 is still the trailing block — must not be cached yet")

        // Round 3: block1 completes and block2 spawns — block1 must now be frozen (its ONE
        // freeze call); block0 remains untouched.
        previous = new
        new = [previous[0], textBlock(index: 1, content: "growing, now complete"), textBlock(index: 2, content: "")]
        d = diff(previous: previous, new: new, frontier: new.count - 1)
        XCTAssertEqual(d.unchanged, [0])
        XCTAssertEqual(d.sealedChanged, [1])
        XCTAssertEqual(d.volatile, 2..<3)
        applyDiffFreezing(diff: d, new: new, scale: 2, cache: &cache, spy: spy)
        XCTAssertEqual(spy.measureCallCount, 2, "block1 is measured exactly once, on the round it finalizes")
        XCTAssertEqual(spy.rasterizeCallCount, 2)
        guard case .frozen = cache[new[1].key] else { return XCTFail("block1 must be frozen after round 3") }
        XCTAssertNil(cache[new[2].key], "block2 is the new trailing block — must not be cached yet")
    }

    func testFrozenBlock_SizeAndBitmapInvariantAcrossRepeatedDiffs() {
        let spy = MeasureRasterizeSpy()
        var cache: [BlockKey: FreezeState] = [:]

        let previous0 = [textBlock(index: 0, content: "")]
        let new: [Block] = [textBlock(index: 0, content: "final"), textBlock(index: 1, content: "")]
        let d0 = diff(previous: previous0, new: new, frontier: new.count - 1)
        applyDiffFreezing(diff: d0, new: new, scale: 2, cache: &cache, spy: spy)

        guard case .frozen(let checkpointSize, let checkpointBitmap) = cache[new[0].key] else {
            return XCTFail("block0 must be frozen")
        }
        let checkpointBytes = pixelBytes(of: checkpointBitmap)

        // 5 more rounds: each round finalizes the current tail (giving it real content) and
        // spawns a fresh empty tail after it — block0's key is never touched again.
        var previous = new
        for round in 0..<5 {
            let tailIndex = previous.count - 1
            var next = previous
            next[tailIndex] = textBlock(index: tailIndex, content: "round \(round) final content")
            next.append(textBlock(index: tailIndex + 1, content: ""))
            let d = diff(previous: previous, new: next, frontier: next.count - 1)
            applyDiffFreezing(diff: d, new: next, scale: 2, cache: &cache, spy: spy)
            previous = next
        }

        guard case .frozen(let finalSize, let finalBitmap) = cache[BlockKey(itemID: "msg", index: 0)] else {
            return XCTFail("block0's frozen entry must still exist")
        }
        XCTAssertEqual(checkpointSize, finalSize, "A frozen block's size must be invariant across later diffs (LB4)")
        XCTAssertTrue(checkpointBitmap === finalBitmap, "A frozen block's bitmap must be the SAME instance — never re-rendered (LB4)")
        XCTAssertEqual(checkpointBytes, pixelBytes(of: finalBitmap), "Pixel bytes must be byte-identical across later diffs (LB4)")
    }

    // MARK: - Acceptance 6 (VelocityUI-ezo.2.5): content-size-category change invalidates frozen bitmaps

    /// A content-size-category change re-derives a TextDescriptor with a different layoutHash
    /// (see FlattenTests' contentSizeCategory coverage), changing Block.contentHash. This proves
    /// what that buys in production: `diff(previous:new:)` no longer classifies the block as
    /// `unchanged`, so the C3 in-place path (FeedScrollView.applyInPlaceBlockDiff) re-measures +
    /// re-rasterizes and `FrozenBitmapStore.store(...)` overwrites the stale entry for the SAME
    /// `BlockKey` — no separate cache-clear call anywhere. `scaledMeasure` stands in for
    /// `UIFontMetrics` scaling (a local closure, not `MeasureRasterizeSpy`, which measures by
    /// content length only and would return identical sizes for same-text descriptors).
    func testContentSizeCategoryChange_InvalidatesFrozenBitmapAndReFreezes() {
        let key = BlockKey(itemID: "msg", index: 0)

        func descriptor(category: VContentSizeCategory, layoutHash: Int) -> TextDescriptor {
            TextDescriptor(
                content: "caption",
                font: VFontDescriptor(size: 16, weight: 0),
                color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                lineLimit: nil,
                lineBreakMode: 0,
                contentSizeCategory: category,
                layoutHash: layoutHash,
                appearanceHash: 0
            )
        }
        func block(_ descriptor: TextDescriptor) -> Block {
            let frame = CGRect(x: 0, y: 0, width: 300, height: 0)
            let fragment = Fragment(id: 0, content: .text(descriptor), frame: frame)
            return Block(key: key, fragment: fragment, layout: ResolvedLayout(totalFrame: frame))
        }
        func scaledMeasure(_ descriptor: TextDescriptor, width: CGFloat) -> CGSize {
            let scale: CGFloat = descriptor.contentSizeCategory == .accessibilityExtraExtraExtraLarge ? 3 : 1
            return CGSize(width: width, height: CGFloat(descriptor.content.count) * scale)
        }
        func fakeRasterize(_ descriptor: TextDescriptor, size: CGSize, scale: CGFloat) -> CGImage? {
            BlockReuseTests.makeFakeCGImage(width: Int(size.width), height: Int(size.height))
        }

        let store = FrozenBitmapStore()

        // Round 1: freeze + store at .large, mirroring applyInPlaceBlockDiff's
        // measureAndMaybeFreeze(persist: true) path for a block that just closed out.
        let smallBlock = block(descriptor(category: .large, layoutHash: 1))
        var cache1: [BlockKey: FreezeState] = [:]
        guard case .frozen(let smallSize, let smallBitmap) = freeze(
            smallBlock, scale: 1, cache: &cache1, measure: scaledMeasure, rasterize: fakeRasterize
        ) else { return XCTFail("round 1 must freeze") }
        store.store(smallBitmap, size: smallSize, cost: 1, for: key)
        XCTAssertEqual(store.size(for: key), smallSize)

        // Round 2: SAME BlockKey, category changed to an accessibility size. contentHash must
        // differ (proving diff() would reclassify this block as changed, not `unchanged`).
        let largeBlock = block(descriptor(category: .accessibilityExtraExtraExtraLarge, layoutHash: 2))
        XCTAssertNotEqual(smallBlock.contentHash, largeBlock.contentHash,
            "a content-size-category change must perturb Block.contentHash for the SAME BlockKey")
        let d = diff(previous: [smallBlock], new: [largeBlock], frontier: 1)
        XCTAssertTrue(d.unchanged.isEmpty, "the category-changed block must not classify as unchanged")
        XCTAssertEqual(d.sealedChanged, [0], "the sole block differing must be reported as sealedChanged, so it gets re-measured")

        var cache2: [BlockKey: FreezeState] = [:]
        guard case .frozen(let largeSize, let largeBitmap) = freeze(
            largeBlock, scale: 1, cache: &cache2, measure: scaledMeasure, rasterize: fakeRasterize
        ) else { return XCTFail("round 2 must freeze") }
        store.store(largeBitmap, size: largeSize, cost: 1, for: key)

        XCTAssertGreaterThan(largeSize.height, smallSize.height,
            "the accessibility category must measure taller — this is the UIFontMetrics stand-in")
        XCTAssertEqual(store.size(for: key), largeSize,
            "FrozenBitmapStore must hold the NEW size for `key` — the stale small-category bitmap was overwritten in place")
    }
}

// MARK: - Acceptance 5: anti-jank trend through the REAL measure/rasterize primitives

#if canImport(UIKit)
extension BlockReuseTests {

    private static let wordBank: [String] = [
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "while", "chat",
        "message", "streams", "token", "by", "token", "across", "several", "lines", "of",
        "wrapped", "text", "and", "continues", "growing", "steadily", "as", "more", "content",
    ]

    private static func token(_ i: Int) -> String { wordBank[i % wordBank.count] }

    private struct BlockStreamResult {
        let n: Int
        let frozenPathSeconds: TimeInterval
        let naiveSeconds: TimeInterval
    }

    /// Streams `totalTokens` through the PRODUCTION Block/BlockKey/FreezeState/diff/freeze
    /// types using the REAL `TextMeasurementContext.measure`/`rasterizeText` — the "through the
    /// real types" counterpart to VelocityUI-6qd's spike harness (ad hoc dictionaries). Same
    /// token/block-quota model as `HybridReuseSpikeTests.simulateStreaming` for a directly
    /// comparable trend. Separate contexts per arm (per VelocityUI-6qd's design notes):
    /// `TextMeasurementContext` mutates shared TextKit 2 state, so interleaving the naive arm's
    /// calls through the frozen arm's context would leak overhead into its reading.
    private func simulateBlockStreaming(
        totalTokens: Int,
        tokenChunk: Int = 10,
        blockTokenQuota: Int = 30,
        width: CGFloat = 300,
        scale: CGFloat = 2
    ) -> BlockStreamResult {
        let frozenCtx = TextMeasurementContext()
        let naiveCtx = TextMeasurementContext()

        var cache: [BlockKey: FreezeState] = [:]
        var tokenBuckets: [[String]] = [[]]
        var previousBlocks: [Block] = [textBlock(index: 0, content: "", width: width)]

        var frozenPathSeconds: TimeInterval = 0
        var naiveSeconds: TimeInterval = 0

        var tokenCursor = 0
        var emitted = 0
        while emitted < totalTokens {
            let chunk = min(tokenChunk, totalTokens - emitted)
            for _ in 0..<chunk {
                tokenBuckets[tokenBuckets.count - 1].append(Self.token(tokenCursor))
                tokenCursor += 1
                if tokenBuckets[tokenBuckets.count - 1].count >= blockTokenQuota {
                    tokenBuckets.append([])
                }
            }
            emitted += chunk

            let newBlocks: [Block] = tokenBuckets.enumerated().map { idx, tokens in
                textBlock(index: idx, content: tokens.joined(separator: " "), width: width)
            }

            // ---- FROZEN/DIFF PATH: freeze only finalized blocks (never the trailing one). ----
            let d = diff(previous: previousBlocks, new: newBlocks, frontier: newBlocks.count - 1)
            for i in d.sealedChanged {
                let start = Date()
                freeze(
                    newBlocks[i], scale: scale, cache: &cache,
                    measure: { descriptor, w in frozenCtx.measure(descriptor, width: w) },
                    rasterize: { descriptor, size, s in rasterizeText(descriptor, size: size, scale: s) }
                )
                frozenPathSeconds += Date().timeIntervalSince(start)
            }
            // The trailing (hot) block is re-measured + re-rasterized every event but never
            // cached — mirrors the spike's hot-block handling exactly.
            let hotIdx = newBlocks.count - 1
            if case .text(let hotDescriptor) = newBlocks[hotIdx].fragment.content, !hotDescriptor.content.isEmpty {
                let mStart = Date()
                let size = frozenCtx.measure(hotDescriptor, width: width)
                frozenPathSeconds += Date().timeIntervalSince(mStart)
                let rStart = Date()
                _ = rasterizeText(hotDescriptor, size: size, scale: scale)
                frozenPathSeconds += Date().timeIntervalSince(rStart)
            }
            previousBlocks = newBlocks

            // ---- NAIVE BASELINE: re-measure + re-rasterize the WHOLE message every event. ----
            let wholeText = tokenBuckets.map { $0.joined(separator: " ") }.joined(separator: " ")
            if !wholeText.isEmpty {
                let descriptor = textDescriptor(wholeText)
                let mStart = Date()
                let size = naiveCtx.measure(descriptor, width: width)
                naiveSeconds += Date().timeIntervalSince(mStart)
                let rStart = Date()
                _ = rasterizeText(descriptor, size: size, scale: scale)
                naiveSeconds += Date().timeIntervalSince(rStart)
            }
        }

        return BlockStreamResult(n: totalTokens, frozenPathSeconds: frozenPathSeconds, naiveSeconds: naiveSeconds)
    }

    /// Anti-jank trend, asserted the same way VelocityUI-6qd's LB1a was — monotonic divergence
    /// of the naive/frozen ratio across N=100/500/2000, NO magic-number threshold gate — but now
    /// through the production Block/BlockKey/FreezeState/diff/freeze types instead of the
    /// spike's ad hoc dictionaries, proving the real API preserves the load-bearing property.
    func testAntiJankTrend_FrozenDiffPathLinear_NaiveSuperLinear_ThroughRealTypes() {
        _ = simulateBlockStreaming(totalTokens: 20) // warm up TextKit/font caches

        let n100 = simulateBlockStreaming(totalTokens: 100)
        let n500 = simulateBlockStreaming(totalTokens: 500)
        let n2000 = simulateBlockStreaming(totalTokens: 2000)

        func ratio(_ r: BlockStreamResult) -> Double {
            r.naiveSeconds / max(r.frozenPathSeconds, .ulpOfOne)
        }
        let r100 = ratio(n100), r500 = ratio(n500), r2000 = ratio(n2000)

        print("[BlockReuse][AntiJank] N=100  frozenPath=\(String(format: "%.5f", n100.frozenPathSeconds))s "
            + "naive=\(String(format: "%.5f", n100.naiveSeconds))s ratio=\(String(format: "%.2f", r100))x")
        print("[BlockReuse][AntiJank] N=500  frozenPath=\(String(format: "%.5f", n500.frozenPathSeconds))s "
            + "naive=\(String(format: "%.5f", n500.naiveSeconds))s ratio=\(String(format: "%.2f", r500))x")
        print("[BlockReuse][AntiJank] N=2000 frozenPath=\(String(format: "%.5f", n2000.frozenPathSeconds))s "
            + "naive=\(String(format: "%.5f", n2000.naiveSeconds))s ratio=\(String(format: "%.2f", r2000))x")

        XCTAssertGreaterThan(r500, r100,
            "naive/frozen ratio must strictly grow from N=100 (\(r100)x) to N=500 (\(r500)x)")
        XCTAssertGreaterThan(r2000, r500,
            "naive/frozen ratio must strictly grow from N=500 (\(r500)x) to N=2000 (\(r2000)x)")
    }
}
#endif

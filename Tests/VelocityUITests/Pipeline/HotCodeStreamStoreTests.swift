// HotCodeStreamStoreTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// VelocityUI-oz5q.7: streaming a hot code block's body into per-line raster tiles, one off-main
/// tree-sitter parse per line-seal event, a plain partial tail, and adaptive defer for large
/// blocks. Full 400-line on-device residency/perf coverage is VelocityUI-oz5q.9's job; these are
/// the unit-level mechanics: tile lifecycle, parse-call counting, stale-result rejection, and
/// theme invalidation.
@MainActor
final class HotCodeStreamStoreTests: XCTestCase {
    private let font = VFontDescriptor(size: 16, weight: 0, family: "Menlo")
    private let theme = Theme.defaultLight
    private let registry = HighlightRegistry()

    private func measure(_ d: TextDescriptor, _ width: CGFloat) -> CGSize {
        TextMeasurementContext().measure(d, width: width)
    }

    /// Flattens a chunked delivery into one image for assertions that predate chunking (byte
    /// comparisons, y-band crops across the whole sealed height) -- same helper production uses to
    /// persist one bitmap into the cold cache once a block leaves the hot streaming path.
    private func composedSealed(_ content: CodeBodyLayerContent, scale: CGFloat) -> CGImage? {
        HotCodeStreamStore.composeFullImage(
            CodeBodyLayerContent(chunks: content.chunks, tailImage: nil, tailSize: .zero), scale: scale
        )?.image
    }

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

    /// Counts observer events by kind — the production counters the acceptance criteria require.
    /// `@unchecked Sendable`: `eventObserver` is declared `@Sendable` on `HotCodeStreamStore.append`
    /// to match the production observer convention, but `append` only ever invokes it inline on
    /// `@MainActor`, never from the off-main parse `Task` -- single-actor access in practice.
    private final class EventCounter: @unchecked Sendable {
        var parseCalls = 0
        var sealedLineTiles = 0
        var partialLines = 0

        func observe(_ kind: CodeStreamEventKind) {
            switch kind {
            case .parseCall: parseCalls += 1
            case .sealedLineTileRasterized: sealedLineTiles += 1
            case .partialLineRasterized: partialLines += 1
            }
        }
    }

    // MARK: - splitSealedAndTail: pure helper edge cases

    func testSplitSealedAndTail_NoNewline_AllTail() {
        let (sealed, tail) = HotCodeStreamStore.splitSealedAndTail("let x = 1")
        XCTAssertEqual(sealed, [])
        XCTAssertEqual(tail, "let x = 1")
    }

    func testSplitSealedAndTail_OneCompleteLine_TrailingNewline() {
        let (sealed, tail) = HotCodeStreamStore.splitSealedAndTail("let x = 1\n")
        XCTAssertEqual(sealed, ["let x = 1"])
        XCTAssertEqual(tail, "")
    }

    func testSplitSealedAndTail_TwoCompleteLinesPlusPartialTail() {
        let (sealed, tail) = HotCodeStreamStore.splitSealedAndTail("a\nb\nc")
        XCTAssertEqual(sealed, ["a", "b"])
        XCTAssertEqual(tail, "c")
    }

    func testSplitSealedAndTail_SingleNewline_OneSealedEmptyLine() {
        let (sealed, tail) = HotCodeStreamStore.splitSealedAndTail("\n")
        XCTAssertEqual(sealed, [""], "a lone newline is one sealed EMPTY line, not zero sealed lines")
        XCTAssertEqual(tail, "")
    }

    func testSplitSealedAndTail_Empty_ZeroSealedLines() {
        let (sealed, tail) = HotCodeStreamStore.splitSealedAndTail("")
        XCTAssertEqual(sealed, [])
        XCTAssertEqual(tail, "")
    }

    // MARK: - append: first line seal produces an immediate plain tile + one parse call

    func testAppend_FirstLineSeal_ProducesImmediateNonNilImageAndFiresCountersOnce() {
        let store = HotCodeStreamStore()
        let counter = EventCounter()
        let key = BlockKey(itemID: "msg", index: 0)

        let result = store.append(
            key, rawCode: "let x = 1\nlet y", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
        )

        guard let image = result.content.tailImage else { return XCTFail("expected an immediate plain tail before any parse result lands") }
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        XCTAssertEqual(counter.sealedLineTiles, 1, "exactly one new sealed line this call")
        XCTAssertEqual(counter.partialLines, 1, "the tail is always rasterized once per call")
        XCTAssertEqual(counter.parseCalls, 1, "one line sealed -> exactly one parse call")
    }

    // MARK: - append: tail-only growth never spawns a new parse

    func testAppend_TailOnlyGrowth_DoesNotSpawnAnotherParseCall() {
        let store = HotCodeStreamStore()
        let counter = EventCounter()
        let key = BlockKey(itemID: "msg", index: 0)

        _ = store.append(
            key, rawCode: "let x = 1\nlet y", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
        )
        XCTAssertEqual(counter.parseCalls, 1)

        _ = store.append(
            key, rawCode: "let x = 1\nlet y = 2", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
        )

        XCTAssertEqual(counter.parseCalls, 1, "no new line sealed -- tail-only growth must not trigger tree-sitter")
        XCTAssertEqual(counter.sealedLineTiles, 1, "no new sealed line -- the existing tile must not be re-rasterized")
        XCTAssertEqual(counter.partialLines, 2, "the tail is rasterized on every call")
    }

    // MARK: - recolor: lands asynchronously and changes the composite's pixels

    func testRecolor_LandsAsynchronously_ChangesCompositePixels() {
        let store = HotCodeStreamStore()
        let key = BlockKey(itemID: "msg", index: 0)
        let exp = expectation(description: "onRecolor fires")
        var recoloredImage: CGImage?

        let plain = store.append(
            key, rawCode: "let keyword = 1\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 2,
            measure: measure, eventObserver: nil,
            onRecolor: { [self] content in
                recoloredImage = composedSealed(content, scale: 2)
                exp.fulfill()
            }
        )
        guard let plainImage = composedSealed(plain.content, scale: 2) else { return XCTFail("expected a plain sealed image") }

        wait(for: [exp], timeout: 5)

        guard let recoloredImage else { return XCTFail("onRecolor must fire once the off-main parse lands") }
        XCTAssertNotEqual(
            pixelBytes(of: plainImage), pixelBytes(of: recoloredImage),
            "a Swift keyword under the default theme must render in a different color than plain text"
        )
    }

    // MARK: - byte identity: an already-colored tile is never touched by later appends

    func testColoredTile_RemainsByteIdenticalAcrossLaterAppends() {
        let store = HotCodeStreamStore()
        let key = BlockKey(itemID: "msg", index: 0)
        let exp = expectation(description: "onRecolor fires")

        _ = store.append(
            key, rawCode: "let keyword = 1\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 2,
            measure: measure, eventObserver: nil,
            onRecolor: { _ in exp.fulfill() }
        )
        wait(for: [exp], timeout: 5)

        // Crop the first line's row band out of the composite right after recolor landed.
        let afterRecolor = store.append(
            key, rawCode: "let keyword = 1\nsecond", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 2,
            measure: measure, eventObserver: nil, onRecolor: { _ in }
        )
        guard let imageA = composedSealed(afterRecolor.content, scale: 2) else { return XCTFail("expected a sealed image") }
        let lineHeightPixels = Int((font.uiFont.lineHeight * 2).rounded())
        guard let firstLineBandA = imageA.cropping(to: CGRect(x: 0, y: 0, width: imageA.width, height: min(lineHeightPixels, imageA.height))) else {
            return XCTFail("expected a croppable first-line band")
        }

        // Append several more lines -- the colored first line's pixels must not move/change.
        let later = store.append(
            key, rawCode: "let keyword = 1\nsecond\nthird\nfourth", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 2,
            measure: measure, eventObserver: nil, onRecolor: { _ in }
        )
        guard let imageB = composedSealed(later.content, scale: 2),
              let firstLineBandB = imageB.cropping(to: CGRect(x: 0, y: 0, width: imageA.width, height: min(lineHeightPixels, imageB.height)))
        else { return XCTFail("expected a croppable first-line band after later appends") }

        XCTAssertEqual(
            pixelBytes(of: firstLineBandA), pixelBytes(of: firstLineBandB),
            "the first line's tile was already colored -- later, unrelated appends must never touch it"
        )
    }

    // MARK: - adaptive defer: stops spawning parses past the threshold

    func testAdaptiveDefer_StopsSpawningParsesPastThreshold() {
        let store = HotCodeStreamStore(adaptiveDeferLineThreshold: 3)
        let counter = EventCounter()
        let key = BlockKey(itemID: "msg", index: 0)

        var rawCode = ""
        for lineNumber in 0..<8 {
            rawCode += "line\(lineNumber)\n"
            _ = store.append(
                key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
                languageID: .swift, highlightRegistry: registry, scale: 1,
                measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
            )
        }

        XCTAssertEqual(
            counter.parseCalls, 3,
            "parse calls must stop increasing once the sealed-line count crosses the threshold (3)"
        )
        XCTAssertEqual(counter.sealedLineTiles, 8, "deferred mode still appends a cheap plain tile per new sealed line")
    }

    // MARK: - theme change: invalidates and rebuilds every tile

    func testThemeGenerationChange_RebuildsAllTilesFromScratch() {
        let store = HotCodeStreamStore()
        let counter = EventCounter()
        let key = BlockKey(itemID: "msg", index: 0)

        _ = store.append(
            key, rawCode: "one\ntwo\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
        )
        XCTAssertEqual(counter.sealedLineTiles, 2)

        // Same content, new theme generation -- every already-sealed line must be re-tiled.
        _ = store.append(
            key, rawCode: "one\ntwo\n", font: font, theme: .defaultDark, themeGeneration: 1,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
        )

        XCTAssertEqual(counter.sealedLineTiles, 4, "a theme change must rebuild every previously-sealed line's tile, not reuse the old-theme pixels")
    }

    // MARK: - evict: tears down only the given key

    func testEvict_TearsDownOnlyGivenKey() {
        let store = HotCodeStreamStore()
        let counterA = EventCounter()
        let counterB = EventCounter()
        let keyA = BlockKey(itemID: "msg", index: 0)
        let keyB = BlockKey(itemID: "msg", index: 1)

        _ = store.append(
            keyA, rawCode: "a\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counterA.observe($0) }, onRecolor: { _ in }
        )
        _ = store.append(
            keyB, rawCode: "b\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counterB.observe($0) }, onRecolor: { _ in }
        )

        store.evict([keyA])

        // A fresh append for keyA after eviction must behave like a brand-new key (full rebuild).
        _ = store.append(
            keyA, rawCode: "a\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counterA.observe($0) }, onRecolor: { _ in }
        )
        XCTAssertEqual(counterA.sealedLineTiles, 2, "keyA was evicted -- the next append must re-tile from scratch, not reuse a torn-down entry")
    }

    // MARK: - evict: cancels the in-flight parse so a remount under the same key can't be colored stale

    func testEvict_CancelsInFlightParse_StaleResultNeverAppliesAfterRemount() {
        let store = HotCodeStreamStore()
        let key = BlockKey(itemID: "msg", index: 0)
        var staleRecolorDeliveries = 0

        _ = store.append(
            key, rawCode: "let keyword = 1\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil,
            onRecolor: { _ in staleRecolorDeliveries += 1 }
        )
        // Evict immediately -- must cancel the parse this append just spawned before it can land.
        store.evict([key])

        // Remount under the same key right away, before any stale completion could fire.
        let exp = expectation(description: "the new generation's own recolor fires")
        var recoloredAfterRemount: CGImage?
        _ = store.append(
            key, rawCode: "second\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil,
            onRecolor: { [self] content in
                recoloredAfterRemount = composedSealed(content, scale: 1)
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(staleRecolorDeliveries, 0, "the evicted key's cancelled parse must never deliver onto the remounted entry")
        XCTAssertNotNil(recoloredAfterRemount, "the new generation must still receive its own recolor")
    }

    // MARK: - scale change: invalidates and rebuilds every tile, mirroring the theme-change contract

    func testScaleChange_RebuildsAllTilesFromScratch() {
        let store = HotCodeStreamStore()
        let counter = EventCounter()
        let key = BlockKey(itemID: "msg", index: 0)

        _ = store.append(
            key, rawCode: "one\ntwo\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
        )
        XCTAssertEqual(counter.sealedLineTiles, 2)

        // Same content and theme, different display scale -- pixels rasterized at the old scale
        // are wrong at the new one, so every already-sealed line must be re-tiled.
        _ = store.append(
            key, rawCode: "one\ntwo\n", font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 2,
            measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
        )

        XCTAssertEqual(counter.sealedLineTiles, 4, "a scale change must rebuild every previously-sealed line's tile, not reuse the old-scale pixels")
    }

    // MARK: - finalize: past adaptive defer, spawns exactly one final parse off the caller's thread

    func testFinalize_PastAdaptiveDefer_SpawnsExactlyOneFinalParseAndColorizesEverything() {
        let store = HotCodeStreamStore(adaptiveDeferLineThreshold: 2)
        let counter = EventCounter()
        let key = BlockKey(itemID: "msg", index: 0)

        var rawCode = ""
        for lineNumber in 0..<5 {
            rawCode += "let keyword\(lineNumber) = \(lineNumber)\n"
            _ = store.append(
                key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
                languageID: .swift, highlightRegistry: registry, scale: 1,
                measure: measure, eventObserver: { counter.observe($0) }, onRecolor: { _ in }
            )
        }
        XCTAssertEqual(counter.parseCalls, 2, "defer must have already stopped intermediate parses")

        let exp = expectation(description: "finalize's single parse lands")
        var finalImage: CGImage?
        let result = store.finalize(
            key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: { counter.observe($0) },
            onRecolor: { [self] content in
                finalImage = composedSealed(content, scale: 1)
                exp.fulfill()
            }
        )
        XCTAssertTrue(result.needsAsyncColorization, "the deferred lines were never colorized -- finalize must still colorize them")
        guard let plainImage = composedSealed(result.content, scale: 1) else { return XCTFail("finalize must return sealed pixels synchronously without blocking on the parse") }

        wait(for: [exp], timeout: 5)
        XCTAssertEqual(counter.parseCalls, 3, "closing the fence spawns exactly one final parse regardless of defer")
        guard let finalImage else { return XCTFail("expected a final colorized delivery") }
        XCTAssertNotEqual(
            pixelBytes(of: plainImage), pixelBytes(of: finalImage),
            "\"let\" is a Swift keyword under the default theme -- the deferred lines (never colorized while hot) must actually be recolored by finalize's parse, not just re-delivered as the same plain bitmap"
        )
    }

    // MARK: - finalize: a large uncolored range delivers across bounded chunks, not one MainActor turn

    func testFinalize_LargeUncoloredRange_DeliversAcrossMultipleChunkedCallbacks() {
        let store = HotCodeStreamStore(adaptiveDeferLineThreshold: 1)
        let key = BlockKey(itemID: "msg", index: 0)

        var rawCode = ""
        for lineNumber in 0..<90 {
            rawCode += "let v\(lineNumber) = \(lineNumber)\n"
        }
        _ = store.append(
            key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil, onRecolor: { _ in }
        )
        // All 90 sealed lines above are still plain -- defer engaged after the first.

        var deliveryCount = 0
        let exp = expectation(description: "the chunked recolor sequence completes")
        _ = store.finalize(
            key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil,
            onRecolor: { _ in
                deliveryCount += 1
                // 90 lines exceeds one chunk's line budget -- if this ever regresses to one
                // synchronous callback covering the whole range, this count collapses to 1.
                if deliveryCount >= 2 { exp.fulfill() }
            }
        )
        wait(for: [exp], timeout: 5)
        XCTAssertGreaterThanOrEqual(deliveryCount, 2, "90 lines must colorize across multiple bounded chunks, not one MainActor turn")
    }

    // MARK: - isFullyColorized: false on every intermediate chunk, true only on the last

    /// Regression for the production bug where the `FeedScrollView+Items.swift` caller evicted
    /// the streaming entry as soon as the FIRST chunked `onRecolor` delivery landed: for a
    /// 90-line block chunked at 40 lines/turn, that dropped the last 50 lines' colorization
    /// (their continuation's `deliverColorRuns` found the entry already gone and silently
    /// returned). `isFullyColorized` is the fix's gating API -- this asserts its contract
    /// directly: false for every delivery except the one that actually finishes the range.
    func testIsFullyColorized_FalseUntilLastChunk_TrueOnFinalDelivery() {
        let store = HotCodeStreamStore(adaptiveDeferLineThreshold: 1)
        let key = BlockKey(itemID: "msg", index: 0)

        var rawCode = ""
        for lineNumber in 0..<90 {
            rawCode += "let v\(lineNumber) = \(lineNumber)\n"
        }
        _ = store.append(
            key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil, onRecolor: { _ in }
        )
        // All 90 sealed lines above are still plain -- defer engaged after the first.

        var isFullyColorizedAtEachDelivery: [Bool] = []
        let exp = expectation(description: "the chunked recolor sequence completes")
        _ = store.finalize(
            key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil,
            onRecolor: { [weak store] _ in
                guard let store else { return }
                let isFinal = store.isFullyColorized(key)
                isFullyColorizedAtEachDelivery.append(isFinal)
                if isFinal { exp.fulfill() }
            }
        )
        wait(for: [exp], timeout: 5)

        XCTAssertGreaterThanOrEqual(
            isFullyColorizedAtEachDelivery.count, 2,
            "90 lines at a 40-line chunk budget must deliver at least twice before completing"
        )
        XCTAssertEqual(
            isFullyColorizedAtEachDelivery.dropLast(), Array(repeating: false, count: isFullyColorizedAtEachDelivery.count - 1),
            "every delivery except the last must report incomplete colorization"
        )
        XCTAssertEqual(isFullyColorizedAtEachDelivery.last, true, "the delivery that finishes the range must report complete colorization")
    }

    /// Mirrors the fixed production call site: only evict once `isFullyColorized` is true. Proves
    /// that gating eviction this way (instead of the old unconditional per-callback evict) lets
    /// every line in a 90-line, past-adaptive-defer block reach its colorized tile -- including
    /// lines well past the first 40-line chunk, which the original bug never colorized.
    func testGatedEvictOnFullColorization_AllNinetyLinesEventuallyColorize() {
        let store = HotCodeStreamStore(adaptiveDeferLineThreshold: 1)
        let key = BlockKey(itemID: "msg", index: 0)

        var rawCode = ""
        for lineNumber in 0..<90 {
            rawCode += "let v\(lineNumber) = \(lineNumber)\n"
        }
        _ = store.append(
            key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil, onRecolor: { _ in }
        )

        var lastImage: CGImage?
        let exp = expectation(description: "final (fully-colorized) delivery lands")
        let result = store.finalize(
            key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
            languageID: .swift, highlightRegistry: registry, scale: 1,
            measure: measure, eventObserver: nil,
            onRecolor: { [self] content in
                lastImage = composedSealed(content, scale: 1)
                if store.isFullyColorized(key) {
                    store.evict([key])
                    exp.fulfill()
                }
            }
        )
        guard let plainImage = composedSealed(result.content, scale: 1) else { return XCTFail("expected plain synchronous sealed pixels") }
        wait(for: [exp], timeout: 5)
        guard let finalImage = lastImage else { return XCTFail("expected a final colorized delivery") }

        // Crop a band around line ~70 of 90 (90 sealed lines + 1 empty tail = 91 rows stacked) --
        // well past the first 40-line chunk, the exact region the original unconditional-evict
        // bug never colorized. Uses a height *fraction* rather than an assumed fixed line height,
        // since the measured per-line height isn't guaranteed to equal `font.uiFont.lineHeight`.
        XCTAssertEqual(plainImage.height, finalImage.height, "colorizing a tile must never change its measured size")
        let totalRows: CGFloat = 91
        let bandStartY = Int(CGFloat(finalImage.height) * (65.0 / totalRows))
        let bandEndY = Int(CGFloat(finalImage.height) * (75.0 / totalRows))
        let bandHeight = bandEndY - bandStartY
        guard bandHeight > 0, bandEndY <= finalImage.height,
              let plainBand = plainImage.cropping(to: CGRect(x: 0, y: bandStartY, width: plainImage.width, height: bandHeight)),
              let coloredBand = finalImage.cropping(to: CGRect(x: 0, y: bandStartY, width: finalImage.width, height: bandHeight))
        else { return XCTFail("expected a croppable band around line 70") }

        XCTAssertNotEqual(
            pixelBytes(of: plainBand), pixelBytes(of: coloredBand),
            "line 89 (past the first 40-line chunk) must be colorized once colorization completes -- this is exactly what the unconditional-evict-on-first-callback bug never delivered"
        )
    }

    // MARK: - Performance: per-seal cost and per-chunk allocation stay flat as the block grows

    /// A monolithic O(sealed height) recomposite (the bug this chunking model replaces) would make
    /// each `append` call that seals a new line cost proportional to how many lines have already
    /// sealed -- late-stream seals in a long block would take many times longer than early ones, and
    /// the single sealed bitmap would grow without bound. Chunking bounds both: every seal only
    /// recomposites at most `chunkLineBudget` lines (the still-growing hot chunk, plus at most one
    /// newly-frozen chunk), and every frozen chunk's own pixel buffer stays the same fixed size
    /// regardless of total block length.
    ///
    /// Streams `adaptiveDeferLineThreshold: 0` so only the very first line seal spawns an off-main
    /// parse (every later seal is deferred) -- this isolates the synchronous append/recomposite cost
    /// this test measures from unrelated Task-spawn overhead.
    func testStreaming_PerSealCostAndChunkAllocationStayFlatAsBlockGrows() {
        let store = HotCodeStreamStore(adaptiveDeferLineThreshold: 0)
        let key = BlockKey(itemID: "msg", index: 0)
        let scale: CGFloat = 1
        // +5 past an exact chunk multiple so the final chunk is a genuine still-growing hot chunk,
        // not another full frozen one -- keeps `dropLast()` below unambiguous.
        let totalLines = 32 * HotCodeStreamStore.chunkLineBudget + 5

        var rawCode = ""
        var perLineNanoseconds: [UInt64] = []
        perLineNanoseconds.reserveCapacity(totalLines)
        var lastContent: CodeBodyLayerContent?

        for lineNumber in 0..<totalLines {
            rawCode += "let v\(lineNumber) = \(lineNumber)\n"
            let start = DispatchTime.now().uptimeNanoseconds
            let result = store.append(
                key, rawCode: rawCode, font: font, theme: theme, themeGeneration: 0,
                languageID: .swift, highlightRegistry: registry, scale: scale,
                measure: measure, eventObserver: nil, onRecolor: { _ in }
            )
            let end = DispatchTime.now().uptimeNanoseconds
            perLineNanoseconds.append(end - start)
            lastContent = result.content
        }

        guard let content = lastContent else { return XCTFail("expected a final delivery") }
        let frozenChunks = content.chunks.dropLast() // last chunk is still the growing hot chunk
        XCTAssertGreaterThanOrEqual(frozenChunks.count, 30, "512 lines at a 16-line budget must freeze at least 30 chunks")

        // Bounded allocation: every frozen chunk's own composite is the same fixed size (bounded by
        // chunkLineBudget lines), never growing with how many lines came before it.
        guard let firstChunkHeight = frozenChunks.first?.size.height, firstChunkHeight > 0 else {
            return XCTFail("expected a non-empty first frozen chunk")
        }
        for chunk in frozenChunks {
            XCTAssertEqual(
                chunk.size.height, firstChunkHeight, accuracy: 0.5,
                "every frozen chunk must be the same bounded size regardless of how many lines sealed before it -- a growing chunk height would mean the O(sealed height) recomposite this bead removes is still happening"
            )
        }

        // Flat per-seal cost: median cost of an early window of seals vs. a late window, after a
        // warmup window to let allocator/caches settle. A monolithic recomposite would make the late
        // window many times slower (proportional to sealedHeight, ~16x more sealed lines by the late
        // window here); the chunked model keeps both windows close, within noise.
        func median(_ values: [UInt64]) -> Double {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 0
                ? Double(sorted[mid - 1] + sorted[mid]) / 2
                : Double(sorted[mid])
        }
        let warmupLines = 4 * HotCodeStreamStore.chunkLineBudget
        let windowSize = 4 * HotCodeStreamStore.chunkLineBudget
        let earlyWindow = Array(perLineNanoseconds[warmupLines..<(warmupLines + windowSize)])
        let lateWindow = Array(perLineNanoseconds[(totalLines - windowSize)...])
        let earlyMedian = median(earlyWindow)
        let lateMedian = median(lateWindow)

        XCTAssertLessThan(
            lateMedian, earlyMedian * 5,
            "median per-seal MainActor time late in a 512-line stream (\(lateMedian)ns) must stay within a small "
            + "constant factor of the early-stream median (\(earlyMedian)ns), not scale with total sealed lines"
        )
    }
}
#endif

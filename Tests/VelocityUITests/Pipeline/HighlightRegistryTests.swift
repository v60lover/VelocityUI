// HighlightRegistryTests.swift

import XCTest
import Foundation
@testable import VelocityUI

/// Covers VelocityUI-oz5q.2: the compiled-grammar LRU + active theme registry.
///
/// Acceptance-criterion -> test mapping:
/// - Registry hands back the SAME compiled grammar instance on repeated lookup (LRU hit)
///     -> testGrammarFor_RepeatedLookup_ReturnsSameInstance
/// - Evicts past capacity
///     -> testGrammarFor_MoreDistinctLanguagesThanCapacity_EvictsLeastRecentlyUsed
/// - A hit bumps recency, rescuing an entry from the next eviction
///     -> testGrammarFor_HitBumpsRecency_RescuesEntryFromNextEviction
/// - Switching theme changes the theme generation so cached rasters invalidate
///     -> testSetActiveTheme_DifferentTheme_IncrementsGenerationByOne
///     -> testSetActiveTheme_SameTheme_DoesNotIncrementGeneration
/// - HighlightRegistry is a RenderEnvironment property, injected by init, no static/shared state
///     -> testRenderEnvironment_OwnsInjectedHighlightRegistry_SameInstance (below, `#if canImport(UIKit)`)
final class HighlightRegistryTests: XCTestCase {

    // MARK: - Acceptance 1: grammar(for:) LRU hit returns the same instance

    func testGrammarFor_RepeatedLookup_ReturnsSameInstance() {
        let registry = HighlightRegistry()

        let first = registry.grammar(for: .swift)
        let second = registry.grammar(for: .swift)

        XCTAssertTrue(first === second, "A repeated lookup for the same language must return the SAME CompiledGrammar instance, not recompile")
    }

    func testGrammarFor_DifferentLanguages_ReturnDistinctInstances() {
        let registry = HighlightRegistry()

        let swift = registry.grammar(for: .swift)
        let python = registry.grammar(for: .python)

        XCTAssertFalse(swift === python)
        XCTAssertEqual(swift.languageID, .swift)
        XCTAssertEqual(python.languageID, .python)
    }

    // MARK: - Acceptance 2: eviction past capacity

    func testGrammarFor_MoreDistinctLanguagesThanCapacity_EvictsLeastRecentlyUsed() {
        let registry = HighlightRegistry(capacity: 3)

        let swift = registry.grammar(for: .swift)
        _ = registry.grammar(for: .python)
        _ = registry.grammar(for: .json)
        // No intervening reads, so `swift` (oldest) is the least-recently-used entry.
        _ = registry.grammar(for: .bash)

        let swiftAgain = registry.grammar(for: .swift)
        XCTAssertFalse(swiftAgain === swift, "`swift` was the least-recently-used entry and must have been evicted to make room for `bash`")
    }

    // MARK: - Acceptance 2b: LRU-recency-rescue

    func testGrammarFor_HitBumpsRecency_RescuesEntryFromNextEviction() {
        let registry = HighlightRegistry(capacity: 3)

        let swift = registry.grammar(for: .swift)
        let python = registry.grammar(for: .python)
        _ = registry.grammar(for: .json)
        // Without a rescue, `swift` (oldest) would be the next eviction victim. Touch it so
        // `python` becomes the new least-recently-used entry instead.
        let swiftRescued = registry.grammar(for: .swift)
        XCTAssertTrue(swiftRescued === swift, "Hit rescues `swift` — bumps it to most-recently-used")

        _ = registry.grammar(for: .bash)

        XCTAssertTrue(registry.grammar(for: .swift) === swift, "`swift` was rescued by the hit — must survive the eviction that follows")
        XCTAssertFalse(registry.grammar(for: .python) === python, "`python` is now the least-recently-used entry — must be the eviction victim")
    }

    // MARK: - Acceptance 3: theme + theme generation

    func testSetActiveTheme_DifferentTheme_IncrementsGenerationByOne() {
        let registry = HighlightRegistry(activeTheme: .defaultLight)
        XCTAssertEqual(registry.themeGeneration, 0)

        registry.setActiveTheme(.defaultDark)

        XCTAssertEqual(registry.themeGeneration, 1)
        XCTAssertEqual(registry.activeTheme, .defaultDark)
    }

    func testSetActiveTheme_SameTheme_DoesNotIncrementGeneration() {
        let registry = HighlightRegistry(activeTheme: .defaultLight)

        registry.setActiveTheme(.defaultLight)

        XCTAssertEqual(registry.themeGeneration, 0, "Setting the theme to its current value must not burn a generation bump")
    }

    func testSetActiveTheme_TwoRealChangesInARow_IncrementsGenerationTwice() {
        let registry = HighlightRegistry(activeTheme: .defaultLight)

        registry.setActiveTheme(.defaultDark)
        registry.setActiveTheme(.defaultLight)

        XCTAssertEqual(registry.themeGeneration, 2)
    }
}

// MARK: - Acceptance 4: RenderEnvironment ownership

#if canImport(UIKit)
extension HighlightRegistryTests {

    @MainActor
    private func makeEnvironment(highlightRegistry: HighlightRegistry) -> RenderEnvironment {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: TextMeasurementPool(),
            layoutCache: LayoutCache(),
            dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc),
            gifActor: GIFActor(),
            videoController: VideoController(videoPreparation: videoPrep),
            videoPreparation: videoPrep,
            frozenBitmapStore: FrozenBitmapStore(),
            hotBlockRasterizerStore: HotBlockRasterizerStore(),
            hotCodeStreamStore: HotCodeStreamStore(),
            highlightRegistry: highlightRegistry
        )
    }

    @MainActor
    func testRenderEnvironment_OwnsInjectedHighlightRegistry_SameInstance() {
        let registry = HighlightRegistry()
        let env = makeEnvironment(highlightRegistry: registry)
        XCTAssertTrue(env.highlightRegistry === registry, "RenderEnvironment must expose the SAME instance it was injected with")
    }

    @MainActor
    func testRenderEnvironment_ConvenienceInit_DefaultConstructsAWorkingRegistry() {
        let env = RenderEnvironment()
        XCTAssertEqual(env.highlightRegistry.themeGeneration, 0)
        XCTAssertEqual(env.highlightRegistry.activeTheme, .defaultLight)
    }
}
#endif

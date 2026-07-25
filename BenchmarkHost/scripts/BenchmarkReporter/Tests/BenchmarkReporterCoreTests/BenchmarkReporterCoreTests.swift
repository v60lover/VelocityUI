// BenchmarkReporterCoreTests.swift

import XCTest
@testable import BenchmarkReporterCore

final class BenchmarkReporterCoreTests: XCTestCase {

    // MARK: - Filename parsing

    func test_parseFilename_validShape() {
        let parsed = RunRecord.parseFilename("velocityui__idiomatic__medium__warm__3.json")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.runtime, "velocityui")
        XCTAssertEqual(parsed?.mode, "idiomatic")
        XCTAssertEqual(parsed?.profile, "medium")
        XCTAssertEqual(parsed?.scenario, "warm")
        XCTAssertEqual(parsed?.runIndex, 3)
    }

    func test_parseFilename_rejectsBadShape() {
        XCTAssertNil(RunRecord.parseFilename("velocityui-idiomatic-medium-warm-3.json"))
        XCTAssertNil(RunRecord.parseFilename("velocityui__idiomatic__medium__warm.json"))
        XCTAssertNil(RunRecord.parseFilename("velocityui__idiomatic__medium__warm__notanumber.json"))
    }

    // MARK: - Percentile math

    func test_percentile_singleValue() {
        XCTAssertEqual(Stats.percentile([42], 50), 42)
        XCTAssertEqual(Stats.percentile([42], 99), 42)
    }

    func test_percentile_pairsReturnsLargerAtP99() {
        XCTAssertEqual(Stats.percentile([1, 10], 99), 10)
        XCTAssertEqual(Stats.percentile([1, 10], 50), 1)
    }

    func test_coefficientOfVariation_zeroForSingleValue() {
        XCTAssertEqual(Stats.coefficientOfVariation([5]), 0)
    }

    func test_coefficientOfVariation_zeroForPerfectZeroes() {
        // VelocityUI's contract case — all zero allocations. CoV must not
        // flag this as unstable; the metric is perfectly stable at 0.
        XCTAssertEqual(Stats.coefficientOfVariation([0, 0, 0, 0]), 0)
    }

    func test_coefficientOfVariation_largeForNoisySeries() {
        let cov = Stats.coefficientOfVariation([10, 12, 11, 9, 50])
        XCTAssertGreaterThan(cov, 0.5)
    }

    // MARK: - Aggregation never averages across asymmetries

    func test_aggregate_keepsColdAndWarmSeparate() {
        let cold = makeRecord(runtime: "velocityui", scenario: "cold", hitches: 50)
        let warm = makeRecord(runtime: "velocityui", scenario: "warm", hitches: 5)
        let rows = Aggregator.aggregate([cold, warm])
        XCTAssertEqual(rows.count, 2, "cold and warm must be separate buckets")
        let coldRow = rows.first { $0.scenario == "cold" }!
        let warmRow = rows.first { $0.scenario == "warm" }!
        XCTAssertEqual(coldRow.hitchesPer1k_p50, 50)
        XCTAssertEqual(warmRow.hitchesPer1k_p50, 5)
    }

    func test_aggregate_keepsIdiomaticAndSamePipelineSeparate() {
        let id1 = makeRecord(runtime: "velocityui", mode: "idiomatic", hitches: 5)
        let sp1 = makeRecord(runtime: "velocityui", mode: "same-pipeline", hitches: 50)
        let rows = Aggregator.aggregate([id1, sp1])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.mode == "idiomatic" }?.hitchesPer1k_p50, 5)
        XCTAssertEqual(rows.first { $0.mode == "same-pipeline" }?.hitchesPer1k_p50, 50)
    }

    // MARK: - Honesty canary (bead success criterion)

    func test_honestyCanary_thirtyPercentVarianceIsFlagged() {
        // 5 runs, 30% spread from the mean — must be flagged as unstable
        // and surfaced in the NOTES section of the Markdown report.
        let runs = [10.0, 13.0, 7.0, 12.0, 8.0].enumerated().map { i, h in
            makeRecord(runtime: "noisy-runtime", scenario: "warm", hitches: h, runIndex: i + 1)
        }
        let rows = Aggregator.aggregate(runs)
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertGreaterThan(row.hitchesPer1k_cov, 0.15,
            "CoV \(row.hitchesPer1k_cov) must exceed 15% threshold to flag instability")

        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("⚠"), "inline unstable marker must appear")
        XCTAssertTrue(md.contains("Unstable combos"), "NOTES section must list unstable combos")
        XCTAssertTrue(md.contains("noisy-runtime"), "NOTES must name the offending combo")
    }

    func test_honestyCanary_stableSeriesIsNotFlagged() {
        let runs = [10.0, 10.1, 9.9, 10.05, 10.02].enumerated().map { i, h in
            makeRecord(runtime: "stable-runtime", scenario: "warm", hitches: h, runIndex: i + 1)
        }
        let rows = Aggregator.aggregate(runs)
        XCTAssertLessThan(rows[0].hitchesPer1k_cov, 0.15)
        let md = MarkdownWriter.render(rows, stamp: "test")
        // Summary mentions count=0; NOTES must not list any combo and tables
        // must not annotate any row with the unstable marker.
        XCTAssertFalse(md.contains("### Unstable combos"))
        // Table-row markers attach the ⚠ to a number — check the specific
        // pattern instead of the bare glyph (the methodology footnote uses
        // a bare ⚠ to describe the convention).
        XCTAssertFalse(md.contains(" ⚠ "), "no inline row should be flagged")
        XCTAssertTrue(md.contains("No unstable combos"))
    }

    // MARK: - VelocityUI contract surfacing

    func test_velocityUIContract_failureSurfacesInNotes() {
        // VelocityUI with nonzero alloc/frame → contract violation → must
        // appear in NOTES with explicit "Phase 1 invariant breached" wording.
        let bad = makeRecord(
            runtime: "velocityui", mode: "idiomatic", profile: "max", scenario: "warm",
            hitches: 0, allocBytes: 64, taskSpawns: 0
        )
        let rows = Aggregator.aggregate([bad])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("Phase 1 invariant breached"),
            "VelocityUI alloc/frame > 0 must surface as contract violation")
        XCTAssertTrue(md.contains("❌"), "Q5 contract column must mark fail")
    }

    func test_velocityUIContract_passSurfacesAsCheckmark() {
        let good = makeRecord(
            runtime: "velocityui", mode: "idiomatic", profile: "max", scenario: "warm",
            hitches: 1, allocBytes: 0, taskSpawns: 0
        )
        let rows = Aggregator.aggregate([good])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("✅"))
        XCTAssertFalse(md.contains("Phase 1 invariant breached"))
    }

    // MARK: - CSV shape

    func test_csv_headerAndRowShape() {
        let row = makeRecord(runtime: "uicollectionview", hitches: 3.5)
        let csv = CSVWriter.render(Aggregator.aggregate([row]))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].split(separator: ",").count, 18)
        XCTAssertTrue(lines[1].hasPrefix("uicollectionview,idiomatic,medium,warm,1,"))
    }

    func test_markdown_emitsAllFiveSections() {
        let r1 = makeRecord(runtime: "velocityui", mode: "idiomatic", scenario: "warm")
        let r2 = makeRecord(runtime: "uicollectionview", mode: "same-pipeline", scenario: "cold")
        let md = MarkdownWriter.render(Aggregator.aggregate([r1, r2]), stamp: "test")
        XCTAssertTrue(md.contains("Q1 — Engine cost"))
        XCTAssertTrue(md.contains("Q2 — Real-world feel"))
        XCTAssertTrue(md.contains("Q3 — Cold launch"))
        XCTAssertTrue(md.contains("Q4 — Steady state"))
        XCTAssertTrue(md.contains("Q5 — Phase 1 contract"))
        XCTAssertTrue(md.contains("Methodology footnotes"))
    }

    // MARK: - Test helpers

    private func makeRecord(
        runtime: String,
        mode: String = "idiomatic",
        profile: String = "medium",
        scenario: String = "warm",
        hitches: Double = 0,
        allocBytes: Double = 0,
        taskSpawns: Int = 0,
        runIndex: Int = 1
    ) -> RunRecord {
        let report = BenchmarkReport(
            runtime: runtime,
            captureDurationSeconds: 30,
            frameStats: .init(
                totalFrames: 1800,
                hitchCount: Int(hitches * 1.8),
                hitchesPerThousand: hitches,
                p50FrameTimeMs: 16.6,
                p99FrameTimeMs: 18.0,
                maxFrameTimeMs: 22.0,
                sustainedFrameRateHz: 59.5
            ),
            memoryStats: .init(
                peakPhysFootprintBytes: 64_000_000,
                avgAllocDeltaPerFrameBytes: allocBytes
            ),
            taskSpawnCount: taskSpawns,
            metricKitSnapshots: []
        )
        return RunRecord(
            runtime: runtime, mode: mode, profile: profile, scenario: scenario,
            runIndex: runIndex, report: report
        )
    }
}

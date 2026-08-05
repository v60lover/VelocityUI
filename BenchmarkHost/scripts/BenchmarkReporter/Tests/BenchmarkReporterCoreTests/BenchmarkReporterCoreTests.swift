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

    func test_aggregate_keepsIdiomaticAndRawSeparate() {
        let id1 = makeRecord(runtime: "velocityui", mode: "idiomatic", hitches: 5)
        let sp1 = makeRecord(runtime: "velocityui", mode: "raw", hitches: 50)
        let rows = Aggregator.aggregate([id1, sp1])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.mode == "idiomatic" }?.hitchesPer1k_p50, 5)
        XCTAssertEqual(rows.first { $0.mode == "raw" }?.hitchesPer1k_p50, 50)
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

    // MARK: - VelocityUI contract surfacing (Fix 3 — gated on `replay`, not warm/cold)

    func test_velocityUIContract_failureSurfacesInNotes() {
        // VelocityUI with nonzero net alloc/frame on the `replay` scenario →
        // contract violation → must appear in NOTES with explicit wording.
        let bad = makeRecord(
            runtime: "velocityui", mode: "idiomatic", profile: "max", scenario: "replay",
            hitches: 0, netAllocBytes: 64_000, taskSpawns: 0
        )
        let rows = Aggregator.aggregate([bad])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("Phase 1 invariant breached"),
            "VelocityUI net alloc/frame over budget on replay must surface as contract violation")
        XCTAssertTrue(md.contains("❌"), "Q5 contract column must mark fail")
    }

    func test_velocityUIContract_passSurfacesAsCheckmark() {
        let good = makeRecord(
            runtime: "velocityui", mode: "idiomatic", profile: "max", scenario: "replay",
            hitches: 1, netAllocBytes: 0, taskSpawns: 0
        )
        let rows = Aggregator.aggregate([good])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("✅"))
        XCTAssertFalse(md.contains("Phase 1 invariant breached"))
    }

    func test_velocityUIContract_coldWarmAreInformationalNotGated() {
        // cold/warm rows must never show ✅/❌ — only `replay` is gated (Fix 3).
        let warmHighAlloc = makeRecord(
            runtime: "velocityui", mode: "idiomatic", profile: "max", scenario: "warm",
            hitches: 0, netAllocBytes: 2_000_000, taskSpawns: 0
        )
        let coldHighAlloc = makeRecord(
            runtime: "velocityui", mode: "idiomatic", profile: "max", scenario: "cold",
            hitches: 0, netAllocBytes: 2_000_000, taskSpawns: 0
        )
        let rows = Aggregator.aggregate([warmHighAlloc, coldHighAlloc])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertFalse(md.contains("✅"), "cold/warm must not be gated pass")
        XCTAssertFalse(md.contains("❌"), "cold/warm must not be gated fail")
        XCTAssertFalse(md.contains("Phase 1 invariant breached"),
            "cold/warm alloc numbers must not surface as contract violations — only replay is gated")
    }

    func test_velocityUIContract_taskSpawnViolationIsScenarioAgnostic() {
        // Task-spawn invariant is not scenario-scoped — a nonzero count on warm
        // must still be flagged even though alloc gating only applies to replay.
        let warmWithTaskSpawn = makeRecord(
            runtime: "velocityui", mode: "idiomatic", profile: "max", scenario: "warm",
            hitches: 0, netAllocBytes: 0, taskSpawns: 3
        )
        let rows = Aggregator.aggregate([warmWithTaskSpawn])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("Phase 1 invariant breached"),
            "nonzero task spawns must be flagged regardless of scenario")
    }

    // MARK: - Net-delta aggregation (Fix 1)

    func test_aggregate_netAllocPercentiles() {
        let runs = [10_000.0, -2_000.0, 30_000.0].enumerated().map { i, net in
            makeRecord(runtime: "velocityui", scenario: "replay", netAllocBytes: net, runIndex: i + 1)
        }
        let rows = Aggregator.aggregate(runs)
        XCTAssertEqual(rows.count, 1)
        // Percentile helper: p50 rank = ceil(0.5*3)=2 → sorted[-2000,10000,30000][1]=10000
        XCTAssertEqual(rows[0].netAllocBytesPerFrame_p50 ?? -1, 10_000, accuracy: 0.01)
        XCTAssertEqual(rows[0].netAllocBytesPerFrame_p99 ?? -1, 30_000, accuracy: 0.01)
    }

    // MARK: - Old-format JSON compatibility (review finding F1)

    // Regression guard: BenchmarkReporterCore/Report.swift originally declared
    // netAllocDeltaPerFrameBytes as a non-optional Double. Every result JSON
    // written before VelocityUI-ah8.4 lacks that key entirely, so JSONDecoder's
    // synthesized Decodable failed with keyNotFound on every one of them —
    // Loader.load skipped all 36 files in a real pre-existing results directory
    // and the reporter exited with "no benchmark reports found", even though
    // avgAllocDeltaPerFrameBytes (the retained field) was right there. This
    // fixture is byte-for-byte the shape BenchmarkOrchestrator wrote before
    // this bead (see results/2026-07-27T21-38-49Z/*.json) — memoryStats has
    // only peakPhysFootprintBytes + avgAllocDeltaPerFrameBytes, and the
    // gray/thumbnail transition counts are absent too.
    private static let oldFormatReportJSON = """
    {
        "frameStats": {
            "p50FrameTimeMs": 16.6678,
            "totalFrames": 1739,
            "maxFrameTimeMs": 16.7005,
            "hitchesPerThousand": 0,
            "p99FrameTimeMs": 16.6678,
            "sustainedFrameRateHz": 59.9958,
            "hitchCount": 0
        },
        "taskSpawnCount": 0,
        "runtime": "velocityui",
        "captureDurationSeconds": 30.0035,
        "memoryStats": {
            "avgAllocDeltaPerFrameBytes": 2054587.38,
            "peakPhysFootprintBytes": 81887952
        },
        "warmupDiscardedSeconds": 1,
        "metricKitSnapshots": []
    }
    """

    func test_oldFormatJSON_decodesSuccessfully() throws {
        let data = Data(Self.oldFormatReportJSON.utf8)
        let report = try JSONDecoder().decode(BenchmarkReport.self, from: data)
        XCTAssertEqual(report.runtime, "velocityui")
        XCTAssertNil(report.memoryStats.netAllocDeltaPerFrameBytes,
            "missing key must decode to nil, not throw and not fabricate 0")
        XCTAssertEqual(report.memoryStats.avgAllocDeltaPerFrameBytes, 2054587.38, accuracy: 0.01,
            "the retained field must still parse — this is the whole point of keeping it")
        XCTAssertNil(report.grayToImageTransitionCount)
        XCTAssertNil(report.thumbnailToImageTransitionCount)
    }

    func test_oldFormatJSON_loaderAcceptsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("velocityui__idiomatic__medium__warm__1.json")
        try Data(Self.oldFormatReportJSON.utf8).write(to: fileURL)

        let records = try Loader.load(directory: dir)
        XCTAssertEqual(records.count, 1, "an old-format file must not be skipped")
        XCTAssertNil(records[0].report.memoryStats.netAllocDeltaPerFrameBytes)
    }

    func test_aggregate_allRunsMissingNetAlloc_yieldsNilNotZero() {
        let runs = (1...3).map { i in
            makeRecord(runtime: "velocityui", scenario: "warm", netAllocBytes: nil, runIndex: i)
        }
        let rows = Aggregator.aggregate(runs)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].netAllocBytesPerFrame_p50, "absent data must aggregate to nil, never a fabricated 0")
        XCTAssertNil(rows[0].netAllocBytesPerFrame_p99)
    }

    func test_aggregate_mixedNetAllocPresence_onlyCountsPresentValues() {
        let withData = makeRecord(runtime: "velocityui", scenario: "warm", netAllocBytes: 1_000, runIndex: 1)
        let withoutData = makeRecord(runtime: "velocityui", scenario: "warm", netAllocBytes: nil, runIndex: 2)
        let rows = Aggregator.aggregate([withData, withoutData])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].netAllocBytesPerFrame_p50 ?? -1, 1_000, accuracy: 0.01,
            "percentile must be computed from the one present value, not treat the missing run as 0")
    }

    func test_csv_missingNetAllocRendersEmptyNotZero() {
        let row = makeRecord(runtime: "velocityui", scenario: "warm", netAllocBytes: nil)
        let csv = CSVWriter.render(Aggregator.aggregate([row]))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let cells = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // header: runtime,mode,profile,scenario,runs,hitches_p50,hitches_p99,frame_p50,frame_p99,
        // frame_max,burst_p50,burst_p99,net_alloc_p50(idx12),net_alloc_p99(idx13),...
        XCTAssertEqual(cells[12], "", "missing net-alloc must render as an empty CSV cell, not \"0.0000\"")
        XCTAssertEqual(cells[13], "")
    }

    func test_csv_headerUsesFootprintBurstNaming() {
        // The burst metric is a footprint burst-SIZE, not a per-frame rate —
        // the CSV header must say so (VelocityUI-7iy). Values stay raw bytes.
        // Asserts the full header field list (rather than a substring
        // absence check) so this test never has to spell out the retired
        // per-frame-rate header name that VelocityUI-7iy killed.
        let row = makeRecord(runtime: "velocityui", allocBytes: 2_600_000)
        let csv = CSVWriter.render(Aggregator.aggregate([row]))
        let header = csv.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let expectedFields = [
            "runtime", "mode", "profile", "scenario", "runs",
            "hitches_per_1k_p50", "hitches_per_1k_p99",
            "frame_ms_p50", "frame_ms_p99", "frame_ms_max",
            "footprint_burst_bytes_p50", "footprint_burst_bytes_p99",
            "net_alloc_bytes_per_frame_p50", "net_alloc_bytes_per_frame_p99",
            "peak_rss_bytes_max",
            "fps_p50", "fps_p99",
            "task_spawn_count_max",
            "hitches_cov", "unstable"
        ]
        XCTAssertEqual(header.split(separator: ",").map(String.init), expectedFields)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let cells = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(cells[10], "2600000.0000", "CSV burst values stay raw bytes, not MB")
    }

    func test_markdown_replayRowMissingNetAlloc_rendersUnknownNotPass() {
        // A `replay` row with no net-alloc data (old-format JSON, hypothetically
        // relabeled) must never silently render as a passing ✅ — that would
        // hide the fact no measurement exists.
        let row = makeRecord(runtime: "velocityui", scenario: "replay", netAllocBytes: nil, taskSpawns: 0)
        let rows = Aggregator.aggregate([row])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("❓"), "missing net-alloc data on a gated replay row must render as unknown")
        XCTAssertFalse(md.contains("✅"), "must never fabricate a pass from absent data")
    }

    // MARK: - No-decode invariant NOTES surfacing (Fix 2)

    func test_noDecodeInvariant_violationSurfacesInNotes() {
        let violating = makeRecord(
            runtime: "velocityui", scenario: "replay",
            grayTransitions: 2, thumbnailTransitions: 0
        )
        let rows = Aggregator.aggregate([violating])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("No-decode invariant violated"))
        XCTAssertTrue(md.contains("Replay no-decode invariant violations"))
    }

    func test_noDecodeInvariant_cleanReplayDoesNotSurface() {
        let clean = makeRecord(runtime: "velocityui", scenario: "replay", grayTransitions: 0, thumbnailTransitions: 0)
        let rows = Aggregator.aggregate([clean])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertFalse(md.contains("No-decode invariant violated"))
    }

    func test_noDecodeInvariant_nonReplayScenarioNotChecked() {
        // Gray/thumbnail transitions are expected on cold/warm (decode-heavy by
        // design) — only `replay` asserts the no-decode invariant.
        let warmWithTransitions = makeRecord(
            runtime: "velocityui", scenario: "warm", grayTransitions: 5, thumbnailTransitions: 3
        )
        let rows = Aggregator.aggregate([warmWithTransitions])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertFalse(md.contains("No-decode invariant violated"))
    }

    // MARK: - CSV shape

    func test_csv_headerAndRowShape() {
        let row = makeRecord(runtime: "uicollectionview", hitches: 3.5)
        let csv = CSVWriter.render(Aggregator.aggregate([row]))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].split(separator: ",").count, 20)
        XCTAssertTrue(lines[1].hasPrefix("uicollectionview,idiomatic,medium,warm,1,"))
    }

    func test_markdown_burstColumnRendersMB() {
        // The burst metric (avgAllocDeltaPerFrameBytes) is a footprint burst-SIZE,
        // not a per-frame rate — VelocityUI-7iy renames the column to `burst MB`
        // and renders it in MB so a skimmed table can't misread it as a rate.
        let row = makeRecord(runtime: "velocityui", scenario: "warm", allocBytes: 2_600_000)
        let rows = Aggregator.aggregate([row])
        let md = MarkdownWriter.render(rows, stamp: "test")
        XCTAssertTrue(md.contains("burst MB p99"), "Q1-Q4 header must use burst MB naming")
        XCTAssertTrue(md.contains("burst MB p50"), "Q5 header must use burst MB naming")
        XCTAssertTrue(md.contains("2.48"), "2_600_000 bytes / 1_048_576 rounded to 2 decimals must render as 2.48")
        XCTAssertFalse(md.contains("2600000"), "raw byte count must never appear in a burst column")
    }

    func test_markdown_emitsAllFiveSections() {
        let r1 = makeRecord(runtime: "velocityui", mode: "idiomatic", scenario: "warm")
        let r2 = makeRecord(runtime: "uicollectionview", mode: "raw", scenario: "cold")
        let md = MarkdownWriter.render(Aggregator.aggregate([r1, r2]), stamp: "test")
        XCTAssertTrue(md.contains("Q1 — Library advantage out of the box"))
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
        netAllocBytes: Double? = 0,
        taskSpawns: Int = 0,
        grayTransitions: Int = 0,
        thumbnailTransitions: Int = 0,
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
                avgAllocDeltaPerFrameBytes: allocBytes,
                netAllocDeltaPerFrameBytes: netAllocBytes
            ),
            taskSpawnCount: taskSpawns,
            metricKitSnapshots: [],
            grayToImageTransitionCount: grayTransitions,
            thumbnailToImageTransitionCount: thumbnailTransitions
        )
        return RunRecord(
            runtime: runtime, mode: mode, profile: profile, scenario: scenario,
            runIndex: runIndex, report: report
        )
    }
}

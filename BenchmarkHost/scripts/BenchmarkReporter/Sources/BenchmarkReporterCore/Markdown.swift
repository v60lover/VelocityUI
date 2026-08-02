// Markdown.swift
//
// The Markdown report is the human-facing face. Grouped by question — not by
// runtime, not by date — so the reader cannot accidentally average across
// asymmetries that matter (cold vs warm, idiomatic vs same-pipeline, engine
// cost vs pipeline cost).
//
// Honesty rules baked into the emitter:
//   • Never average cold + warm (different sections)
//   • Never average across image modes (different sections)
//   • Always show p99 alongside p50
//   • Variance > 15% → `⚠ unstable` annotation, surfaced both inline and in
//     a top-level NOTES section
//   • Losses for VelocityUI get the same emphasis as wins — Q5 table lists
//     the contract clauses VelocityUI must satisfy (alloc=0, task-spawn=0)
//     even when other runtimes are noisier on the same metric

import Foundation

public enum MarkdownWriter {
    public static func render(_ rows: [AggregatedRow], stamp: String) -> String {
        var out = ""
        out += "# BenchmarkHost report — \(stamp)\n\n"
        out += summary(rows)
        out += "\n---\n\n"
        out += questionSection(
            "Q1 — Engine cost (same-pipeline)",
            why: "Same image-source pipeline across runtimes. What's left is the engine's overhead.",
            rows: rows.filter { $0.mode == "same-pipeline" }
        )
        out += questionSection(
            "Q2 — Real-world feel (idiomatic)",
            why: "Each runtime gets its preferred image-source. This is what adopters will see.",
            rows: rows.filter { $0.mode == "idiomatic" }
        )
        out += questionSection(
            "Q3 — Cold launch",
            why: "First scroll without a warmed cache. Measures dropped frames during decode + layout pressure.",
            rows: rows.filter { $0.scenario == "cold" }
        )
        out += questionSection(
            "Q4 — Steady state (warm)",
            why: "Each cell entering the viewport is fresh content the engine has not seen — same production path as normal feed scroll, minus first-second launch jitter. Process is warm (frameworks loaded), but no pre-warming of image caches, layout caches, or GPU textures.",
            rows: rows.filter { $0.scenario == "warm" }
        )
        out += contractSection(rows)
        out += notesSection(rows)
        out += footnotes()
        return out
    }

    // MARK: - Sections

    private static func summary(_ rows: [AggregatedRow]) -> String {
        let runtimes = Set(rows.map(\.runtime)).count
        let combos = Set(rows.map { "\($0.runtime)|\($0.mode)|\($0.profile)|\($0.scenario)" }).count
        let totalRuns = rows.reduce(0) { $0 + $1.runCount }
        let unstable = rows.filter { $0.hitchesPer1k_cov > 0.15 }.count
        var s = "## Summary\n\n"
        s += "- **Runtimes:** \(runtimes)\n"
        s += "- **Combos:** \(combos)\n"
        s += "- **Total runs:** \(totalRuns)\n"
        s += "- **Unstable combos (CoV>15%):** \(unstable)\n"
        return s
    }

    private static func questionSection(_ title: String, why: String, rows: [AggregatedRow]) -> String {
        var s = "## \(title)\n\n"
        s += "_\(why)_\n\n"
        guard !rows.isEmpty else {
            s += "_No data._\n\n---\n\n"
            return s
        }
        s += "| runtime | mode | profile | scenario | runs | hitches/1k p50 | hitches/1k p99 | frame ms p50 | frame ms p99 | frame ms max | burst MB p99 | peak RSS (MB) | fps p50 | tasks max |\n"
        s += "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
        for r in rows {
            let unstable = r.hitchesPer1k_cov > 0.15 ? " ⚠" : ""
            let rss = Double(r.peakRSSBytes_max) / (1024 * 1024)
            s += "| \(r.runtime) | \(r.mode) | \(r.profile) | \(r.scenario) | \(r.runCount) "
            s += "| \(fmt(r.hitchesPer1k_p50))\(unstable) "
            s += "| \(fmt(r.hitchesPer1k_p99)) "
            s += "| \(fmt(r.frameTimeMs_p50)) "
            s += "| \(fmt(r.frameTimeMs_p99)) "
            s += "| \(fmt(r.frameTimeMs_max)) "
            s += "| \(fmtMB(r.footprintBurstBytes_p99)) "
            s += "| \(String(format: "%.1f", rss)) "
            s += "| \(fmt(r.fps_p50)) "
            s += "| \(r.taskSpawnCount_max) |\n"
        }
        s += "\n---\n\n"
        return s
    }

    /// Budget for the `replay` scenario's net alloc/frame gate — see Fix 3 of
    /// VelocityUI-ah8.4. Expected real value is ~0-2 KB/frame; the headroom is
    /// for OS/CA noise. Tighten after the first device run.
    private static let q5NetAllocBudgetBytesPerFrame: Double = 16_384

    private static func contractSection(_ rows: [AggregatedRow]) -> String {
        var s = "## Q5 — Phase 1 contract\n\n"
        s += "_VelocityUI's Phase 1 contract: zero heap allocations per scroll frame, zero Task spawns on the scroll path. Gated on the `replay` scenario's net alloc/frame (true per-frame rate, budget \(Int(q5NetAllocBudgetBytesPerFrame / 1024)) KB) and tasks max — `cold`/`warm` rows are informational only (decode-pipeline churn is expected there by design). Other runtimes report as-is for comparison._\n\n"
        s += "| runtime | mode | profile | scenario | burst MB p50 | burst MB p99 | net alloc B/frame p50 | net alloc B/frame p99 | tasks max | pass? |\n"
        s += "|---|---|---|---|---:|---:|---:|---:|---:|:---:|\n"
        let sorted = rows.sorted { (a, b) -> Bool in
            // Put VelocityUI rows first so the contract owner is unmissable.
            if (a.runtime == "velocityui") != (b.runtime == "velocityui") {
                return a.runtime == "velocityui"
            }
            return a.runtime < b.runtime
        }
        for r in sorted {
            let isGatedRow = r.runtime == "velocityui" && r.scenario == "replay"
            let pass: String
            if isGatedRow {
                if let net = r.netAllocBytesPerFrame_p99 {
                    pass = (net <= q5NetAllocBudgetBytesPerFrame && r.taskSpawnCount_max == 0) ? "✅" : "❌"
                } else {
                    // Replay row with no net-alloc data (pre-ah8.4 result JSON) —
                    // never silently pass on absent data.
                    pass = "❓"
                }
            } else {
                pass = "—"
            }
            s += "| \(r.runtime) | \(r.mode) | \(r.profile) | \(r.scenario) "
            s += "| \(fmtMB(r.footprintBurstBytes_p50)) "
            s += "| \(fmtMB(r.footprintBurstBytes_p99)) "
            s += "| \(fmtOpt(r.netAllocBytesPerFrame_p50)) "
            s += "| \(fmtOpt(r.netAllocBytesPerFrame_p99)) "
            s += "| \(r.taskSpawnCount_max) "
            s += "| \(pass) |\n"
        }
        s += "\n---\n\n"
        return s
    }

    private static func notesSection(_ rows: [AggregatedRow]) -> String {
        var s = "## NOTES\n\n"
        let unstable = rows.filter { $0.hitchesPer1k_cov > 0.15 }
        // Alloc violations are scoped to `replay` — cold/warm are informational
        // decode-pipeline churn by design (see Q5 section). Task-spawn is not
        // scenario-scoped: the "zero Task spawns on the scroll path" invariant
        // applies regardless of which scenario is driving the scroll.
        let velocityFails = rows.filter { r in
            guard r.runtime == "velocityui" else { return false }
            if r.taskSpawnCount_max > 0 { return true }
            if r.scenario == "replay", let net = r.netAllocBytesPerFrame_p99, net > q5NetAllocBudgetBytesPerFrame { return true }
            return false
        }
        let noDecodeViolations = rows.filter { r in
            r.runtime == "velocityui" && r.scenario == "replay" &&
            (r.grayToImageTransitionCount_max > 0 || r.thumbnailToImageTransitionCount_max > 0)
        }
        if unstable.isEmpty && velocityFails.isEmpty && noDecodeViolations.isEmpty {
            s += "- No unstable combos. No VelocityUI contract violations.\n\n"
            return s
        }
        if !unstable.isEmpty {
            s += "### Unstable combos (CoV > 15%)\n\n"
            for r in unstable {
                s += "- `\(r.runtime) / \(r.mode) / \(r.profile) / \(r.scenario)` — "
                s += "hitches/1k CoV=\(String(format: "%.1f%%", r.hitchesPer1k_cov * 100)), "
                s += "p50=\(fmt(r.hitchesPer1k_p50)), p99=\(fmt(r.hitchesPer1k_p99)), n=\(r.runCount)\n"
            }
            s += "\n"
        }
        if !velocityFails.isEmpty {
            s += "### VelocityUI contract violations\n\n"
            for r in velocityFails {
                s += "- `\(r.mode) / \(r.profile) / \(r.scenario)` — "
                s += "net alloc B/frame p99=\(fmtOpt(r.netAllocBytesPerFrame_p99)), tasks max=\(r.taskSpawnCount_max). "
                s += "**Phase 1 invariant breached.**\n"
            }
            s += "\n"
        }
        if !noDecodeViolations.isEmpty {
            s += "### Replay no-decode invariant violations\n\n"
            s += "_The `replay` scenario's measured pass must observe zero gray/thumbnail→image transitions — the replay range is bounded to fit inside the image cache specifically so no decode should fire during capture. A nonzero count here means the bound was violated (cache eviction mid-capture) or the invariant genuinely regressed._\n\n"
            for r in noDecodeViolations {
                s += "- `\(r.mode) / \(r.profile)` — "
                s += "gray→image max=\(r.grayToImageTransitionCount_max), thumbnail→image max=\(r.thumbnailToImageTransitionCount_max). "
                s += "**No-decode invariant violated.**\n"
            }
            s += "\n"
        }
        return s
    }

    private static func footnotes() -> String {
        var s = "## Methodology footnotes\n\n"
        s += "- p50/p99 across runs are computed from per-run aggregates (hitches/1k frames, p50/p99 frame time). The app collapses raw frames before reporting; pooling raw frames across runs is not possible from this data.\n"
        s += "- Variance flag: coefficient of variation on hitches/1k frames > 15% across runs. Surfaced inline (⚠) and in NOTES.\n"
        s += "- `cold` skips the warm-up scroll; `warm` waits 1s for process settle, then measures a fresh-content scroll with the first second of frames discarded — steady-state user experience, not cache-hit replay. The `warmupDiscardedSeconds` field in each JSON report documents the discard window applied.\n"
        s += "- `replay` is the Phase 1 contract scenario: a warm-up pass fills the cache over a range bounded to fit inside it (~30 items), then the SAME range is measured a second time — a cache-hit replay with no decode expected. `burst MB p50/p99` is the mean footprint burst-step size in MB (not a rate — see AllocationProbe.summarize); `net alloc B/frame p50/p99` is the true per-frame allocation rate ((last-first)/(count-1) across the capture window) and is what Q5 gates on for `replay` rows.\n"
        s += "- Simulator numbers are NOT publishable. Run the full matrix on a physical device (`scripts/run.sh --device …`).\n"
        s += "- Q5 pass column: `—` = not a gated row (cold/warm, or a non-velocityui runtime). `❓` = a gated `replay` row from a result JSON written before net-alloc tracking existed (pre-VelocityUI-ah8.4) — absent data, never silently scored as a pass.\n"
        return s
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    /// Renders a byte count as MB with 2 decimals. Burst-size columns use this
    /// — raw 7-digit byte counts invite the "per frame" misreading this rename
    /// exists to kill (see VelocityUI-7iy). Net-alloc columns stay byte-rendered
    /// via `fmt`/`fmtOpt` — they are small, honestly named, and don't need it.
    private static func fmtMB(_ bytes: Double) -> String {
        String(format: "%.2f", bytes / 1_048_576)
    }

    /// "—" (not a fabricated 0) for a value absent from every run in the
    /// bucket — pre-ah8.4 result JSONs don't carry net-alloc data.
    private static func fmtOpt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return fmt(v)
    }
}

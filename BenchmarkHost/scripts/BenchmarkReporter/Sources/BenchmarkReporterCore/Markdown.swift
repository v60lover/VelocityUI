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
        s += "| runtime | mode | profile | scenario | runs | hitches/1k p50 | hitches/1k p99 | frame ms p50 | frame ms p99 | frame ms max | alloc B/frame p99 | peak RSS (MB) | fps p50 | tasks max |\n"
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
            s += "| \(fmt(r.allocBytesPerFrame_p99)) "
            s += "| \(String(format: "%.1f", rss)) "
            s += "| \(fmt(r.fps_p50)) "
            s += "| \(r.taskSpawnCount_max) |\n"
        }
        s += "\n---\n\n"
        return s
    }

    private static func contractSection(_ rows: [AggregatedRow]) -> String {
        var s = "## Q5 — Phase 1 contract\n\n"
        s += "_VelocityUI's Phase 1 contract: zero heap allocations per scroll frame, zero Task spawns on the scroll path. Other runtimes report as-is for comparison._\n\n"
        s += "| runtime | mode | profile | scenario | alloc B/frame p50 | alloc B/frame p99 | tasks max | pass? |\n"
        s += "|---|---|---|---|---:|---:|---:|:---:|\n"
        let sorted = rows.sorted { (a, b) -> Bool in
            // Put VelocityUI rows first so the contract owner is unmissable.
            if (a.runtime == "velocityui") != (b.runtime == "velocityui") {
                return a.runtime == "velocityui"
            }
            return a.runtime < b.runtime
        }
        for r in sorted {
            let isVelocityUI = r.runtime == "velocityui"
            let pass: String
            if isVelocityUI {
                pass = (r.allocBytesPerFrame_p99 == 0 && r.taskSpawnCount_max == 0) ? "✅" : "❌"
            } else {
                pass = "—"
            }
            s += "| \(r.runtime) | \(r.mode) | \(r.profile) | \(r.scenario) "
            s += "| \(fmt(r.allocBytesPerFrame_p50)) "
            s += "| \(fmt(r.allocBytesPerFrame_p99)) "
            s += "| \(r.taskSpawnCount_max) "
            s += "| \(pass) |\n"
        }
        s += "\n---\n\n"
        return s
    }

    private static func notesSection(_ rows: [AggregatedRow]) -> String {
        var s = "## NOTES\n\n"
        let unstable = rows.filter { $0.hitchesPer1k_cov > 0.15 }
        let velocityFails = rows.filter {
            $0.runtime == "velocityui" &&
            ($0.allocBytesPerFrame_p99 > 0 || $0.taskSpawnCount_max > 0)
        }
        if unstable.isEmpty && velocityFails.isEmpty {
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
                s += "alloc B/frame p99=\(fmt(r.allocBytesPerFrame_p99)), tasks max=\(r.taskSpawnCount_max). "
                s += "**Phase 1 invariant breached.**\n"
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
        s += "- Simulator numbers are NOT publishable. Run the full matrix on a physical device (`scripts/run.sh --device …`).\n"
        return s
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}

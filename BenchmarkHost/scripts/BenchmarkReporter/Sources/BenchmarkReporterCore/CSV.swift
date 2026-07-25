// CSV.swift

import Foundation

public enum CSVWriter {
    /// One row per (runtime, mode, profile, scenario). Header is stable so a
    /// CI diff against the previous run can be cell-level. The CSV is the
    /// machine-readable face of the report — keep field names verbose enough
    /// that nobody has to look at this file to understand them.
    public static func render(_ rows: [AggregatedRow]) -> String {
        let header = [
            "runtime", "mode", "profile", "scenario", "runs",
            "hitches_per_1k_p50", "hitches_per_1k_p99",
            "frame_ms_p50", "frame_ms_p99", "frame_ms_max",
            "alloc_bytes_per_frame_p50", "alloc_bytes_per_frame_p99",
            "peak_rss_bytes_max",
            "fps_p50", "fps_p99",
            "task_spawn_count_max",
            "hitches_cov", "unstable"
        ].joined(separator: ",")

        var lines: [String] = [header]
        for row in rows {
            let cells: [String] = [
                row.runtime, row.mode, row.profile, row.scenario, "\(row.runCount)",
                fmt(row.hitchesPer1k_p50), fmt(row.hitchesPer1k_p99),
                fmt(row.frameTimeMs_p50), fmt(row.frameTimeMs_p99), fmt(row.frameTimeMs_max),
                fmt(row.allocBytesPerFrame_p50), fmt(row.allocBytesPerFrame_p99),
                "\(row.peakRSSBytes_max)",
                fmt(row.fps_p50), fmt(row.fps_p99),
                "\(row.taskSpawnCount_max)",
                fmt(row.hitchesPer1k_cov),
                row.hitchesPer1k_cov > 0.15 ? "true" : "false"
            ]
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.4f", v)
    }
}

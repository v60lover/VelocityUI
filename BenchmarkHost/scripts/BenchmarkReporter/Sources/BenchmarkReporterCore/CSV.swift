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
            "footprint_burst_bytes_p50", "footprint_burst_bytes_p99",
            "net_alloc_bytes_per_frame_p50", "net_alloc_bytes_per_frame_p99",
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
                fmt(row.footprintBurstBytes_p50), fmt(row.footprintBurstBytes_p99),
                fmtOpt(row.netAllocBytesPerFrame_p50), fmtOpt(row.netAllocBytesPerFrame_p99),
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

    /// Empty cell (not "0.0000") for a value absent from every run in the
    /// bucket — a fabricated 0 in a numeric CSV column would read as a real,
    /// passing measurement to any downstream tool that parses this file.
    private static func fmtOpt(_ v: Double?) -> String {
        guard let v else { return "" }
        return fmt(v)
    }
}

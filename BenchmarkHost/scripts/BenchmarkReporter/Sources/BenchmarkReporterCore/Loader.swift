// Loader.swift

import Foundation

public enum Loader {
    public enum LoaderError: Error, CustomStringConvertible {
        case directoryNotFound(String)
        case noReports(String)

        public var description: String {
            switch self {
            case .directoryNotFound(let p): return "directory not found: \(p)"
            case .noReports(let p): return "no benchmark reports found in: \(p)"
            }
        }
    }

    /// Loads every JSON report in `directory` whose filename matches the
    /// orchestrator-emitted pattern. Files that fail filename parsing or JSON
    /// decode are reported to stderr and skipped — never silently dropped.
    public static func load(directory url: URL) throws -> [RunRecord] {
        let fm = FileManager.default
        guard let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
              isDir == true else {
            throw LoaderError.directoryNotFound(url.path)
        }
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var records: [RunRecord] = []
        for file in entries where file.pathExtension == "json" {
            let name = file.lastPathComponent
            guard let parsed = RunRecord.parseFilename(name) else {
                FileHandle.standardError.write(Data("skip: bad filename '\(name)'\n".utf8))
                continue
            }
            do {
                let data = try Data(contentsOf: file)
                let report = try decoder.decode(BenchmarkReport.self, from: data)
                records.append(RunRecord(
                    runtime: parsed.runtime,
                    mode: parsed.mode,
                    profile: parsed.profile,
                    scenario: parsed.scenario,
                    runIndex: parsed.runIndex,
                    report: report
                ))
            } catch {
                FileHandle.standardError.write(Data("skip: decode failed '\(name)': \(error)\n".utf8))
            }
        }
        if records.isEmpty {
            throw LoaderError.noReports(url.path)
        }
        return records
    }
}

// main.swift — BenchmarkReporter CLI

import Foundation
import BenchmarkReporterCore

let args = CommandLine.arguments
guard args.count >= 2 else {
    let exe = (args.first as NSString?)?.lastPathComponent ?? "BenchmarkReporter"
    FileHandle.standardError.write(Data("usage: \(exe) <results-directory>\n".utf8))
    exit(2)
}

let dir = URL(fileURLWithPath: args[1])

do {
    let records = try Loader.load(directory: dir)
    let rows = Aggregator.aggregate(records)

    let stamp = dir.lastPathComponent
    let csv = CSVWriter.render(rows)
    let md = MarkdownWriter.render(rows, stamp: stamp)

    let csvURL = dir.appendingPathComponent("report.csv")
    let mdURL = dir.appendingPathComponent("report.md")
    try csv.write(to: csvURL, atomically: true, encoding: .utf8)
    try md.write(to: mdURL, atomically: true, encoding: .utf8)
    print("wrote \(csvURL.path)")
    print("wrote \(mdURL.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

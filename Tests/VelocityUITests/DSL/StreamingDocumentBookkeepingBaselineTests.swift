// StreamingDocumentBookkeepingBaselineTests.swift

import XCTest
@testable import VelocityUI

final class StreamingDocumentBookkeepingBaselineTests: XCTestCase {
    @MainActor
    func testTwoHundredBlockAppendReportsSeparateBookkeepingCosts() {
        let controller = StreamingMarkdownController()
        controller.append((0..<199).map { "Paragraph \($0).\n\n" }.joined() + "Tail ")

        var previousTable = flatten(
            VStackNode { controller.renderNodes }, itemID: "message"
        )
        XCTAssertEqual(previousTable.children(of: 0).count, 200)

        var nodeTimes: [Double] = []
        var flattenTimes: [Double] = []
        var blockTimes: [Double] = []
        var diffTimes: [Double] = []
        var totalComparedBlocks = 0
        let initialStyleCalls = controller._styleCallCount

        for _ in 0..<40 {
            controller.append("x")
            let startNodes = ProcessInfo.processInfo.systemUptime
            let nodes = controller.renderNodes
            let startFlatten = ProcessInfo.processInfo.systemUptime
            let nextTable = flatten(VStackNode { nodes }, itemID: "message")
            let startBlocks = ProcessInfo.processInfo.systemUptime
            let previousBlocks = blocks(for: previousTable)
            let nextBlocks = blocks(for: nextTable)
            let startDiff = ProcessInfo.processInfo.systemUptime
            let change = diff(previous: previousBlocks, new: nextBlocks)
            let end = ProcessInfo.processInfo.systemUptime

            XCTAssertEqual(change.updated, [199])
            XCTAssertEqual(change.reused.count, 199)
            totalComparedBlocks += previousBlocks.count + nextBlocks.count
            nodeTimes.append((startFlatten - startNodes) * 1_000_000)
            flattenTimes.append((startBlocks - startFlatten) * 1_000_000)
            blockTimes.append((startDiff - startBlocks) * 1_000_000)
            diffTimes.append((end - startDiff) * 1_000_000)
            previousTable = nextTable
        }

        XCTAssertEqual(controller._styleCallCount - initialStyleCalls, 40)
        XCTAssertEqual(totalComparedBlocks, 16_000)
        print("[document-bookkeeping] blocks=200 updates=40 styled=40 compared=\(totalComparedBlocks)")
        print("[document-bookkeeping] nodes \(summary(nodeTimes))")
        print("[document-bookkeeping] flatten \(summary(flattenTimes))")
        print("[document-bookkeeping] block-lists \(summary(blockTimes))")
        print("[document-bookkeeping] block-diff \(summary(diffTimes))")
    }

    @MainActor
    private func blocks(for table: NodeTable) -> [Block] {
        let ordinals = table.leafOrdinals()
        return table.children(of: 0).compactMap { index in
            guard let contract = table.blockRenderContract(
                at: index, itemID: "message", logicalOrdinal: ordinals[index] ?? index
            ) else { return nil }
            return Block(contract: contract, id: index, frame: CGRect(x: 0, y: 0, width: 320, height: 0))
        }
    }

    private func summary(_ times: [Double]) -> String {
        let sorted = times.sorted()
        return "median=\(Int(sorted[sorted.count / 2]))us p99=\(Int(sorted[sorted.count - 1]))us"
    }
}

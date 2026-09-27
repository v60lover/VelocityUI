// StreamCostScenario.swift

import Foundation

/// Maps `--stream-fixture` / `--stream-script` names to a fixture-backed turn list and a script
/// (VelocityUI-ln1g.1). Unknown names return nil so a typo fails loudly instead of running the default.
enum StreamCostScenario {

    static func turns(fixture name: String) -> [StreamDataset.StreamTurn]? {
        if name == "many-messages" {
            return StreamFixture.manyMessages(count: 40).enumerated().map {
                StreamDataset.StreamTurn(userMessage: "Question \($0.offset)", assistantChunks: $0.element)
            }
        }
        if name == "large-stress" {
            return StreamStressDataset.turns()
        }
        let fixture: StreamFixture
        switch name {
        case "table-501-stable": fixture = .table(rows: 501, widths: .stable)
        case "table-1000-stable": fixture = .table(rows: 1000, widths: .stable)
        case "table-501-changing": fixture = .table(rows: 501, widths: .changing(growEvery: 25))
        case "table-1000-changing": fixture = .table(rows: 1000, widths: .changing(growEvery: 25))
        case "paragraph": fixture = .longParagraph(words: 2000)
        case "code": fixture = .longCode(lines: 600)
        default: return nil
        }
        return [StreamDataset.StreamTurn(userMessage: "Stream \(fixture.name)", assistantChunks: fixture.tokens)]
    }

    static func script(named name: String, tokenCount: Int) -> StreamScenarioScript? {
        switch name {
        case "in-view": return StreamScenarioScript.none
        case "offscreen": return .offscreen(from: tokenCount / 4, to: tokenCount * 3 / 4)
        case "evict": return .evictAndReenter(leaveAt: tokenCount / 5, returnAt: tokenCount * 9 / 10)
        case "width": return .widthChange(at: tokenCount / 2, narrowPadding: 40, restorePadding: 8)
        default: return nil
        }
    }
}

// IncrementalMarkdownParser+TestHooks.swift

import Foundation
import CoreGraphics

#if canImport(XCTest)
extension IncrementalMarkdownParser {
    /// Test-only: a sealed block's key/content must never differ from what an earlier
    /// snapshot already reported at the same index.
    func debugSealedPrefixMatches<ID: Hashable & Sendable>(_ previous: [Block], itemID: ID, width: CGFloat) -> Bool {
        let current = blockList(itemID: itemID, width: width)
        let count = min(previous.count, sealedBlocks.count)
        for i in 0..<count {
            guard previous[i].key == current[i].key, previous[i].contentHash == current[i].contentHash else {
                return false
            }
        }
        return true
    }
}
#endif

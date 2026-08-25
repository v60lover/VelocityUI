// HotBlockMeasurer+TestHooks.swift

#if canImport(UIKit)
import UIKit

#if canImport(XCTest)
extension HotBlockMeasurer {
    /// Test-only: (rangeStart, rangeLength) UTF-16 offsets for every fragment after a
    /// full ensured walk. Lets tests compute stable-prefix / re-laid-out counts.
    func _debugFragmentRanges() -> [(start: Int, length: Int)] {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var ranges: [(Int, Int)] = []
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let start = self.contentStorage.offset(
                from: self.layoutManager.documentRange.location, to: fragment.rangeInElement.location
            )
            let length = self.contentStorage.offset(
                from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation
            )
            ranges.append((start, length))
            return true
        }
        return ranges
    }

    /// Test-only: brute enumerate-from-top height — compared against
    /// `usageBoundsForTextContainer` in the height-parity test.
    func _debugEnumerateSumHeight() -> CGFloat {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return maxY
    }
}
#endif
#endif

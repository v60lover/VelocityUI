// RenderCellRevealMaskTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class RenderCellRevealMaskTests: XCTestCase {

    // MARK: - Helpers

    private func makeCell(size: CGSize = CGSize(width: 320, height: 400)) -> RenderCell {
        let cell = RenderCell()
        cell.layer.frame = CGRect(origin: .zero, size: size)
        return cell
    }

    private func textFragment(id: Int, frame: CGRect) -> Fragment {
        Fragment(
            id: id,
            content: .text(TextDescriptor(
                content: "Visible text", font: VFontDescriptor(size: 14, weight: 0),
                color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                lineLimit: nil, lineBreakMode: 0, layoutHash: id, appearanceHash: id
            )),
            frame: frame
        )
    }

    private func contentLayer(of cell: RenderCell) -> CALayer? {
        cell.layer.sublayers?.first { !($0 is CAGradientLayer) }
    }

    // MARK: - Test 1: Growth region gets an animated reveal mask

    func testGrowthRegionGetsAnimatedRevealMask() {
        let cell = makeCell()
        cell.applyLayout([textFragment(id: 1, frame: CGRect(x: 0, y: 0, width: 320, height: 40))])

        guard let contentLayer = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let sub = contentLayer.sublayers?.first else { XCTFail("sublayer missing"); return }

        let identity = cell.layerIdentityByFragmentID[1]!

        cell.applyRevealRegions([1: (from: 40, to: 100)])

        let mask = sub.mask as? CAGradientLayer
        XCTAssertNotNil(mask, "Sublayer must have a CAGradientLayer mask")
        XCTAssertTrue(mask === cell.revealMaskLayers[identity], "Mask must match stored revealMaskLayers entry")

        XCTAssertEqual(mask!.frame, CGRect(x: 0, y: 0, width: 320, height: 100),
            "Mask frame height must match region.to")

        let locationsDoubles = (mask?.locations ?? []).map { $0.doubleValue }
        XCTAssertEqual(locationsDoubles.count, 4, "Resting mask must have 4 gradient stops")
        for (index, expected) in [0.0, 1.0, 1.0, 1.0].enumerated() where index < locationsDoubles.count {
            XCTAssertEqual(locationsDoubles[index], expected, accuracy: 0.001,
                "Mask model locations must be at resting state [0, 1, 1, 1]")
        }

        guard let anim = mask?.animation(forKey: "revealRamp") as? CABasicAnimation else {
            XCTFail("Mask must have a CABasicAnimation attached with key 'revealRamp'")
            return
        }
        XCTAssertEqual(anim.keyPath, "locations", "Animation must target the locations keyPath")
    }

    // MARK: - Test 2: Animation's fromValue encodes correct partial-reveal fraction

    func testAnimationFromValueEncodesPartialRevealFraction() {
        let cell = makeCell()
        cell.applyLayout([textFragment(id: 1, frame: CGRect(x: 0, y: 0, width: 320, height: 40))])

        guard let contentLayer = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let sub = contentLayer.sublayers?.first else { XCTFail("sublayer missing"); return }

        cell.applyRevealRegions([1: (from: 25, to: 100)])

        guard let mask = sub.mask as? CAGradientLayer,
              let anim = mask.animation(forKey: "revealRamp") as? CABasicAnimation,
              let fromValue = anim.fromValue as? [NSNumber] else {
            XCTFail("Expected animation with fromValue array")
            return
        }

        XCTAssertEqual(fromValue[0].doubleValue, 0, accuracy: 0.001)
        XCTAssertEqual(fromValue[1].doubleValue, 0.25, accuracy: 0.001,
            "Second element encodes from/to fraction (25/100 = 0.25)")
        XCTAssertEqual(fromValue[3].doubleValue, 1, accuracy: 0.001)
    }

    // MARK: - Test 3: Fragment with no growth region is untouched

    func testFragmentWithoutGrowthRegionUntouched() {
        let cell = makeCell()
        cell.applyLayout([
            textFragment(id: 1, frame: CGRect(x: 0, y: 0, width: 320, height: 40)),
            textFragment(id: 2, frame: CGRect(x: 0, y: 40, width: 320, height: 40)),
        ])

        guard let contentLayer = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sublayers = contentLayer.sublayers ?? []
        guard sublayers.count >= 2 else { XCTFail("expected at least 2 sublayers"); return }

        cell.applyRevealRegions([1: (from: 40, to: 100)])

        XCTAssertNil(sublayers[1].mask, "Fragment 2 must have no mask (not in regions dict)")
    }

    // MARK: - Test 4: region.from >= region.to (no actual growth) is skipped

    func testNoActualGrowthSkippedNoMaskCreated() {
        let cell = makeCell()
        cell.applyLayout([textFragment(id: 3, frame: CGRect(x: 0, y: 0, width: 320, height: 40))])

        guard let contentLayer = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let sub = contentLayer.sublayers?.first else { XCTFail("sublayer missing"); return }

        let identity = cell.layerIdentityByFragmentID[3]!

        cell.applyRevealRegions([3: (from: 100, to: 100)])

        XCTAssertNil(sub.mask, "Equal from/to must not create a mask")
        XCTAssertNil(cell.revealMaskLayers[identity], "revealMaskLayers must not contain entry for no-growth region")
    }

    // MARK: - Test 5: Empty regions dict is a no-op

    func testEmptyRegionsDictNoOp() {
        let cell = makeCell()
        cell.applyLayout([textFragment(id: 1, frame: CGRect(x: 0, y: 0, width: 320, height: 40))])

        guard let contentLayer = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let sub = contentLayer.sublayers?.first else { XCTFail("sublayer missing"); return }

        cell.applyRevealRegions([:])

        XCTAssertNil(sub.mask, "Empty dict must be a no-op; no mask should appear")
    }

    // MARK: - Test 6: Second call reuses mask and bumps generation

    func testSecondCallReusesMaskAndBumpsGeneration() {
        let cell = makeCell()
        cell.applyLayout([textFragment(id: 4, frame: CGRect(x: 0, y: 0, width: 320, height: 40))])

        guard let contentLayer = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let sub = contentLayer.sublayers?.first else { XCTFail("sublayer missing"); return }

        let identity = cell.layerIdentityByFragmentID[4]!

        cell.applyRevealRegions([4: (from: 10, to: 50)])

        let firstGeneration = cell.revealGeneration[identity]!
        let firstMask = sub.mask as? CAGradientLayer
        XCTAssertNotNil(firstMask, "First call must create a mask")

        cell.applyRevealRegions([4: (from: 50, to: 90)])

        let secondGeneration = cell.revealGeneration[identity]!
        let secondMask = sub.mask as? CAGradientLayer

        XCTAssertEqual(secondGeneration, firstGeneration + 1,
            "Generation must increment on second call")
        XCTAssertTrue(secondMask === firstMask,
            "Mask object must be reused (same identity)")
        XCTAssertEqual(secondMask?.frame.height, 90,
            "Mask frame must update to new region.to")
    }
}
#endif

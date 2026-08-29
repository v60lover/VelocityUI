import XCTest
import CoreGraphics
@testable import VelocityUI

@MainActor
final class VisibleBlockStoreTests: XCTestCase {
    private func image(width: Int = 10, height: Int = 10) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func key(_ index: Int) -> BlockKey { BlockKey(itemID: "item", index: index) }

    func testDemoteThenPromote_MovesSameBitmapWithoutRerasterizing() {
        let resident = VisibleBlockStore()
        let cache = FrozenBitmapStore(byteBudget: 10_000)
        let block = key(0)
        let bitmap = image()

        resident.store(bitmap, size: CGSize(width: 10, height: 10), for: block)
        resident.demote([block], to: cache)
        XCTAssertNil(resident.bitmap(for: block))
        XCTAssertTrue(cache.bitmap(for: block) === bitmap)

        resident.promote([block], from: cache)
        XCTAssertTrue(resident.bitmap(for: block) === bitmap)
        XCTAssertNil(cache.bitmap(for: block), "Promotion transfers ownership out of the evictable tier")
    }

    func testDemoteThenPromote_PreservesCodeBodyRasterIdentity() {
        let resident = VisibleBlockStore()
        let cache = FrozenBitmapStore(byteBudget: 10_000)
        let block = key(0)
        let bitmap = image()
        let identity = CodeBodyRasterIdentity(themeGeneration: 7, scale: 3)

        resident.store(bitmap, size: CGSize(width: 10, height: 10), for: block, codeBodyIdentity: identity)
        resident.demote([block], to: cache)
        XCTAssertTrue(cache.codeBodyRaster(for: block, identity: identity)?.image === bitmap)

        resident.promote([block], from: cache)
        XCTAssertTrue(resident.codeBodyRaster(for: block, identity: identity)?.image === bitmap)

        resident.demote([block], to: cache)
        XCTAssertTrue(cache.codeBodyRaster(for: block, identity: identity)?.image === bitmap)
        XCTAssertNil(
            cache.codeBodyRaster(
                for: block,
                identity: CodeBodyRasterIdentity(themeGeneration: 8, scale: 3)
            )
        )
    }

    func testActualBitmapCost_UsesBytesPerRowAndPixelHeight() {
        let resident = VisibleBlockStore()
        let bitmap = image(width: 13, height: 7)
        resident.store(bitmap, size: CGSize(width: 13, height: 7), for: key(0))

        XCTAssertEqual(resident.currentByteTotal, bitmap.bytesPerRow * bitmap.height)
    }

    func testOversizedVisibleSet_RemainsResidentAndDoesNotThrash() {
        let resident = VisibleBlockStore(targetByteBudget: 1)
        let bitmaps = (0..<4).map { _ in image(width: 100, height: 100) }
        for (index, bitmap) in bitmaps.enumerated() {
            resident.store(bitmap, size: CGSize(width: 100, height: 100), for: key(index))
        }

        XCTAssertGreaterThan(resident.currentByteTotal, resident.targetByteBudget)
        for (index, bitmap) in bitmaps.enumerated() {
            XCTAssertTrue(resident.bitmap(for: key(index)) === bitmap,
                          "Visible block \(index) must survive a resident-budget overage")
        }
    }

    func testMemoryPressureClearsInactiveCacheBeforeResidentContent() {
        let resident = VisibleBlockStore()
        let cache = FrozenBitmapStore(byteBudget: 10_000)
        let active = key(0)
        let inactive = key(1)
        let activeBitmap = image()

        resident.store(activeBitmap, size: CGSize(width: 10, height: 10), for: active)
        cache.store(image(), size: CGSize(width: 10, height: 10), cost: 400, for: inactive)
        cache.handleMemoryPressure()

        XCTAssertNil(cache.bitmap(for: inactive))
        XCTAssertTrue(resident.bitmap(for: active) === activeBitmap)
    }

    func testTeardown_ReleasesResidentStore() {
        weak var weakStore: VisibleBlockStore?
        do {
            var store: VisibleBlockStore? = VisibleBlockStore()
            weakStore = store
            store?.store(image(), size: CGSize(width: 10, height: 10), for: key(0))
            store = nil
        }
        XCTAssertNil(weakStore)
    }
}

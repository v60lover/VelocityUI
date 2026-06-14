// RenderCellTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class RenderCellTests: XCTestCase {

    // MARK: - Helpers

    private func makeCell(size: CGSize = CGSize(width: 320, height: 400)) -> RenderCell {
        let cell = RenderCell()
        cell.layer.frame = CGRect(origin: .zero, size: size)
        return cell
    }

    private func imageFragment(id: Int, frame: CGRect) -> Fragment {
        Fragment(
            id: id,
            content: .image(ImageDescriptor(
                url: nil, aspectRatio: 1.0, contentMode: 0,
                cornerRadius: 0, layoutHash: id, appearanceHash: id
            )),
            frame: frame
        )
    }

    private func geometryFragment(id: Int, frame: CGRect) -> Fragment {
        Fragment(id: id, content: .geometry, frame: frame)
    }

    private func makeCGImage(width: Int = 10, height: Int = 10) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        return ctx.makeImage()!
    }

    private func contentLayer(of cell: RenderCell) -> CALayer? {
        cell.layer.sublayers?.first { !($0 is CAGradientLayer) }
    }

    private func placeholderLayer(of cell: RenderCell) -> CAGradientLayer? {
        cell.layer.sublayers?.compactMap { $0 as? CAGradientLayer }.first
    }

    // MARK: - Test 1: applyLayout creates sublayers once, reuses on second call (identity stable)

    func testApplyLayoutCreatesSublayersAndReusesOnSecondCall() {
        let cell = makeCell()
        let fragments = [
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 160)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 160, width: 320, height: 160)),
            geometryFragment(id: 2, frame: CGRect(x: 0, y: 320, width: 320, height: 80)),
        ]

        cell.applyLayout(fragments)

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let subs = cl.sublayers ?? []
        XCTAssertEqual(subs.count, 3)

        let identitiesBefore = subs.map { ObjectIdentifier($0) }

        cell.applyLayout(fragments)  // same fragments — must reuse instances

        XCTAssertEqual((cl.sublayers ?? []).map { ObjectIdentifier($0) }, identitiesBefore,
            "Sublayer instances must be reused — no allocation on hot path")
    }

    // MARK: - Test 2: Image sublayers carry gray placeholder; geometry sublayers do not

    func testImageSublayersHaveGrayBackgroundGeometryDoesNot() {
        let cell = makeCell()
        cell.applyLayout([
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200)),
            geometryFragment(id: 1, frame: CGRect(x: 0, y: 200, width: 320, height: 40)),
        ])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let subs = cl.sublayers ?? []
        XCTAssertEqual(subs.count, 2)

        // Insertion order = fragment order: subs[0]=id0 (image), subs[1]=id1 (geometry)
        XCTAssertNotNil(subs[0].backgroundColor, "Image sublayer must have gray placeholder backgroundColor")
        XCTAssertNil(subs[1].backgroundColor, "Geometry sublayer must not have gray backgroundColor")
    }

    // MARK: - Animation test helpers (window-connected layers only)

    /// Creates a cell whose layer is attached to a (non-key) UIWindow so CA
    /// actually runs its animation system. Without a display connection, all
    /// animation(forKey:) / animationKeys() calls return nil/empty in the test runner.
    ///
    /// CATransaction.flush() is required after triggering the animation before inspecting keys.
    /// Layer speed is set to 0 so animations are frozen in place (don't complete between flush
    /// and the assertion).
    /// Window-connected cell with speed=0: explicit animations (CATransition via add(_:forKey:))
    /// appear in animationKeys() after flush. Does NOT work for implicit animations (property
    /// changes in transactions) — CA skips implicit animation creation for speed=0 layers.
    private func makeCellInWindow(size: CGSize = CGSize(width: 320, height: 400))
        -> (cell: RenderCell, window: UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.isHidden = false
        let cell = RenderCell()
        cell.layer.frame = CGRect(origin: .zero, size: size)
        cell.layer.speed = 0
        window.layer.addSublayer(cell.layer)
        return (cell, window)
    }

    /// Window-connected cell WITHOUT speed freeze. Required for implicit animation tests
    /// (opacity transitions created by CATransaction.setAnimationDuration). Synchronous
    /// checks work because 0.15–0.2 s >> test-method execution time.
    private func makeCellInWindowUnfrozen(size: CGSize = CGSize(width: 320, height: 400))
        -> (cell: RenderCell, window: UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.isHidden = false
        let cell = RenderCell()
        cell.layer.frame = CGRect(origin: .zero, size: size)
        window.layer.addSublayer(cell.layer)
        return (cell, window)
    }

    // MARK: - Test 3: applyContent attaches a CATransition for the contents key

    func testApplyContentAttachesCATransitionForContentsKey() {
        // Requires a window-connected layer: detached layers don't commit to CA's animation
        // system, so animation(forKey:)/animationKeys() always return nil/empty.
        // CATransaction.flush() forces the commit; speed=0 freezes it in place.
        // Note: CA ignores the custom key for CATransition and uses kCATransition ("transition").
        let (cell, _window) = makeCellInWindow()
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])
        cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item"))
        CATransaction.flush()

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first

        // CA remaps CATransition to kCATransition ("transition") regardless of the key passed
        // to add(_:forKey:). Check via animationKeys() which reflects the real stored key.
        XCTAssertEqual(sub?.animationKeys()?.contains("transition"), true,
            "applyContent must attach a CATransition — plain setAnimationDuration has no effect " +
            "on contents since CALayer.contents has no registered default CA action")
        XCTAssertTrue(sub?.animation(forKey: kCATransition) is CATransition,
            "The transition must be a CATransition (crossfade)")
    }

    // MARK: - Test 4: applyContent fade + placeholder fade sequencing

    func testApplyContentAndPlaceholderFadeSequencing() {
        // Unfrozen: implicit opacity animations only appear in animationKeys() on non-speed=0 layers.
        // Model opacity checks are unaffected (model layer updates synchronously regardless).
        let (cell, _window) = makeCellInWindowUnfrozen()
        let fragments = [
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 200, width: 320, height: 200)),
        ]
        cell.applyLayout(fragments)

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let pl = placeholderLayer(of: cell) else { XCTFail("placeholderLayer missing"); return }

        XCTAssertEqual(cl.opacity, 0, "contentLayer starts hidden")
        XCTAssertEqual(pl.opacity, 1, "placeholderLayer starts visible")

        let img = makeCGImage()

        // First image: placeholder must remain (second fragment still pending)
        cell.applyContent(id: 0, image: img, for: AnyHashable("item"))
        CATransaction.flush()
        XCTAssertEqual(cl.opacity, 0, "contentLayer must stay hidden until ALL media arrives")
        XCTAssertEqual(pl.opacity, 1, "Placeholder must stay visible until ALL media arrives")
        XCTAssertNil(pl.animationKeys(), "Placeholder must not have animations before all media")

        // Second (last) image: placeholder fades out, contentLayer becomes visible
        cell.applyContent(id: 1, image: img, for: AnyHashable("item"))
        CATransaction.flush()
        XCTAssertEqual(cl.opacity, 1, "contentLayer must be visible once all media arrives")
        XCTAssertEqual(pl.opacity, 0, "Placeholder must fade out once all media arrives")

        // Opacity animations must exist (not instant model jumps)
        XCTAssertEqual(pl.animationKeys()?.contains("opacity"), true,
            "Placeholder must fade via animation, not an instant cut")
        XCTAssertEqual(cl.animationKeys()?.contains("opacity"), true,
            "contentLayer must reveal via animation, not an instant cut")
    }

    // MARK: - Test 5: fadeOutPlaceholderIfAllReady is idempotent after first reveal

    func testPlaceholderFadeDoesNotReFireAfterAllMediaLoaded() {
        let (cell, _window) = makeCellInWindowUnfrozen()
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])
        guard let pl = placeholderLayer(of: cell) else { XCTFail("placeholderLayer missing"); return }

        // Prime the CA display connection — one flush needed before implicit animations
        // appear in animationKeys() on a newly-connected layer.
        CATransaction.flush()

        cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item"))
        CATransaction.flush()
        XCTAssertEqual(pl.animationKeys()?.contains("opacity"), true,
            "First reveal must attach opacity animation")

        // Simulate animation completion by clearing all animations
        pl.removeAllAnimations()
        CATransaction.flush()
        XCTAssertNil(pl.animationKeys(), "Precondition: animations cleared")

        // Second applyContent (updated image for same fragment) — allMediaLoaded guard must fire
        cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item"))
        CATransaction.flush()
        XCTAssertNil(pl.animationKeys(),
            "fadeOutPlaceholderIfAllReady must short-circuit when allMediaLoaded is true")
    }

    // MARK: - Test 6: prepareForReuse same-item keeps contents

    func testPrepareForReuseSameItemKeepsContents() {
        let cell = makeCell()
        let itemID = AnyHashable("item-a")

        cell.prepareForReuse(for: itemID)  // initial bind
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])
        cell.applyContent(id: 0, image: makeCGImage(), for: itemID)

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNotNil(sub?.contents, "Precondition: content set before reuse")

        cell.prepareForReuse(for: itemID)  // same item

        XCTAssertNotNil(sub?.contents, "Same-item reuse must NOT clear contents")
        XCTAssertEqual(cl.sublayers?.count, 1, "Same-item reuse must NOT remove sublayers")
        XCTAssertEqual(cell.currentItemID, itemID, "currentItemID must be retained")
    }

    // MARK: - Test 7: prepareForReuse cross-item resets layer state (UX + privacy guarantee)

    func testPrepareForReuseCrossItemResetsState() {
        let cell = makeCell()

        cell.prepareForReuse(for: AnyHashable("item-a"))
        let fragments = [
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 200, width: 320, height: 200)),
        ]
        cell.applyLayout(fragments)
        let img = makeCGImage()
        cell.applyContent(id: 0, image: img, for: AnyHashable("item-a"))
        cell.applyContent(id: 1, image: img, for: AnyHashable("item-a"))

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let pl = placeholderLayer(of: cell) else { XCTFail("placeholderLayer missing"); return }

        XCTAssertEqual(cl.opacity, 1)
        XCTAssertEqual(pl.opacity, 0)

        cell.prepareForReuse(for: AnyHashable("item-b"))  // different → cross-item

        XCTAssertEqual(cl.opacity, 0, "contentLayer must reset to 0 on cross-item reuse")
        XCTAssertEqual(pl.opacity, 1, "Placeholder must reset to 1 on cross-item reuse")
        XCTAssertEqual(cl.sublayers?.count ?? 0, 0, "Sublayers must be removed on cross-item reuse")
        XCTAssertEqual(cell.currentItemID, AnyHashable("item-b"), "currentItemID must update to new item")
    }

    // MARK: - Test 8: Cross-item reuse never flashes previous item's image

    func testCrossItemReuseDoesNotFlashPreviousContent() {
        let cell = makeCell()
        cell.prepareForReuse(for: AnyHashable("item-a"))
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        cell.applyLayout([frag])
        cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item-a"))

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        XCTAssertNotNil(cl.sublayers?.first?.contents, "Precondition: content set")

        cell.prepareForReuse(for: AnyHashable("item-b"))

        let newFrag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        cell.layer.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
        cell.applyLayout([newFrag])

        // Fresh sublayer must have nil contents — no flash of previous item's image
        XCTAssertNil(cl.sublayers?.first?.contents,
            "New sublayer must not carry previous item's image after cross-item recycle")
    }

    // MARK: - Test 9: MediaHandle.cancel called on prepareForReuse (both modes)

    func testMediaHandleCancelCalledOnCrossItemPrepareForReuse() {
        let cell = makeCell()
        let task1 = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let task2 = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        cell.addMediaHandle(MediaHandle(task: task1))
        cell.addMediaHandle(MediaHandle(task: task2))

        cell.prepareForReuse(for: AnyHashable("item-b"))

        XCTAssertTrue(task1.isCancelled, "Handle 1 must be cancelled on cross-item prepareForReuse")
        XCTAssertTrue(task2.isCancelled, "Handle 2 must be cancelled on cross-item prepareForReuse")
    }

    func testMediaHandleCancelAlsoFiresOnSameItemReuse() {
        let cell = makeCell()
        let itemID = AnyHashable("item-a")
        cell.prepareForReuse(for: itemID)  // initial bind

        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let handle = MediaHandle(task: task)
        cell.addMediaHandle(handle)

        cell.prepareForReuse(for: itemID)  // same item

        XCTAssertTrue(handle.isCancelled, "Pending fetches must be cancelled even on same-item reuse")
    }

    // MARK: - Test 10: Layer invariant sweep — no masksToBounds, cornerRadius, CATextLayer

    func testLayerInvariantSweep() {
        let cell = makeCell()
        cell.applyLayout([
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200)),
            geometryFragment(id: 1, frame: CGRect(x: 0, y: 200, width: 320, height: 40)),
        ])

        func check(_ l: CALayer) {
            XCTAssertFalse(l.masksToBounds, "masksToBounds must be false on \(type(of: l))")
            XCTAssertEqual(l.cornerRadius, 0, "cornerRadius must be 0 on \(type(of: l))")
            XCTAssertFalse(l is CATextLayer, "CATextLayer is forbidden in the layer tree")
            for child in l.sublayers ?? [] { check(child) }
        }
        check(cell.layer)
    }

    // MARK: - Test 11: Geometry-only layout never triggers placeholder fade

    func testGeometryOnlyLayoutNeverTriggersPlaceholderFade() {
        let cell = makeCell()
        cell.applyLayout([geometryFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 40))])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let pl = placeholderLayer(of: cell) else { XCTFail("placeholderLayer missing"); return }

        // mediaFragmentIDs is empty → fadeOutPlaceholderIfAllReady short-circuits
        XCTAssertEqual(cl.opacity, 0, "No image fragments → contentLayer stays at 0")
        XCTAssertEqual(pl.opacity, 1)
    }

    // MARK: - Test 12: Stale sublayer pruning on fragment set shrink

    func testApplyLayoutPrunesSublayersRemovedFromFragmentSet() {
        let cell = makeCell()
        let three = [
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0,   width: 320, height: 100)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 100, width: 320, height: 100)),
            imageFragment(id: 2, frame: CGRect(x: 0, y: 200, width: 320, height: 100)),
        ]
        cell.applyLayout(three)

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        XCTAssertEqual(cl.sublayers?.count, 3, "Precondition: 3 sublayers")

        // Re-layout with only 2 fragments — id=2 should be pruned
        let two = [
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0,   width: 320, height: 150)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 150, width: 320, height: 150)),
        ]
        cell.applyLayout(two)

        XCTAssertEqual(cl.sublayers?.count, 2, "Pruned sublayer must be removed from contentLayer")

        // Deliver content for remaining fragments — placeholder should fade once BOTH arrive
        // (confirms mediaFragmentIDs was also updated by the prune)
        let img = makeCGImage()
        cell.applyContent(id: 0, image: img, for: AnyHashable("item"))
        XCTAssertEqual(cl.opacity, 0, "Placeholder still showing — id=1 not yet loaded")
        cell.applyContent(id: 1, image: img, for: AnyHashable("item"))
        XCTAssertEqual(cl.opacity, 1, "Placeholder must fade once the 2 remaining fragments load")
    }

    // MARK: - Test 13: mediaFragmentIDs reclassifies when fragment content type changes

    func testMediaFragmentIDsReclassifiesOnContentTypeChange() {
        let cell = makeCell()

        // Start with geometry fragment at id=0
        cell.applyLayout([geometryFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let pl = placeholderLayer(of: cell) else { XCTFail("placeholderLayer missing"); return }
        XCTAssertEqual(cl.opacity, 0, "Precondition: contentLayer hidden (geometry-only, no media IDs)")

        // Re-layout as image fragment — mediaFragmentIDs must now track id=0
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])
        XCTAssertEqual(cl.opacity, 0, "Still waiting for image content")
        XCTAssertEqual(pl.opacity, 1)

        // Deliver content — placeholder must now fade (id=0 is in mediaFragmentIDs)
        cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item"))
        XCTAssertEqual(cl.opacity, 1, "Placeholder must fade when reclassified image fragment loads")
        XCTAssertEqual(pl.opacity, 0)
    }

    // MARK: - Test 14: kind is stored as let (pool-key stability)

    func testKindIsStoredAndStable() {
        let cell = RenderCell(kind: .standard)
        XCTAssertEqual(cell.kind, .standard)
        var pool: [CellKind: [RenderCell]] = [:]
        pool[cell.kind, default: []].append(cell)
        XCTAssertEqual(pool[.standard]?.count, 1)
    }

    // MARK: - Test 15: image→geometry reclassification nils sub.contents (Latent 1 guard)

    func testImageToGeometryReclassificationClearsContents() {
        let cell = makeCell()

        // Start as image fragment, deliver content
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])
        cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item"))

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        XCTAssertNotNil(cl.sublayers?.first?.contents, "Precondition: image content is set")

        // Re-layout: same id now carries geometry content
        cell.applyLayout([geometryFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])

        XCTAssertNil(cl.sublayers?.first?.contents,
            "image→geometry reclassification must nil sub.contents — stale image must not remain visible")
        XCTAssertNil(cl.sublayers?.first?.backgroundColor,
            "Geometry sublayer must not carry image placeholder tint")
    }

    // MARK: - Test 16: applyContent with mismatched itemID is a no-op (Latent 3 privacy guard)

    func testApplyContentWithMismatchedItemIDIsNoOp() {
        let cell = makeCell()
        let itemA = AnyHashable("item-a")
        let itemB = AnyHashable("item-b")

        cell.prepareForReuse(for: itemA)
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])

        // Simulate cross-item recycle: cell is now bound to item-b
        cell.prepareForReuse(for: itemB)
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }

        // Stale callback arrives for item-a (e.g. Task.isCancelled was ignored)
        cell.applyContent(id: 0, image: makeCGImage(), for: itemA)  // wrong item

        XCTAssertNil(cl.sublayers?.first?.contents,
            "Stale applyContent for a previous item must be a no-op — privacy: item-a's image " +
            "must never paint on a cell now showing item-b")

        // Correct callback for item-b should still work
        cell.applyContent(id: 0, image: makeCGImage(), for: itemB)
        XCTAssertNotNil(cl.sublayers?.first?.contents,
            "Correct applyContent for the current item must succeed")
    }
}
#endif

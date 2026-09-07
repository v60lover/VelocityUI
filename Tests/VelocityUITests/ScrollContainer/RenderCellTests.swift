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

    private func geometryFragment(id: Int, frame: CGRect) -> Fragment {
        Fragment(id: id, content: .geometry, frame: frame)
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

    private func codeTextFragment(id: Int, role: CodeBlockRole, frame: CGRect) -> Fragment {
        Fragment(
            id: id,
            content: .text(TextDescriptor(
                content: "Visible code", font: VFontDescriptor(size: 14, weight: 0),
                color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                lineLimit: nil, lineBreakMode: 0, layoutHash: id, appearanceHash: id,
                codeBlockRole: role
            )),
            frame: frame
        )
    }

    /// Known-valid canonical BlurHash string (public example from https://blurha.sh).
    private let validBlurHash = "L6PZfSi_.AyE_3t7t7R**0o#DgR4"

    private func imageFragment(
        id: Int, blockID: BlockID? = nil, frame: CGRect, thumbnailData: Data? = nil, blurHash: String? = nil,
        customPlaceholderPayload: AnyPlaceholderPayload? = nil
    ) -> Fragment {
        Fragment(
            id: id, blockID: blockID,
            content: .image(ImageDescriptor(
                url: nil, aspectRatio: 1.0, contentMode: 0,
                cornerRadius: 0, layoutHash: id, appearanceHash: id,
                thumbnailData: thumbnailData, blurHash: blurHash,
                customPlaceholderPayload: customPlaceholderPayload
            )),
            frame: frame
        )
    }

    /// A payload shape thumbnailData/blurHash cannot express — proves .custom is not
    /// limited to the two built-in field types.
    private struct SolidColorPayload: Hashable, Sendable {
        let red: UInt8, green: UInt8, blue: UInt8
    }

    /// Trivial injectable renderer for `.custom` payloads — returns a 1x1 BGRA8888
    /// premultiplied CGImage of the payload's color, nil for anything else.
    private struct FakeSolidColorPlaceholderRenderer: PlaceholderRenderer {
        nonisolated func render(
            _ payload: PlaceholderPayload, targetSize: CGSize, cornerRadius: CGFloat
        ) -> CGImage? {
            guard case .custom(let box) = payload,
                  let color = box.unwrap(as: SolidColorPayload.self) else { return nil }
            let pixels: [UInt8] = [color.blue, color.green, color.red, 255]
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
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

    func testBlockIdentityPreservesLayerWhenAnInsertionChangesNodeIndices() {
        let cell = makeCell()
        let first = imageFragment(id: 0, blockID: BlockID("a"), frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        let second = imageFragment(id: 1, blockID: BlockID("b"), frame: CGRect(x: 0, y: 100, width: 320, height: 100))

        cell.updateBlockViewport(
            fragments: [first, second], viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 200), synchronousContent: [:]
        )
        guard let content = contentLayer(of: cell), let originalSecondLayer = content.sublayers?.last else {
            XCTFail("Expected the second block layer")
            return
        }

        let inserted = geometryFragment(id: 2, frame: CGRect(x: 0, y: 0, width: 320, height: 40))
        let movedFirst = imageFragment(id: 3, blockID: BlockID("a"), frame: CGRect(x: 0, y: 40, width: 320, height: 100))
        let movedSecond = imageFragment(id: 4, blockID: BlockID("b"), frame: CGRect(x: 0, y: 140, width: 320, height: 100))
        cell.updateBlockViewport(
            fragments: [inserted, movedFirst, movedSecond],
            viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 240),
            synchronousContent: [:]
        )

        XCTAssertTrue(content.sublayers?.contains { $0 === originalSecondLayer } == true,
            "Moving a stable block must keep its existing layer")
        XCTAssertEqual(originalSecondLayer.frame, movedSecond.frame)
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

    /// Creates a cell whose layer is attached to a (non-key) UIWindow so CA actually runs its
    /// animation system — without a display connection, `animation(forKey:)`/`animationKeys()`
    /// return nil/empty in the test runner.
    ///
    /// `CATransaction.flush()` is required after triggering the animation before inspecting keys.
    /// Layer speed is set to 0 so animations freeze in place instead of completing between flush and
    /// the assertion. Works for explicit animations (CATransition via `add(_:forKey:)`) — does NOT
    /// work for implicit animations (property changes in transactions), since CA skips implicit
    /// animation creation for speed=0 layers.
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

    /// Updated for VelocityUI-ksh's secondary fix: cross-item recycle used to remove every
    /// sublayer (`sub.removeFromSuperlayer()` + `sublayers.removeAll()`), forcing `applyLayout`
    /// to `CALayer()`-allocate a fresh sublayer for every fragment on the very next mount — the
    /// "20/37 CALayer" allocation smell from the bead's Instruments call tree. The fix instead
    /// clears `contents`/`backgroundColor` on the EXISTING sublayer instances and keeps them in
    /// the `sublayers` map, so `applyLayout`'s `if let existing = sublayers[fragment.id]` path
    /// reuses them — zero CALayer allocation on cross-item mount, same privacy hard-cut.
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

        let sublayerIdentitiesBefore = (cl.sublayers ?? []).map { ObjectIdentifier($0) }
        XCTAssertEqual(sublayerIdentitiesBefore.count, 2, "Precondition: 2 sublayers before reuse")

        cell.prepareForReuse(for: AnyHashable("item-b"))  // different → cross-item

        XCTAssertEqual(cl.opacity, 0, "contentLayer must reset to 0 on cross-item reuse")
        XCTAssertEqual(pl.opacity, 1, "Placeholder must reset to 1 on cross-item reuse")
        XCTAssertEqual((cl.sublayers ?? []).map { ObjectIdentifier($0) }, sublayerIdentitiesBefore,
            "Sublayers must be RETAINED (same CALayer instances) on cross-item reuse — cleared "
            + "in place, not reallocated, so the next applyLayout mount needs zero fresh CALayer()")
        for sub in cl.sublayers ?? [] {
            XCTAssertNil(sub.contents, "Cross-item reuse must clear contents — no stale pixel from the old item")
            XCTAssertNil(sub.backgroundColor, "Cross-item reuse must clear backgroundColor")
        }
        XCTAssertEqual(cell.currentItemID, AnyHashable("item-b"), "currentItemID must update to new item")
    }

    // MARK: - Test 7b: Cross-item recycle with a DIFFERENT fragment id set does not orphan sublayers

    /// Regression for a latent bug in VelocityUI-ksh's secondary fix: `applyLayout`'s prune only ran
    /// the id-diff when `sublayers.count > fragments.count`. `fragment.id` is POSITIONAL (== nodeIndex),
    /// so a cross-item recycle into a cell shape with an EQUAL-OR-LARGER but DIFFERENT id set never
    /// triggered the guard — e.g. an image-only cell (ids {0}) recycled into a VStack{image,text} cell
    /// (ids {1,2}): count 1→2 makes `1 > 2` false, so id 0's sublayer is orphaned (leak + growing layer
    /// tree) while ids 1 and 2 allocate fresh layers on top of it.
    ///
    /// The fix: `prepareForReuse`'s cross-item branch sets `needsSublayerReconcile`, forcing the NEXT
    /// `applyLayout` to run the full id-diff prune unconditionally, then clear the flag. This test
    /// asserts NO orphaned sublayer remains — only ids {1, 2} (the new item's exact fragment set)
    /// remain.
    func testCrossItemRecycleWithDisjointFragmentIDsDoesNotOrphanSublayers() {
        let cell = makeCell()

        // Phase 1: mount an image-only shape (fragment id set {0}).
        cell.prepareForReuse(for: AnyHashable("item-a"))
        cell.applyLayout([imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        XCTAssertEqual(cl.sublayers?.count, 1, "Precondition: 1 sublayer (id 0) after first mount")
        let orphanCandidate = cl.sublayers?.first

        // Phase 2: cross-item recycle into a DIFFERENT shape whose fragment id set is disjoint
        // from {0} and whose count (2) is EQUAL-OR-LARGER than the retained count (1) — the
        // exact shape the count-only fast path (`sublayers.count > fragments.count`) misses.
        cell.prepareForReuse(for: AnyHashable("item-b"))
        cell.applyLayout([
            imageFragment(id: 1, frame: CGRect(x: 0, y: 0, width: 320, height: 100)),
            geometryFragment(id: 2, frame: CGRect(x: 0, y: 100, width: 320, height: 100)),
        ])

        let subsAfter = cl.sublayers ?? []
        XCTAssertEqual(subsAfter.count, 2,
            "contentLayer must have exactly 2 sublayers (the new item's fragment count) — "
            + "no orphaned leftover from the old id set")
        XCTAssertFalse(subsAfter.contains { orphanCandidate === $0 },
            "The old id-0 sublayer must be gone — retaining-and-clearing cross-item recycle must "
            + "not orphan a sublayer whose id is absent from the new item's fragment set")

        // The RenderCell's own bookkeeping (`sublayers` dict) must also be reconciled to the
        // new item's exact id set — checked indirectly via applyContent routing: id 0 must no
        // longer resolve to a sublayer (no-op, not a crash), while ids 1 and 2 do.
        XCTAssertNil(cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item-b")),
            "Stale id 0 must have no sublayer to route to after reconcile — applyContent no-ops")
        XCTAssertNotNil(cell.applyContent(id: 1, image: makeCGImage(), for: AnyHashable("item-b")),
            "id 1 (new item's image fragment) must resolve to a live sublayer")
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

    // MARK: - Test 17: cell.layer suppresses implicit animations on frame changes (snap-only contract)

    func testCellLayerSuppressesImplicitAnimationsOnFrameChange() {
        // Window-connected, unfrozen: without suppression, frame changes produce
        // position/bounds implicit animations visible in animationKeys() for 0.25 s.
        // speed=0 bypasses implicit animation creation entirely; unfrozen means nil
        // animationKeys() proves suppression via layer.actions, not speed bypass.
        let (cell, _window) = makeCellInWindowUnfrozen()
        CATransaction.flush()  // commit the addSublayer

        cell.layer.frame = CGRect(x: 0, y: 50, width: 300, height: 350)
        CATransaction.flush()

        XCTAssertNil(cell.layer.animationKeys(),
            "cell.layer must not carry implicit animations after frame change — " +
            "layer.actions must suppress position/bounds/opacity/sublayers so all " +
            "FeedScrollView mount sites snap without animating")
    }

    // MARK: - Test 18: applyLayout with sync content sets sublayer.contents, skips gray tint

    func testSyncApplyLayoutSetsContentsAndSkipsGrayTint() {
        let cell = makeCell()
        let img = makeCGImage()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))

        cell.applyLayout([frag], synchronousContent: [0: img])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first

        XCTAssertNotNil(sub?.contents,
            "Sync paint must set sublayer.contents immediately — no Task spawn or applyContent needed")
        XCTAssertNil(sub?.backgroundColor,
            "Sync paint must skip the gray placeholder tint — image is already present")
    }

    // MARK: - Test 19: applyLayout sync full-coverage reveals contentLayer immediately, no animation

    func testSyncApplyLayoutAllFragmentsCoveredRevealsContentLayerImmediately() {
        let cell = makeCell()
        let img = makeCGImage()
        let frags = [
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 100)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 100, width: 320, height: 100)),
        ]

        // Capture baseline before the call — the static counter accumulates across tests.
        #if canImport(XCTest)
        let countBefore = RenderCell._debugApplyContentCount
        #endif

        cell.applyLayout(frags, synchronousContent: [0: img, 1: img])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        guard let pl = placeholderLayer(of: cell) else { XCTFail("placeholderLayer missing"); return }

        XCTAssertEqual(cl.opacity, 1,
            "contentLayer must be immediately visible when sync map covers every image fragment")
        XCTAssertEqual(pl.opacity, 0,
            "placeholderLayer must be immediately hidden when sync map covers every image fragment")

        // Verify applyContent was NOT called — sync path bypasses it, so the counter must not move.
        #if canImport(XCTest)
        XCTAssertEqual(RenderCell._debugApplyContentCount, countBefore,
            "Sync paint must bypass applyContent — _debugApplyContentCount must not increment")
        #endif
    }

    // MARK: - Test 20: applyLayout partial sync map — covered fragment has contents, uncovered has gray tint

    func testSyncApplyLayoutPartialCoverageLeavesMissingFragmentAsAsync() {
        let cell = makeCell()
        let img = makeCGImage()
        let frags = [
            imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 100)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 100, width: 320, height: 100)),
        ]

        // Only fragment 0 in sync map — fragment 1 falls back to async path
        cell.applyLayout(frags, synchronousContent: [0: img])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let subs = cl.sublayers ?? []
        XCTAssertEqual(subs.count, 2)

        // Insertion order = fragment order: subs[0]=id0 (sync), subs[1]=id1 (async fallback)
        XCTAssertNotNil(subs[0].contents, "Sync-painted fragment must have non-nil contents")
        XCTAssertNil(subs[0].backgroundColor, "Sync-painted fragment must not have gray tint")
        XCTAssertNil(subs[1].contents, "Async-fallback fragment must have nil contents (not yet fetched)")
        XCTAssertNotNil(subs[1].backgroundColor, "Async-fallback fragment must have gray placeholder tint")

        // contentLayer must stay hidden — not all fragments loaded yet
        XCTAssertEqual(cl.opacity, 0,
            "contentLayer must stay hidden when partial sync map does not cover all image fragments")
    }

    // MARK: - Test 21: painted text reveals without waiting for media

    func testPaintedTextRevealsContentWithoutImageFragments() {
        let cell = makeCell()
        let text = makeCGImage()
        let fragment = textFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 40))

        cell.applyLayout([fragment], synchronousContent: [0: text])

        guard let cl = contentLayer(of: cell), let pl = placeholderLayer(of: cell) else {
            XCTFail("Expected cell layers")
            return
        }
        XCTAssertEqual(cl.opacity, 1, "Painted text must be visible without an image delivery")
        XCTAssertEqual(pl.opacity, 0, "Painted text must not be covered by the full-cell gradient")
    }

    func testPaintedTextRevealsWhileUnloadedImageKeepsGrayTint() {
        let cell = makeCell()
        let text = makeCGImage()
        let fragments = [
            textFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 40)),
            imageFragment(id: 1, frame: CGRect(x: 0, y: 40, width: 320, height: 200)),
        ]

        cell.applyLayout(fragments, synchronousContent: [0: text])

        guard let cl = contentLayer(of: cell), let pl = placeholderLayer(of: cell),
              let imageLayer = cl.sublayers?.last else {
            XCTFail("Expected cell layers")
            return
        }
        XCTAssertEqual(cl.opacity, 1, "Text must not wait for the image request")
        XCTAssertEqual(pl.opacity, 0, "The full-cell gradient must be hidden once text is painted")
        XCTAssertNil(imageLayer.contents, "The image must remain pending")
        XCTAssertNotNil(imageLayer.backgroundColor, "The pending image must retain its gray tint")
    }

    // MARK: - Test 22: applyLayout(_:) wrapper produces same behavior as empty sync map

    func testApplyLayoutNoArgWrapperPreservesGrayTintForNilContents() {
        let cell = makeCell()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))

        cell.applyLayout([frag])  // wrapper → synchronousContent: [:]

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNil(sub?.contents, "No sync content — sublayer must have nil contents")
        XCTAssertNotNil(sub?.backgroundColor, "No sync content — gray placeholder tint must be applied")
    }

    // MARK: - Tests 22-27: decode-guaranteed placeholder (VelocityUI-1su.3)

    func testApplyLayoutDecodesBlurHashPlaceholderAndSkipsGrayTint() {
        let cell = makeCell()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 40), blurHash: validBlurHash)

        cell.applyLayout([frag])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNotNil(sub?.contents,
            "BlurHash placeholder must be decoded synchronously and set as sub.contents")
        XCTAssertNil(sub?.backgroundColor,
            "Placeholder decode must skip the systemGray5 gray tint")
    }

    func testApplyLayoutMalformedBlurHashFallsBackToGrayTint() {
        let cell = makeCell()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 40), blurHash: "not-a-blurhash")

        cell.applyLayout([frag])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNil(sub?.contents, "Malformed BlurHash must decode to nil, not crash")
        XCTAssertNotNil(sub?.backgroundColor, "Malformed BlurHash must fall back to gray tint")
    }

    func testApplyLayoutNoPlaceholderDataPreservesExistingGrayTintBehavior() {
        // AC7 backward compatibility: absent placeholder data must behave identically
        // to pre-VelocityUI-1su.3 RenderCell.
        let cell = makeCell()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))

        cell.applyLayout([frag])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNil(sub?.contents)
        XCTAssertNotNil(sub?.backgroundColor)
    }

    func testApplyLayoutDoesNotRedecodePlaceholderOnSubsequentLayoutPasses() {
        let cell = makeCell()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 40), blurHash: validBlurHash)

        cell.applyLayout([frag])
        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let firstContents = cl.sublayers?.first?.contents as! CGImage?

        cell.applyLayout([frag])  // second pass — sub.contents is already non-nil
        let secondContents = cl.sublayers?.first?.contents as! CGImage?

        XCTAssertTrue(firstContents === secondContents,
            "Placeholder must decode once per fragment lifetime — the gate is sub.contents == nil")
    }

    // MARK: - Injectable PlaceholderRenderer (VelocityUI-9x0.1)

    func testInjectedCustomRendererPaintsCustomPayloadInsteadOfGrayTint() {
        let color = SolidColorPayload(red: 200, green: 10, blue: 10)
        let cell = RenderCell(kind: .standard, placeholderRenderer: FakeSolidColorPlaceholderRenderer())
        cell.layer.frame = CGRect(origin: .zero, size: CGSize(width: 320, height: 400))
        let frag = imageFragment(
            id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 40),
            customPlaceholderPayload: AnyPlaceholderPayload(color)
        )

        cell.applyLayout([frag])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNotNil(sub?.contents, "Custom renderer output must be painted instead of the gray tint")
        XCTAssertNil(sub?.backgroundColor, "Custom placeholder paint must skip the gray tint")
        XCTAssertEqual((sub?.contents as! CGImage?)?.width, 1)
    }

    func testDefaultRendererIgnoresCustomPayloadAndFallsBackToGrayTint() {
        // Without an injected renderer, DefaultPlaceholderRenderer doesn't know how to
        // interpret .custom — same gray-tint fallback as no placeholder data at all.
        let cell = makeCell()
        let color = SolidColorPayload(red: 5, green: 5, blue: 5)
        let frag = imageFragment(
            id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 40),
            customPlaceholderPayload: AnyPlaceholderPayload(color)
        )

        cell.applyLayout([frag])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNil(sub?.contents)
        XCTAssertNotNil(sub?.backgroundColor)
    }

    func testCustomPayloadIsThirdFallbackTierAfterThumbnailAndBlurHashFail() {
        // Malformed thumbnail bytes AND malformed BlurHash both fail to decode — the cell
        // must still fall through to a custom payload as the third tier, not the gray tint.
        let color = SolidColorPayload(red: 1, green: 2, blue: 3)
        let cell = RenderCell(kind: .standard, placeholderRenderer: FakeSolidColorPlaceholderRenderer())
        cell.layer.frame = CGRect(origin: .zero, size: CGSize(width: 320, height: 400))
        let frag = imageFragment(
            id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 40),
            thumbnailData: Data([0x00, 0x01, 0x02]), blurHash: "not-a-blurhash",
            customPlaceholderPayload: AnyPlaceholderPayload(color)
        )

        cell.applyLayout([frag])

        guard let cl = contentLayer(of: cell) else { XCTFail("contentLayer missing"); return }
        let sub = cl.sublayers?.first
        XCTAssertNotNil(sub?.contents, "Custom payload must still paint when both built-in tiers fail to decode")
        XCTAssertEqual((sub?.contents as! CGImage?)?.width, 1)
    }

    func testApplyContentReplacingThumbnailPlaceholderReportsFromThumbnailPlaceholder() {
        let cell = makeCell()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 40), blurHash: validBlurHash)
        cell.applyLayout([frag])

        let transition = cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item"))

        XCTAssertEqual(transition, .fromThumbnailPlaceholder,
            "Replacing a placeholder-painted sublayer must report .fromThumbnailPlaceholder")
    }

    func testApplyContentReplacingGrayTintReportsFromGrayPlaceholder() {
        let cell = makeCell()
        let frag = imageFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        cell.applyLayout([frag])

        let transition = cell.applyContent(id: 0, image: makeCGImage(), for: AnyHashable("item"))

        XCTAssertEqual(transition, .fromGrayPlaceholder,
            "Replacing a gray-tint sublayer (no placeholder data) must report .fromGrayPlaceholder")
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

    // MARK: - CodeBlockBackground fragment content

    func testApplyLayout_CodeBlockBackground_SetsContentsAndContentsCenter_NeverCornerRadiusOrMasksToBounds() {
        let cell = makeCell()
        let descriptor = CodeBlockBackgroundDescriptor(
            cornerRadius: 8, color: VColorDescriptor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        )
        let fragment = Fragment(id: -1, content: .codeBlockBackground(descriptor), frame: CGRect(x: 0, y: 0, width: 300, height: 90))

        cell.applyLayout([fragment])

        guard let cl = contentLayer(of: cell), let sub = cl.sublayers?.first else {
            return XCTFail("expected one sublayer for the background fragment")
        }
        XCTAssertNotNil(sub.contents, "background must paint a pre-rounded CGImage")
        XCTAssertEqual(sub.contentsCenter, codeBlockBackgroundContentsCenter(cornerRadius: 8),
            "contentsCenter must come from the same helper the rasterizer's template size is derived from")
        XCTAssertEqual(sub.cornerRadius, 0, "must never set CALayer.cornerRadius -- pre-rounded via CGContext clip")
        XCTAssertFalse(sub.masksToBounds, "must never set masksToBounds")
    }

    // MARK: - Code block viewport grouping

    /// A code card uses its background frame as one viewport range.
    func testUpdateBlockViewport_CodeBlockBackground_ActivatesAsOneUnitWithHeaderAndBody() {
        let cell = makeCell()
        let chrome = CodeBlockChrome(cornerRadius: 8, backgroundColor: .codeBlockBackground, language: nil)
        let background = Fragment(
            id: -1,
            content: .codeBlockBackground(CodeBlockBackgroundDescriptor(cornerRadius: 8, color: .codeBlockBackground)),
            frame: CGRect(x: 0, y: 0, width: 320, height: 90)
        )
        let header = codeTextFragment(id: 0, role: .header(chrome), frame: CGRect(x: 0, y: 0, width: 320, height: 30))
        let body = codeTextFragment(id: 1, role: .body(chrome), frame: CGRect(x: 0, y: 30, width: 320, height: 60))
        let unrelated = textFragment(id: 2, frame: CGRect(x: 0, y: 90, width: 320, height: 60))

        let active = cell.updateBlockViewport(
            fragments: [background, header, body, unrelated],
            viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 25), // reaches only the header row
            synchronousContent: [:]
        )

        let activeIDs = Set(active.map(\.id))
        XCTAssertTrue(activeIDs.contains(header.id), "header must be active when the viewport intersects it")
        XCTAssertTrue(activeIDs.contains(background.id), "background must activate alongside its card")
        XCTAssertTrue(activeIDs.contains(body.id),
            "body must activate too -- the whole card is one unit, even though the window only reaches the header row")
        XCTAssertFalse(activeIDs.contains(unrelated.id),
            "a block after the code block must not be pulled in by the group's extended range")
    }

    /// A card stays resident while any of its parts intersects the viewport.
    func testUpdateBlockViewport_HeaderScrolledAboveViewport_BackgroundStaysActiveWhileBodyVisible() {
        let cell = makeCell()
        let chrome = CodeBlockChrome(cornerRadius: 8, backgroundColor: .codeBlockBackground, language: nil)
        let background = Fragment(
            id: -1,
            content: .codeBlockBackground(CodeBlockBackgroundDescriptor(cornerRadius: 8, color: .codeBlockBackground)),
            frame: CGRect(x: 0, y: 0, width: 320, height: 90)
        )
        let header = codeTextFragment(id: 0, role: .header(chrome), frame: CGRect(x: 0, y: 0, width: 320, height: 30))
        let body = codeTextFragment(id: 1, role: .body(chrome), frame: CGRect(x: 0, y: 30, width: 320, height: 60))

        let active = cell.updateBlockViewport(
            fragments: [background, header, body],
            // header's own row (y 0-30) is entirely above this window -- only the body row is visible.
            viewportInCell: CGRect(x: 0, y: 40, width: 320, height: 25),
            synchronousContent: [:]
        )

        let activeIDs = Set(active.map(\.id))
        XCTAssertTrue(activeIDs.contains(body.id), "body must be active -- the viewport intersects it")
        XCTAssertTrue(activeIDs.contains(background.id),
            "background must stay active while any part of its card (here, the body) is visible")
        XCTAssertTrue(activeIDs.contains(header.id),
            "header rides along with the rest of its card's atomic activation unit")
    }

    func testUpdateBlockViewport_MissingHeaderDoesNotGroupUnrelatedFragment() {
        let cell = makeCell()
        let chrome = CodeBlockChrome(cornerRadius: 8, backgroundColor: .codeBlockBackground, language: nil)
        let background = Fragment(
            id: -1,
            content: .codeBlockBackground(CodeBlockBackgroundDescriptor(cornerRadius: 8, color: .codeBlockBackground)),
            frame: CGRect(x: 0, y: 0, width: 320, height: 90)
        )
        let body = codeTextFragment(id: 0, role: .body(chrome), frame: CGRect(x: 0, y: 30, width: 320, height: 60))
        let unrelated = textFragment(id: 1, frame: CGRect(x: 0, y: 90, width: 320, height: 60))

        let active = cell.updateBlockViewport(
            fragments: [background, body, unrelated],
            viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 25),
            synchronousContent: [:]
        )

        XCTAssertEqual(Set(active.map(\.id)), Set([background.id]),
            "a missing header must not let the next fragment join the code card")
    }

    func testUpdateBlockViewport_FramedNilLanguageCodeBlockKeepsTripleAndExcludesNextFragment() async throws {
        let root = VStackNode {
            VStackNode {
                CodeBlockNode(language: nil, rawCode: "let value = 1")
                TextNode("next fragment")
            }
            .frame(width: 320, height: 120, alignment: .top)
        }
        let table = flatten(root, itemID: "framed-code-block")
        let layout = await measureNode(table, nodeIndex: 0, width: 320, textPool: TextMeasurementPool(capacity: 2))
        let fragments = extractFragments(table: table, layout: layout)

        XCTAssertEqual(fragments.count, 4, "a clipped code card must retain background, empty header, and body")
        guard case .codeBlockBackground = fragments[0].content,
              case .text(let header) = fragments[1].content,
              case .header = header.codeBlockRole,
              case .text(let body) = fragments[2].content,
              case .body = body.codeBlockRole
        else { return XCTFail("the code card must be an ordered triple") }

        let cell = makeCell()
        let active = cell.updateBlockViewport(
            fragments: fragments,
            viewportInCell: fragments[0].frame,
            synchronousContent: [:]
        )
        XCTAssertEqual(Set(active.map(\.id)), Set(fragments.prefix(3).map(\.id)),
            "the next fragment must not be treated as a clipped code card part")
    }

    func testCodeBodyUsesSeparateSealedAndTailLayers() {
        let cell = makeCell()
        let fragment = codeTextFragment(
            id: 9,
            role: .body(CodeBlockChrome(
                cornerRadius: 0,
                backgroundColor: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                language: "swift"
            )),
            frame: CGRect(x: 4, y: 20, width: 300, height: 60)
        )
        let sealed = makeCGImage(width: 120, height: 20)
        let tail = makeCGImage(width: 80, height: 20)
        let content = CodeBodyLayerContent(
            chunks: [CodeBodyChunk(image: sealed, size: CGSize(width: 120, height: 20))],
            tailImage: tail, tailSize: CGSize(width: 80, height: 20)
        )

        cell.applyLayout([fragment], synchronousContent: [:], codeBodyContent: [fragment.id: content])

        // Chunk/tail layers live one level deeper now -- sublayers of the code body's clip
        // container (itself a sublayer of contentLayer), at LOCAL coordinates. `convert(_:to:)`
        // recovers the absolute contentLayer-space frame regardless of nesting.
        guard let contentLayer = contentLayer(of: cell),
              let clip = contentLayer.sublayers?.first(where: { $0.masksToBounds }),
              let painted = clip.sublayers?.filter({ $0.contents != nil })
        else {
            return XCTFail("Expected code-body clip layer with chunk/tail sublayers")
        }
        XCTAssertEqual(painted.count, 2, "one chunk layer + one tail layer")
        XCTAssertTrue((painted[0].contents as! CGImage) === sealed)
        XCTAssertTrue((painted[1].contents as! CGImage) === tail)
        XCTAssertEqual(clip.convert(painted[0].frame, to: contentLayer), CGRect(x: 4, y: 20, width: 120, height: 20))
        XCTAssertEqual(clip.convert(painted[1].frame, to: contentLayer), CGRect(x: 4, y: 40, width: 80, height: 20))
    }

    func testCodeBodyTailSurvivesViewportExitAndReentry() {
        let fragment = codeTextFragment(
            id: 9,
            role: .body(CodeBlockChrome(
                cornerRadius: 0,
                backgroundColor: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
                language: "swift"
            )),
            frame: CGRect(x: 4, y: 20, width: 300, height: 60)
        )

        for sealed in [makeCGImage(width: 120, height: 20), nil] {
            let cell = makeCell()
            let tail = makeCGImage(width: 80, height: 20)
            let chunks = sealed.map { [CodeBodyChunk(image: $0, size: CGSize(width: 120, height: 20))] } ?? []
            let content = CodeBodyLayerContent(chunks: chunks, tailImage: tail, tailSize: CGSize(width: 80, height: 20))

            _ = cell.updateBlockViewport(
                fragments: [fragment],
                viewportInCell: fragment.frame,
                synchronousContent: [:],
                codeBodyContent: [fragment.id: content]
            )
            _ = cell.updateBlockViewport(
                viewportInCell: CGRect(x: 0, y: 200, width: 300, height: 20),
                synchronousContent: [:],
                codeBodyContent: [:]
            )
            _ = cell.updateBlockViewport(
                viewportInCell: fragment.frame,
                synchronousContent: [:],
                codeBodyContent: [:]
            )

            guard let clip = contentLayer(of: cell)?.sublayers?.first(where: { $0.masksToBounds }),
                  let layers = clip.sublayers
            else {
                return XCTFail("Expected re-entered code-body clip layer")
            }
            guard let tailLayer = layers.first(where: { $0.contents != nil && ($0.contents as! CGImage) === tail }) else {
                return XCTFail("expected the tail layer to survive re-entry")
            }
            // Tail layer position is LOCAL to the clip container now (origin x=0), not absolute.
            XCTAssertEqual(tailLayer.frame.origin.y, sealed == nil ? 0 : 20)
        }
    }

    // MARK: - Incremental viewport content delivery

    func testViewportOnlyDeliveryPaintsLateBitmapWithoutEnteringFragments() {
        let cell = makeCell()
        let fragment = textFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 40))

        let initiallyActive = cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame, synchronousContent: [:]
        )
        XCTAssertEqual(initiallyActive.map(\.id), [fragment.id])

        let bitmap = makeCGImage(width: 320, height: 40)
        let entering = cell.updateBlockViewport(
            viewportInCell: fragment.frame, synchronousContent: [fragment.id: bitmap]
        )

        XCTAssertTrue(entering.isEmpty, "Late content must not be reported as a newly entering fragment")
        guard let sublayer = contentLayer(of: cell)?.sublayers?.first else {
            return XCTFail("Expected the text sublayer")
        }
        XCTAssertTrue((sublayer.contents as! CGImage?) === bitmap,
            "Viewport-only content delivery must paint the supplied bitmap")
    }

    func testViewportOnlyPartialDeliveryPreservesOtherRasterContent() {
        let cell = makeCell()
        let fragments = [
            textFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 40)),
            textFragment(id: 1, frame: CGRect(x: 0, y: 40, width: 320, height: 40)),
        ]
        let first = makeCGImage(width: 320, height: 40)
        let second = makeCGImage(width: 320, height: 40)
        cell.updateBlockViewport(
            fragments: fragments, viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 80),
            synchronousContent: [0: first, 1: second]
        )

        let replacement = makeCGImage(width: 320, height: 40)
        let entering = cell.updateBlockViewport(
            viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 80),
            synchronousContent: [0: replacement]
        )

        XCTAssertTrue(entering.isEmpty)
        guard let sublayers = contentLayer(of: cell)?.sublayers, sublayers.count == 2 else {
            return XCTFail("Expected two text sublayers")
        }
        XCTAssertTrue((sublayers[0].contents as! CGImage?) === replacement)
        XCTAssertTrue((sublayers[1].contents as! CGImage?) === second,
            "An omitted bitmap must remain painted on the incremental viewport path")
    }

    func testViewportOnlySameContentIsNoOpAndReusesLayers() {
        let cell = makeCell()
        let fragment = textFragment(id: 0, frame: CGRect(x: 0, y: 0, width: 320, height: 40))
        let bitmap = makeCGImage(width: 320, height: 40)
        cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame, synchronousContent: [0: bitmap]
        )
        guard let layer = contentLayer(of: cell)?.sublayers?.first else {
            return XCTFail("Expected the text sublayer")
        }
        let identity = ObjectIdentifier(layer)

        let entering = cell.updateBlockViewport(
            viewportInCell: fragment.frame, synchronousContent: [0: bitmap]
        )

        XCTAssertTrue(entering.isEmpty, "Repeated content must not report duplicate entering fragments")
        guard let currentLayer = contentLayer(of: cell)?.sublayers?.first else {
            return XCTFail("Expected the text sublayer after the no-op update")
        }
        XCTAssertEqual(ObjectIdentifier(currentLayer), identity, "No-op delivery must not churn layers")
        XCTAssertTrue((currentLayer.contents as! CGImage?) === bitmap)
    }

    func testViewportOnlyDeliveryRepaintsTableAndMathRasters() {
        let cell = makeCell()
        let table = Fragment(
            id: 0,
            content: .table(TableRasterDescriptor(
                naturalContentSize: CGSize(width: 320, height: 40), layoutHash: 1, appearanceHash: 1
            )),
            frame: CGRect(x: 0, y: 0, width: 320, height: 40)
        )
        let math = Fragment(
            id: 1,
            content: .mathBlock(MathBlockRasterDescriptor(
                naturalContentSize: CGSize(width: 320, height: 40), layoutHash: 2, appearanceHash: 2
            )),
            frame: CGRect(x: 0, y: 40, width: 320, height: 40)
        )
        cell.updateBlockViewport(
            fragments: [table, math], viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 80),
            synchronousContent: [:]
        )
        let tableBitmap = makeCGImage(width: 320, height: 40)
        let mathBitmap = makeCGImage(width: 320, height: 40)
        XCTAssertTrue(cell.updateBlockViewport(
            viewportInCell: CGRect(x: 0, y: 0, width: 320, height: 80),
            synchronousContent: [0: tableBitmap, 1: mathBitmap]
        ).isEmpty)

        guard let content = contentLayer(of: cell),
              let clips = content.sublayers?.filter({ $0.masksToBounds }),
              clips.count == 2,
              let tableClip = clips.first,
              let mathClip = clips.last,
              let tableContent = tableClip.sublayers?.first,
              let mathContent = mathClip.sublayers?.first
        else { return XCTFail("Expected nested table and math raster layers") }
        XCTAssertTrue((tableContent.contents as! CGImage?) === tableBitmap)
        XCTAssertTrue((mathContent.contents as! CGImage?) === mathBitmap)
    }

    func testViewportOnlyDeliveryRepaintsFreshCodeBodyContent() {
        let cell = makeCell()
        let fragment = codeTextFragment(
            id: 0,
            role: .body(CodeBlockChrome(cornerRadius: 0, backgroundColor: .codeBlockBackground, language: "swift")),
            frame: CGRect(x: 0, y: 0, width: 320, height: 40)
        )
        let oldTail = makeCGImage(width: 100, height: 20)
        let oldContent = CodeBodyLayerContent(
            chunks: [], tailImage: oldTail, tailSize: CGSize(width: 100, height: 20)
        )
        cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame, synchronousContent: [:],
            codeBodyContent: [0: oldContent]
        )
        let newTail = makeCGImage(width: 120, height: 20)
        let newContent = CodeBodyLayerContent(
            chunks: [], tailImage: newTail, tailSize: CGSize(width: 120, height: 20)
        )

        XCTAssertTrue(cell.updateBlockViewport(
            viewportInCell: fragment.frame, synchronousContent: [:], codeBodyContent: [0: newContent]
        ).isEmpty)
        guard let clip = contentLayer(of: cell)?.sublayers?.first(where: { $0.masksToBounds }),
              let tail = clip.sublayers?.first
        else { return XCTFail("Expected code-body clip and tail layers") }
        XCTAssertTrue((tail.contents as! CGImage?) === newTail,
            "A fresh code-body payload must repaint on the incremental viewport path")
    }
}
#endif

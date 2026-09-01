// RenderCellScrollBoundaryTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

/// Covers `RenderCell`'s code-body scroll boundary API (`scrollBoundaryInfo`/`setCodeBodyOffset`)
/// that `CodeBodyScrollAnimator` drives every drag/momentum/spring tick against — see
/// `CodeBodyScrollPhysicsTests` for the pure-math half of the same feature.
@MainActor
final class RenderCellScrollBoundaryTests: XCTestCase {

    // MARK: - Helpers (mirror RenderCellTests.swift's private fixtures)

    private func makeCell(size: CGSize = CGSize(width: 320, height: 400)) -> RenderCell {
        let cell = RenderCell()
        cell.layer.frame = CGRect(origin: .zero, size: size)
        return cell
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

    private func makeCGImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        return context.makeImage()!
    }

    /// A wide code body -- 600pt of content in a 300pt-wide fragment -- so `scrollBoundaryInfo`
    /// reports a nonzero legal range. Mounts via `updateBlockViewport` (not bare `applyLayout`)
    /// so `layerIdentityByFragmentID`/`codeBodyClipLayer` populate exactly as the real scroll
    /// path leaves them.
    @discardableResult
    private func mountWideCodeBody(
        on cell: RenderCell, id: Int = 9, itemID: AnyHashable = "item-1", contentWidth: CGFloat = 600
    ) -> (fragment: Fragment, identity: RenderCell.LayerIdentity) {
        cell.prepareForReuse(for: itemID)
        let fragment = codeTextFragment(
            id: id,
            role: .body(CodeBlockChrome(
                cornerRadius: 0, backgroundColor: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1), language: "swift"
            )),
            frame: CGRect(x: 0, y: 0, width: 300, height: 60)
        )
        let sealed = makeCGImage(width: Int(contentWidth), height: 20)
        let content = CodeBodyLayerContent(
            chunks: [CodeBodyChunk(image: sealed, size: CGSize(width: contentWidth, height: 20))],
            tailImage: nil, tailSize: .zero
        )
        _ = cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame,
            synchronousContent: [:], codeBodyContent: [fragment.id: content]
        )
        guard let identity = cell.layerIdentityByFragmentID[fragment.id] else {
            fatalError("mountWideCodeBody: fragment should have a layer identity after mount")
        }
        return (fragment, identity)
    }

    // MARK: - scrollBoundaryInfo

    func testScrollBoundaryInfoReportsOffsetContentWidthAndViewportWidth() {
        let cell = makeCell()
        let (_, identity) = mountWideCodeBody(on: cell, contentWidth: 600)

        let info = cell.scrollBoundaryInfo(for: identity)

        XCTAssertEqual(info?.offset, 0, "freshly mounted body starts unscrolled")
        XCTAssertEqual(info?.contentWidth, 600)
        XCTAssertEqual(info?.viewportWidth, 300)
    }

    func testScrollBoundaryInfoIsNilForAnUnknownIdentity() {
        let cell = makeCell()
        mountWideCodeBody(on: cell, id: 9)
        let bogusIdentity = RenderCell.LayerIdentity.positional(999)

        XCTAssertNil(cell.scrollBoundaryInfo(for: bogusIdentity))
    }

    // MARK: - setCodeBodyOffset: absolute write

    func testSetCodeBodyOffsetWritesTheExactAbsoluteOffset() {
        let cell = makeCell()
        let (_, identity) = mountWideCodeBody(on: cell, itemID: "item-1", contentWidth: 600)

        let wrote = cell.setCodeBodyOffset(123.5, identity: identity, itemID: "item-1")

        XCTAssertTrue(wrote)
        XCTAssertEqual(cell.scrollBoundaryInfo(for: identity)?.offset, 123.5)
    }

    func testSetCodeBodyOffsetOverwritesAPreviousOffsetRatherThanAccumulating() {
        let cell = makeCell()
        let (_, identity) = mountWideCodeBody(on: cell, itemID: "item-1", contentWidth: 600)

        _ = cell.setCodeBodyOffset(50, identity: identity, itemID: "item-1")
        _ = cell.setCodeBodyOffset(10, identity: identity, itemID: "item-1")

        XCTAssertEqual(cell.scrollBoundaryInfo(for: identity)?.offset, 10, "absolute write, not a delta")
    }

    // MARK: - Item-ID rejection after recycle

    func testSetCodeBodyOffsetRejectsWriteAfterCrossItemRecycle() {
        let cell = makeCell()
        let (_, identity) = mountWideCodeBody(on: cell, itemID: "item-1", contentWidth: 600)
        _ = cell.setCodeBodyOffset(80, identity: identity, itemID: "item-1")

        // Recycle to a different item -- mirrors what FeedScrollView.returnToPool + dequeue do
        // between a cell's uses. The clip layer instance survives recycle, only its offset resets
        // (RenderCell.prepareForReuse's cross-item branch), so scrollBoundaryInfo for the OLD
        // identity is gone once the new item's applyLayout prunes it -- simulate a stale animator
        // tick landing between prepareForReuse and the next applyLayout.
        cell.prepareForReuse(for: "item-2")

        let wroteWithStaleItemID = cell.setCodeBodyOffset(999, identity: identity, itemID: "item-1")

        XCTAssertFalse(wroteWithStaleItemID, "a write carrying the OLD item's ID must be rejected once the cell is bound to a new item")
        // The offset a stale tick tried to write must not have landed.
        XCTAssertNotEqual(cell.scrollBoundaryInfo(for: identity)?.offset, 999)
    }

    func testPrepareForReuseResetsClipOffsetOnCrossItemRecycle() {
        let cell = makeCell()
        let (_, identity) = mountWideCodeBody(on: cell, itemID: "item-1", contentWidth: 600)
        _ = cell.setCodeBodyOffset(80, identity: identity, itemID: "item-1")

        cell.prepareForReuse(for: "item-2")

        XCTAssertEqual(cell.scrollBoundaryInfo(for: identity)?.offset, 0, "a recycled cell must not inherit a different item's horizontal scroll position")
    }

    // MARK: - Identity removal (fragment pruned)

    func testScrollBoundaryInfoAndSetCodeBodyOffsetFailOnceTheIdentityIsPruned() {
        let cell = makeCell()
        let (_, identity) = mountWideCodeBody(on: cell, id: 9, itemID: "item-1", contentWidth: 600)
        _ = cell.setCodeBodyOffset(80, identity: identity, itemID: "item-1")

        // Prune the code-body fragment out of the active set entirely (block left the viewport).
        _ = cell.updateBlockViewport(
            viewportInCell: CGRect(x: 0, y: 9_000, width: 300, height: 20),
            synchronousContent: [:], codeBodyContent: [:]
        )

        XCTAssertNil(cell.scrollBoundaryInfo(for: identity), "identity must no longer resolve once its code body left residency")
        XCTAssertFalse(cell.setCodeBodyOffset(1, identity: identity, itemID: "item-1"), "a write against a pruned identity must be rejected")
    }

    // MARK: - Re-clamp after content-width shrink

    func testContentWidthShrinkReclampsAnOutOfRangeOffset() {
        let cell = makeCell()
        let (fragment, identity) = mountWideCodeBody(on: cell, id: 9, itemID: "item-1", contentWidth: 600)
        // Legal range is [0, 600-300] = [0, 300]; scroll to the max.
        _ = cell.setCodeBodyOffset(300, identity: identity, itemID: "item-1")
        XCTAssertEqual(cell.scrollBoundaryInfo(for: identity)?.offset, 300)

        // Re-tokenize delivers a narrower body (e.g. a shorter longest line): 400pt content in
        // the same 300pt viewport -- new legal max is 100.
        let narrowerSealed = makeCGImage(width: 400, height: 20)
        let narrowerContent = CodeBodyLayerContent(
            chunks: [CodeBodyChunk(image: narrowerSealed, size: CGSize(width: 400, height: 20))],
            tailImage: nil, tailSize: .zero
        )
        _ = cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame,
            synchronousContent: [:], codeBodyContent: [fragment.id: narrowerContent]
        )

        let info = cell.scrollBoundaryInfo(for: identity)
        XCTAssertEqual(info?.contentWidth, 400)
        XCTAssertEqual(info?.offset, 100, "offset must be re-clamped to the new [0, contentWidth - viewportWidth] max, not left pointing past the new content edge")
    }

    /// The legal max is `contentWidth - viewportWidth`, so a viewport that *grows* (a card
    /// widening on rotation, content width unchanged) is what actually shrinks the legal range
    /// -- exercising the same `reclampCodeBodyOffset` path as the content-width-shrink test above.
    func testViewportWidthGrowthReclampsAnOutOfRangeOffset() {
        let bodyRole = CodeBlockRole.body(CodeBlockChrome(
            cornerRadius: 0, backgroundColor: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1), language: "swift"
        ))
        let cell = makeCell()
        let (_, identity) = mountWideCodeBody(on: cell, id: 9, itemID: "item-1", contentWidth: 600)
        // Legal range is [0, 600 - 300] = [0, 300]; scroll to the max.
        _ = cell.setCodeBodyOffset(300, identity: identity, itemID: "item-1")
        XCTAssertEqual(cell.scrollBoundaryInfo(for: identity)?.offset, 300)

        // Card widens (rotation): body fragment frame grows to 550pt, content width unchanged.
        // New legal max is 600 - 550 = 50, well below the current offset of 300.
        let widerFragment = codeTextFragment(id: 9, role: bodyRole, frame: CGRect(x: 0, y: 0, width: 550, height: 60))
        let sealed = makeCGImage(width: 600, height: 20)
        let content = CodeBodyLayerContent(
            chunks: [CodeBodyChunk(image: sealed, size: CGSize(width: 600, height: 20))],
            tailImage: nil, tailSize: .zero
        )
        _ = cell.updateBlockViewport(
            fragments: [widerFragment], viewportInCell: widerFragment.frame,
            synchronousContent: [:], codeBodyContent: [widerFragment.id: content]
        )

        let info = cell.scrollBoundaryInfo(for: identity)
        XCTAssertEqual(info?.viewportWidth, 550)
        XCTAssertEqual(info?.offset, 50, "offset must be re-clamped to the new, smaller legal max after the viewport grows")
    }

    // MARK: - Reclamp suppression while CodeBodyScrollAnimator owns the offset

    /// Regression for the right-edge bounce stutter: `reclampCodeBodyOffset` (fired by every
    /// layout/recolor pass) used to hard-snap an in-flight overdrag back to `maxOffset`,
    /// stomping on `CodeBodyScrollAnimator`'s ground-truth offset mid-spring. Left-edge overdrag
    /// (offset < 0) was never affected since reclamp only ever clamped the upper bound.
    func testReclamp_SkippedWhileAnimatorIsDrivingOffset_ThenResumesAfterAnimatorSettles() {
        let cell = makeCell()
        let (fragment, identity) = mountWideCodeBody(on: cell, id: 9, itemID: "item-1", contentWidth: 600)
        // Legal max is 600 - 300 = 300.
        let animator = CodeBodyScrollAnimator()
        animator.beginDrag(cell: cell, identity: identity, itemID: "item-1")

        // Simulate an intentional right-edge overdrag the animator is mid-spring on.
        _ = cell.setCodeBodyOffset(400, identity: identity, itemID: "item-1")
        XCTAssertEqual(cell.scrollBoundaryInfo(for: identity)?.offset, 400)

        // A layout/recolor pass lands mid-animation (e.g. a late tree-sitter delivery) -- the
        // exact `applyLayout` path that calls `reclampCodeBodyOffset` on every pass.
        let sealed = makeCGImage(width: 600, height: 20)
        let content = CodeBodyLayerContent(
            chunks: [CodeBodyChunk(image: sealed, size: CGSize(width: 600, height: 20))],
            tailImage: nil, tailSize: .zero
        )
        _ = cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame,
            synchronousContent: [:], codeBodyContent: [fragment.id: content]
        )

        XCTAssertEqual(
            cell.scrollBoundaryInfo(for: identity)?.offset, 400,
            "reclamp must not yank the offset back to maxOffset while the animator is actively driving an overdrag"
        )

        // Animator finishes (mirrors the recycle path's `cancelInFlightWork` -> `settle`) --
        // reclamp is live again on the very next layout/recolor pass.
        animator.cancelInFlightWork()
        _ = cell.updateBlockViewport(
            fragments: [fragment], viewportInCell: fragment.frame,
            synchronousContent: [:], codeBodyContent: [fragment.id: content]
        )

        XCTAssertEqual(
            cell.scrollBoundaryInfo(for: identity)?.offset, 300,
            "once the animator has settled, reclamp must resume and pull the overdragged offset back in range"
        )
    }
}
#endif

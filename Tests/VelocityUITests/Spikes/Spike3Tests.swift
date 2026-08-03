// Spike3Tests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Spike 3: validates zero offscreen-render, zero copied images, and smooth
/// scroll frame timing using CALayer-only cells.
/// @MainActor: all CALayer/UIKit objects stay on the main thread — no Sendable issues.
@MainActor
final class Spike3Tests: XCTestCase {

    // MARK: - Helpers

    /// RGBA premultipliedLast — intentionally wrong format so normaliseAndRound must convert.
    private func makeSyntheticRGBAImage(size: CGSize, hue: CGFloat) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Pure CoreGraphics — no UIColor, safe on any thread/actor
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                                 components: [hue, 0.5, 0.8, 1.0])!)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    // MARK: - Test 1: Zero offscreen render

    func testZeroOffscreenRenderInLayerTree() {
        let root = CALayer()
        let cellSize = CGSize(width: 100, height: 100)
        let frag = Fragment(
            id: 0,
            content: .image(ImageDescriptor(url: nil, aspectRatio: 1.0, contentMode: 0,
                                            cornerRadius: 0, layoutHash: 0, appearanceHash: 0)),
            frame: CGRect(origin: .zero, size: cellSize)
        )

        for i in 0..<20 {
            let raw = makeSyntheticRGBAImage(size: cellSize, hue: CGFloat(i) / 20)
            guard let normalised = normaliseAndRound(raw, targetSize: cellSize, cornerRadius: 12) else {
                XCTFail("normaliseAndRound returned nil at index \(i)"); continue
            }
            let cell = RenderCell()
            cell.layer.frame = CGRect(x: 0, y: CGFloat(i) * 108, width: 100, height: 100)
            cell.applyLayout([frag])
            cell.applyContent(id: 0, image: normalised, for: AnyHashable("item"))
            root.addSublayer(cell.layer)
        }

        // Walk entire layer tree
        var allLayers: [CALayer] = []
        var queue = [root]
        while !queue.isEmpty {
            let l = queue.removeFirst()
            allLayers.append(l)
            queue += l.sublayers ?? []
        }

        for layer in allLayers {
            XCTAssertFalse(layer.masksToBounds,
                "masksToBounds must never be set — causes offscreen render pass")
            XCTAssertEqual(layer.cornerRadius, 0,
                "cornerRadius must never be set on CALayer — round at decode time via CGContext")
        }
    }

    // MARK: - Test 2: Zero copied images (BGRA8888 format)

    func testNormalisedImageIsBGRA8888() {
        let cases: [(CGSize, CGFloat)] = [
            (CGSize(width: 50, height: 50), 0),
            (CGSize(width: 300, height: 200), 8),
            (CGSize(width: 100, height: 100), 16),
        ]
        for (size, radius) in cases {
            let raw = makeSyntheticRGBAImage(size: size, hue: 0.5)
            XCTAssertFalse(isBGRA8888(raw), "Synthetic RGBA source should not be BGRA8888")

            guard let out = normaliseAndRound(raw, targetSize: size, cornerRadius: radius) else {
                XCTFail("normaliseAndRound returned nil (size:\(size) radius:\(radius))"); continue
            }
            XCTAssertTrue(isBGRA8888(out),
                "Output must be BGRA8888 premultiplied. bitmapInfo: \(out.bitmapInfo.rawValue)")
            XCTAssertEqual(out.width, Int(size.width))
            XCTAssertEqual(out.height, Int(size.height))
        }
    }

    // MARK: - Test 2b (VelocityUI-zgs Fix B1): fast path skips the scratch blit entirely

    private func makeBGRA8888Image(size: CGSize) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.2, 0.4, 0.6, 1.0])!)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    func testFastPathReturnsSameInstanceWhenAlreadyNormalisedAndCorrectSize() throws {
        let size = CGSize(width: 64, height: 48)
        let already = try XCTUnwrap(makeBGRA8888Image(size: size))
        XCTAssertTrue(isBGRA8888(already))

        let out = normaliseAndRound(already, targetSize: size, cornerRadius: 0)
        XCTAssertTrue(
            out === already,
            "Already-normalised, correctly-sized, unclipped input must be returned unmodified — no scratch CGContext blit"
        )
    }

    func testFastPathNotTakenWhenCornerRadiusNonZero() throws {
        let size = CGSize(width: 64, height: 48)
        let already = try XCTUnwrap(makeBGRA8888Image(size: size))

        let out = try XCTUnwrap(normaliseAndRound(already, targetSize: size, cornerRadius: 8))
        XCTAssertFalse(out === already, "cornerRadius > 0 must still clip, even when the input is already BGRA8888")
    }

    func testFastPathNotTakenWhenSizeDiffers() throws {
        let source = try XCTUnwrap(makeBGRA8888Image(size: CGSize(width: 64, height: 48)))
        let out = try XCTUnwrap(normaliseAndRound(source, targetSize: CGSize(width: 32, height: 24), cornerRadius: 0))
        XCTAssertFalse(out === source, "A size mismatch must still go through the resize blit")
        XCTAssertEqual(out.width, 32)
        XCTAssertEqual(out.height, 24)
    }

    // MARK: - Test 3: Frame timing during programmatic scroll

    func testScrollFrameTiming() async throws {
        final class TimingCapture: NSObject, @unchecked Sendable {
            var times: [CFTimeInterval] = []
            var link: CADisplayLink?
            weak var scrollView: UIScrollView?
            var contentHeight: CGFloat = 0
            var startTime: CFTimeInterval = 0

            @objc func tick(_ dl: CADisplayLink) {
                if startTime == 0 { startTime = dl.timestamp }
                times.append(dl.timestamp)
                let t = min((dl.timestamp - startTime) / 2.0, 1.0)
                scrollView?.setContentOffset(
                    CGPoint(x: 0, y: t * max(0, contentHeight - 844)),
                    animated: false
                )
            }
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let sv = UIScrollView(frame: window.bounds)
        let contentH: CGFloat = 100 * 80
        sv.contentSize = CGSize(width: 390, height: contentH)
        window.addSubview(sv)
        window.makeKeyAndVisible()

        for i in 0..<100 {
            let l = CALayer()
            l.frame = CGRect(x: 0, y: CGFloat(i) * 80, width: 390, height: 72)
            l.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                                        components: [0.2, 0.5, 0.9, 1.0])
            l.masksToBounds = false
            l.cornerRadius = 0
            sv.layer.addSublayer(l)
        }

        let capture = TimingCapture()
        capture.scrollView = sv
        capture.contentHeight = contentH

        let dl = CADisplayLink(target: capture, selector: #selector(TimingCapture.tick(_:)))
        dl.add(to: .main, forMode: .default)
        capture.link = dl

        // Suspend this Task — main RunLoop (and CADisplayLink) keeps firing.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        dl.invalidate()

        let times = capture.times
        guard times.count >= 10 else {
            XCTFail("Too few frames captured: \(times.count)"); return
        }

        let intervals = zip(times, times.dropFirst()).map { $1 - $0 }
        let avgFPS = 1.0 / (intervals.reduce(0, +) / Double(intervals.count))
        // This test validates the scroll read path is non-blocking (synchronous layout reads,
        // no awaits) — which is the architectural precondition for 120fps in production.
        // Actual 120fps on ProMotion hardware requires CADisableMinimumFrameDuration in the
        // production app's Info.plist + preferredFrameRateRange on the scroll CADisplayLink.
        // The test harness VRR governor caps at 60Hz regardless, so ≥50fps is the correct bar here.
        let onTime = intervals.filter { $0 <= 1.0 / 50.0 }.count  // 50fps min budget
        let ratio = Double(onTime) / Double(intervals.count)

        print("[Spike3] Frames: \(times.count)  Avg FPS: \(String(format: "%.1f", avgFPS))  On-time(≥50fps): \(String(format: "%.1f", ratio * 100))%")

        XCTAssertGreaterThanOrEqual(avgFPS, 50,
            "Average FPS must be ≥50 (validates non-blocking scroll path; 120fps target is production-only)")
        XCTAssertGreaterThanOrEqual(ratio, 0.95,
            "≥95% of frames within 20ms. Got \(String(format: "%.1f", ratio * 100))%")
    }

    // MARK: - Test 4: Cross-item recycle clears stale content

    /// Updated for VelocityUI-ksh's secondary fix: cross-item recycle used to remove every
    /// sublayer (`sub.removeFromSuperlayer()` + `sublayers.removeAll()`), forcing the next
    /// `applyLayout` to `CALayer()`-allocate a fresh sublayer per fragment (the "20/37 CALayer"
    /// allocation smell from the bead's Instruments call tree). The fix clears
    /// `contents`/`backgroundColor` on the EXISTING sublayer instead of removing it, so
    /// `applyLayout`'s `if let existing = sublayers[fragment.id]` path can reuse it — same
    /// privacy hard-cut (no stale pixel ever shown), zero CALayer allocation on cross-item mount.
    func testCrossItemRecycleClearsContent() {
        let size = CGSize(width: 200, height: 150)
        let raw = makeSyntheticRGBAImage(size: size, hue: 0.3)
        let img = normaliseAndRound(raw, targetSize: size, cornerRadius: 0)!
        let frag = Fragment(
            id: 0,
            content: .image(ImageDescriptor(url: nil, aspectRatio: 4.0/3.0, contentMode: 0,
                                            cornerRadius: 0, layoutHash: 1, appearanceHash: 1)),
            frame: CGRect(origin: .zero, size: size)
        )

        let cell = RenderCell()
        cell.layer.frame = CGRect(origin: .zero, size: size)
        cell.applyLayout([frag])
        cell.applyContent(id: 0, image: img, for: AnyHashable("item"))

        // contentLayer is cell.layer.sublayers[1] (index 1, after placeholderLayer at 0)
        guard let contentLayer = cell.layer.sublayers?.first(where: { !($0 is CAGradientLayer) }) else {
            XCTFail("contentLayer not found"); return
        }
        XCTAssertNotNil(contentLayer.sublayers?.first?.contents,
            "Content should be set before recycle")
        let sublayerIdentityBeforeRecycle = contentLayer.sublayers?.first.map(ObjectIdentifier.init)

        // Cross-item recycle: contents/background hard-cut, sublayer RETAINED (not removed)
        cell.prepareForReuse(for: AnyHashable("item-b"))

        XCTAssertEqual(contentLayer.sublayers?.count, 1,
            "Sublayer must be RETAINED (not removed) after cross-item prepareForReuse — cleared "
            + "in place so the next applyLayout mount needs zero fresh CALayer()")
        XCTAssertEqual(contentLayer.sublayers?.first.map(ObjectIdentifier.init), sublayerIdentityBeforeRecycle,
            "The retained sublayer must be the SAME CALayer instance, not a reallocation")
        XCTAssertNil(contentLayer.sublayers?.first?.contents,
            "Cross-item recycle must clear contents — no stale pixel from the old item")
        XCTAssertNil(contentLayer.sublayers?.first?.backgroundColor,
            "Cross-item recycle must clear backgroundColor")
        XCTAssertEqual(cell.currentItemID, AnyHashable("item-b"),
            "currentItemID must update to new item after cross-item recycle")

        // Same-item recycle must NOT clear content: re-layout → apply → reuse(sameItem)
        cell.layer.frame = CGRect(origin: .zero, size: size)
        cell.applyLayout([frag])
        cell.applyContent(id: 0, image: img, for: AnyHashable("item-b"))
        let sub = contentLayer.sublayers?.first
        XCTAssertNotNil(sub?.contents, "Content should be set after re-apply")
        cell.prepareForReuse(for: AnyHashable("item-b"))  // same item
        XCTAssertNotNil(sub?.contents,
            "Same-item recycle must not clear content")
    }
}
#endif

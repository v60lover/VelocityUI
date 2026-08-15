// TextLineBreakParityTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

/// Bead VelocityUI-ezo.2.4: lineBreakMode must reach both the measure and render paths
/// identically, for every NSLineBreakMode value, and truncated-height parity (maximumNumberOfLines
/// set + overflowing content) must hold within 1pt just like the untruncated case.
final class TextLineBreakParityTests: XCTestCase {

    private let allModes: [NSLineBreakMode] = [
        .byWordWrapping, .byCharWrapping, .byClipping,
        .byTruncatingHead, .byTruncatingTail, .byTruncatingMiddle
    ]

    private func makeDescriptor(
        content: String,
        lineLimit: Int?,
        lineBreakMode: NSLineBreakMode
    ) -> TextDescriptor {
        TextDescriptor(
            content: content,
            font: VFontDescriptor(size: 16, weight: 0),
            color: VColorDescriptor(red: 0, green: 0, blue: 0, alpha: 1),
            lineLimit: lineLimit,
            lineBreakMode: lineBreakMode.rawValue,
            layoutHash: 0,
            appearanceHash: 0
        )
    }

    /// Mirrors Spike4Tests/TextAttributeBuilderTests' pixel-scan helper: last non-transparent
    /// row from the bottom, in points (scale = 1).
    private func actualContentHeight(in image: CGImage) -> CGFloat {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for row in stride(from: h - 1, through: 0, by: -1) {
            for col in 0..<w {
                if bytes[(row * w + col) * 4 + 3] > 0 { return CGFloat(row + 1) }
            }
        }
        return 0
    }

    private func assertParity(
        _ descriptor: TextDescriptor,
        width: CGFloat,
        label: String,
        measureCtx: TextMeasurementContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let measured = measureCtx.measure(descriptor, width: width)
        XCTAssertGreaterThan(measured.width, 0, "\(label): zero measured width", file: file, line: line)
        XCTAssertGreaterThan(measured.height, 0, "\(label): zero measured height", file: file, line: line)

        guard let image = rasterizeText(descriptor, size: measured) else {
            XCTFail("\(label): rasterizeText returned nil", file: file, line: line)
            return
        }
        let inkHeight = actualContentHeight(in: image)
        XCTAssertLessThanOrEqual(
            inkHeight, measured.height + 1,
            "\(label): ink \(inkHeight)pt overflowed measured \(measured.height)pt by more than 1pt",
            file: file, line: line
        )
    }

    // MARK: - Single-line: every mode, content that never wraps regardless of mode

    func testSingleLineMeasureEqualsRenderForEveryLineBreakMode() {
        let measureCtx = TextMeasurementContext()
        for mode in allModes {
            let descriptor = makeDescriptor(content: "Short parity line.", lineLimit: nil, lineBreakMode: mode)
            assertParity(descriptor, width: 320, label: "single-line/\(mode.rawValue)", measureCtx: measureCtx)
        }
    }

    // MARK: - Multi-line wrap: every mode, long content forced to wrap at a narrow width

    func testMultiLineWrapMeasureEqualsRenderForEveryLineBreakMode() {
        let measureCtx = TextMeasurementContext()
        let longContent = String(repeating: "wrapping parity text ", count: 8)
        for mode in allModes {
            let descriptor = makeDescriptor(content: longContent, lineLimit: nil, lineBreakMode: mode)
            assertParity(descriptor, width: 150, label: "multi-line-wrap/\(mode.rawValue)", measureCtx: measureCtx)
        }
    }

    // MARK: - Truncated: lineLimit set + content overflowing it, every mode

    func testTruncatedMeasureEqualsRenderForEveryLineBreakMode() {
        let measureCtx = TextMeasurementContext()
        let longContent = String(repeating: "wrapping parity text ", count: 8)
        for mode in allModes {
            let descriptor = makeDescriptor(content: longContent, lineLimit: 2, lineBreakMode: mode)
            assertParity(descriptor, width: 150, label: "truncated/\(mode.rawValue)", measureCtx: measureCtx)
        }
    }

    // MARK: - Full matrix: mode x lineLimit x width, per the bead's acceptance criteria

    func testParityMatrixAcrossModeLineLimitAndWidth() {
        let measureCtx = TextMeasurementContext()
        let content = String(repeating: "matrix parity text ", count: 6)
        let lineLimits: [Int?] = [nil, 1, 2]
        let widths: [CGFloat] = [320, 150, 80]

        for mode in allModes {
            for lineLimit in lineLimits {
                for width in widths {
                    let descriptor = makeDescriptor(content: content, lineLimit: lineLimit, lineBreakMode: mode)
                    let label = "mode=\(mode.rawValue)/lineLimit=\(String(describing: lineLimit))/width=\(width)"
                    assertParity(descriptor, width: width, label: label, measureCtx: measureCtx)
                }
            }
        }
    }

    // MARK: - lineBreakMode reaches the paragraph style even without lineLimit/lineSpacing

    /// Regression guard for the makeAttributes() gate: previously a non-default lineBreakMode
    /// with no lineLimit and no lineSpacing was silently dropped from the attributed string.
    func testNonDefaultLineBreakModeAloneBuildsParagraphStyle() {
        let descriptor = makeDescriptor(content: "text", lineLimit: nil, lineBreakMode: .byCharWrapping)
        let para = descriptor.makeAttributes()[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(para?.lineBreakMode, .byCharWrapping)
    }

    /// .byWordWrapping (the default) alone must NOT add a paragraphStyle attribute -- matches
    /// NSMutableParagraphStyle's own default, keeps the no-lineLimit/no-lineSpacing case a
    /// no-op for every existing caller (Spike4Tests, TextAttributeBuilderTests use lineBreakMode: 0).
    func testDefaultLineBreakModeAloneDoesNotBuildParagraphStyle() {
        let descriptor = makeDescriptor(content: "text", lineLimit: nil, lineBreakMode: .byWordWrapping)
        XCTAssertNil(descriptor.makeAttributes()[.paragraphStyle])
    }
}
#endif

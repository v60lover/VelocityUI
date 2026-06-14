// DimensionCacheTests.swift

#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

final class DimensionCacheTests: XCTestCase {

    // MARK: - Helpers

    // scale=1 forces 1:1 pt→px mapping so kCGImagePropertyPixelWidth == the logical size.
    // Default scale on iPhone simulator is 3× — without this fix reported pixels are 3× the
    // logical size and all dimension assertions fail.
    private func makeFormat() -> UIGraphicsImageRendererFormat {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return fmt
    }

    private func jpegData(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: makeFormat())
        return renderer.jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func pngData(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: makeFormat())
        return renderer.pngData { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - Test 1: JPEG dimensions parsed from first 1 KB

    func testJPEGDimensionsParsedFromFirst1KB() {
        let full = jpegData(width: 200, height: 150)
        let size = DimensionCache.parse(from: Data(full.prefix(1024)))
        XCTAssertNotNil(size, "JPEG dimensions must be readable from first 1 KB")
        XCTAssertEqual(size?.width, 200)
        XCTAssertEqual(size?.height, 150)
    }

    // MARK: - Test 2: PNG dimensions parsed from first 1 KB

    func testPNGDimensionsParsedFromFirst1KB() {
        let full = pngData(width: 300, height: 100)
        let size = DimensionCache.parse(from: Data(full.prefix(1024)))
        XCTAssertNotNil(size, "PNG IHDR is at bytes 8–33, so dimensions are available in first 1 KB")
        XCTAssertEqual(size?.width, 300)
        XCTAssertEqual(size?.height, 100)
    }

    // MARK: - Test 3: Overly truncated data returns nil without crashing

    func testOverlyTruncatedDataReturnsNil() {
        let full = jpegData(width: 100, height: 100)
        XCTAssertNil(DimensionCache.parse(from: Data(full.prefix(4))),
            "4-byte truncation (SOI only, no SOF) must return nil, not crash")
    }

    // MARK: - Test 4: Non-image data (e.g. HTML error page) returns nil

    func testNonImageDataReturnsNil() {
        let garbage = Data("<html>Not Found</html>".utf8)
        XCTAssertNil(DimensionCache.parse(from: garbage),
            "HTML error body must parse to nil — most likely real-world 200+garbage failure mode")
    }

    // MARK: - Test 5: Sync get returns cached value set via store

    func testSyncCacheHitReturnsCachedSize() {
        let cache = DimensionCache()
        let url = URL(string: "https://example.com/image.jpg")!
        let stored = CGSize(width: 640, height: 480)

        cache.store(stored, for: url)

        XCTAssertEqual(cache.get(url), stored, "Sync get must return the stored size immediately")
    }

    // MARK: - Test 6: dimensions(for:) caches result after file:// fetch

    // NOTE: file:// URLs cause URLSession to ignore the Range header and return the full file.
    // This exercises the 200-status fallback path in fetchAndParse (server ignores Range).
    // The actual 206 partial-content round-trip is not tested here (no localhost HTTP server per
    // bead spec); Range header construction is verified separately in Test 7.
    func testDimensionsForFileCachesResult() async throws {
        let data = pngData(width: 80, height: 60)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = DimensionCache()
        let size = await cache.dimensions(for: url)
        XCTAssertEqual(size?.width, 80)
        XCTAssertEqual(size?.height, 60)

        // Sync get must return the cached value — no second network call
        XCTAssertEqual(cache.get(url), size, "Result must be cached after first fetch")
    }

    // MARK: - Test 7: rangedRequest carries Range: bytes=0-1023

    func testRangedRequestHasCorrectHeader() {
        let url = URL(string: "https://example.com/image.jpg")!
        let req = DimensionCache.rangedRequest(for: url)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
    }

    // MARK: - Test 8: Concurrent dimensions(for:) calls for same URL return identical sizes

    // NOTE: This test proves "coalescing didn't break correctness," not "coalescing engaged."
    // Proving the latter requires a fetch-count probe (URLProtocol counter or an internal
    // var probeCount). Deferred to a future hardening bead — correctness is the gate here.
    func testConcurrentDimensionsCallsCoalesce() async throws {
        let data = pngData(width: 55, height: 42)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = DimensionCache()

        // Fire 10 concurrent calls for the same URL. All must return the same size.
        let results: [CGSize?] = await withTaskGroup(of: CGSize?.self) { group in
            for _ in 0..<10 {
                group.addTask { await cache.dimensions(for: url) }
            }
            var sizes: [CGSize?] = []
            for await s in group { sizes.append(s) }
            return sizes
        }

        XCTAssertTrue(results.allSatisfy { $0 == CGSize(width: 55, height: 42) },
            "All concurrent calls for the same URL must return identical dimensions")
    }

    // MARK: - Test 9: Concurrent store/get from 1000 tasks is TSan-clean

    func testConcurrentAccessIsSafe() async {
        let cache = DimensionCache()
        let url = URL(string: "https://example.com/img.jpg")!

        // Each even task writes a distinct size (width == height == i); odd tasks read.
        // Post-condition: final value must be one of the 500 written sizes — proving
        // "last write wins coherently" under concurrency, not just "no crash."
        let legalSizes = (0..<1000).filter { $0.isMultiple(of: 2) }
            .map { CGSize(width: $0, height: $0) }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        cache.store(CGSize(width: i, height: i), for: url)
                    } else {
                        _ = cache.get(url)
                    }
                }
            }
        }

        let result = cache.get(url)
        XCTAssertNotNil(result, "Cache must hold a value after 500 concurrent stores")
        if let result {
            XCTAssertTrue(legalSizes.contains(result),
                "Final value \(result) must be one of the 500 distinct written sizes")
        }
    }
}
#endif

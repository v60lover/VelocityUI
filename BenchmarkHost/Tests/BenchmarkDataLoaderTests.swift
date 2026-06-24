// BenchmarkDataLoaderTests.swift

import Nuke
import XCTest
@testable import BenchmarkHost

final class BenchmarkDataLoaderTests: XCTestCase {

    // MARK: - Conformance smoke

    func testBenchmarkPipelineConstructs() {
        // Accessing ImagePipeline.benchmark forces the static initializer, which
        // constructs BenchmarkDataLoader and passes it to ImagePipeline.Configuration.
        // If BenchmarkDataLoader no longer conforms to DataLoading this will fail to compile.
        XCTAssertNotNil(ImagePipeline.benchmark)
    }

    // MARK: - Valid URL

    func testValidURLReturnsData() async throws {
        let url = try XCTUnwrap(URL(string: "benchmark://fixture/0"))
        let (data, _) = try await ImagePipeline.benchmark.data(for: url)
        XCTAssertFalse(data.isEmpty, "Expected non-empty PNG data for benchmark://fixture/0")
    }

    func testValidURLProducesDecodableImage() async throws {
        let url = try XCTUnwrap(URL(string: "benchmark://fixture/0"))
        let (data, _) = try await ImagePipeline.benchmark.data(for: url)
        let image = try XCTUnwrap(UIImage(data: data), "PNG data must decode to a UIImage")
        XCTAssertEqual(image.size.width, BenchmarkItem.thumbWidth, accuracy: 1,
            "Image width must match BenchmarkItem.thumbWidth")
    }

    // MARK: - Invalid scheme

    func testInvalidSchemeThrows() async {
        let url = URL(string: "https://example.com/x.png")!
        do {
            _ = try await ImagePipeline.benchmark.data(for: url)
            XCTFail("Expected an error for https:// URL routed through BenchmarkDataLoader")
        } catch {
            // Expected — BenchmarkDataLoader rejects non-benchmark:// schemes.
        }
    }

    // MARK: - Invalid path component

    func testNonIntegerPathComponentThrows() async {
        let url = URL(string: "benchmark://fixture/notanumber")!
        do {
            _ = try await ImagePipeline.benchmark.data(for: url)
            XCTFail("Expected an error for benchmark URL with non-integer path component")
        } catch {
            // Expected.
        }
    }

    // MARK: - Palette stability

    func testSameIDProducesIdenticalBytes() async throws {
        let url = try XCTUnwrap(URL(string: "benchmark://fixture/3"))
        let (first, _)  = try await ImagePipeline.benchmark.data(for: url)
        let (second, _) = try await ImagePipeline.benchmark.data(for: url)
        XCTAssertEqual(first, second, "PNG output must be deterministic for the same fixture ID")
    }
}

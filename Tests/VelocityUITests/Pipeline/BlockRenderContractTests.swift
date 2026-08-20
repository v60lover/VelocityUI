// BlockRenderContractTests.swift

@testable import VelocityUI
import XCTest

final class BlockRenderContractTests: XCTestCase {
    func testImageContractSeparatesHashesAndCarriesRequestIdentity() {
        let descriptor = ImageDescriptor(
            url: URL(string: "https://example.com/photo.jpg"),
            aspectRatio: 2,
            contentMode: VContentMode.fit.rawValue,
            cornerRadius: 8,
            layoutHash: 101,
            appearanceHash: 202
        )
        let table = makeTable(nodes: [.image(descriptor)], blockIDs: [BlockID("photo")])

        let contract = try! XCTUnwrap(table.blockRenderContract(at: 0, itemID: "item"))

        XCTAssertEqual(contract.geometryHash, 101)
        XCTAssertEqual(contract.appearanceHash, 202)
        guard case .aspectRatio(2) = contract.geometry else {
            return XCTFail("image geometry should retain its aspect ratio")
        }
        guard case .image(let request)? = contract.contentRequest?.kind else {
            return XCTFail("image contract should request image content")
        }
        XCTAssertEqual(request.url, descriptor.url)
        XCTAssertEqual(contract.contentRequest?.key, BlockKey(itemID: "item", blockID: BlockID("photo")))
    }

    func testStandInLeavesUseOnlyGeometryAndPresentationCapabilities() {
        let gif = GIFDescriptor(url: URL(string: "https://example.com/a.gif"), loopCount: 0, autoplay: true, layoutHash: 1, appearanceHash: 2)
        let video = VideoDescriptor(url: URL(string: "https://example.com/a.mp4"), autoplayThreshold: 0.5, muted: true, loopEnabled: false, layoutHash: 3, appearanceHash: 4)
        let table = makeTable(nodes: [
            .hosting(HostingDescriptor(size: CGSize(width: 30, height: 40), layoutHash: 5, appearanceHash: 6)),
            .gif(gif),
            .video(video),
            .customLayer(CGSize(width: 50, height: 60)),
            .spacer(12)
        ])

        let contracts = table.nodes.indices.compactMap { table.blockRenderContract(at: $0, itemID: "item") }

        XCTAssertEqual(contracts.count, 5)
        XCTAssertNil(contracts[0].contentRequest)
        XCTAssertNotNil(contracts[1].contentRequest)
        XCTAssertNotNil(contracts[2].contentRequest)
        guard case .fixed(CGSize(width: 30, height: 40)) = contracts[0].geometry,
              case .fixed(CGSize(width: 50, height: 60)) = contracts[3].geometry,
              case .spacer(12) = contracts[4].geometry else {
            return XCTFail("stand-ins should compose existing geometry policies")
        }
        for contract in contracts {
            guard case .geometry = contract.presentation else {
                return XCTFail("stand-ins should not require a new presentation branch")
            }
        }
    }

    func testContentDeliveryKeepsRequestGeneration() {
        let key = BlockKey(itemID: "item", blockID: BlockID("map"))
        let delivery = BlockContentDelivery(key: key, generation: 17, value: "bitmap")

        XCTAssertEqual(delivery.key, key)
        XCTAssertEqual(delivery.generation, 17)
        XCTAssertEqual(delivery.value, "bitmap")
    }

    func testAppearanceChangeKeepsGeometryHashAndAdvancesRequestGeneration() {
        let first = ImageDescriptor(
            url: URL(string: "https://example.com/photo.jpg"),
            aspectRatio: 2,
            contentMode: VContentMode.fit.rawValue,
            cornerRadius: 0,
            layoutHash: 101,
            appearanceHash: 201
        )
        let second = ImageDescriptor(
            url: first.url,
            aspectRatio: 2,
            contentMode: VContentMode.fit.rawValue,
            cornerRadius: 12,
            layoutHash: 101,
            appearanceHash: 202
        )

        let firstContract = try! XCTUnwrap(makeTable(nodes: [.image(first)]).blockRenderContract(at: 0, itemID: "item"))
        let secondContract = try! XCTUnwrap(makeTable(nodes: [.image(second)]).blockRenderContract(at: 0, itemID: "item"))

        XCTAssertEqual(firstContract.geometryHash, secondContract.geometryHash)
        XCTAssertNotEqual(firstContract.appearanceHash, secondContract.appearanceHash)
        XCTAssertNotEqual(firstContract.contentRequest?.generation, secondContract.contentRequest?.generation)
    }

    private func makeTable(nodes: [NodeKind], blockIDs: [BlockID?]? = nil) -> NodeTable {
        NodeTable(
            itemID: "item",
            nodes: nodes,
            parentIndices: Array(repeating: -1, count: nodes.count),
            layoutHash: 0,
            appearanceHash: 0,
            blockIDs: blockIDs
        )
    }
}

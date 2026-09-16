#if canImport(UIKit)
import XCTest
import UIKit
@testable import VelocityUI

@MainActor
final class HotTableRasterizerStoreTests: XCTestCase {
    private actor RenderGate {
        private var enteredGenerations: [Int] = []
        private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        private var released: Set<Int> = []
        private var cancelledGenerations: [Int] = []

        func wait(_ generation: Int) async {
            if released.contains(generation) || Task.isCancelled {
                if Task.isCancelled { cancelledGenerations.append(generation) }
                return
            }
            enteredGenerations.append(generation)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released.contains(generation) {
                        continuation.resume()
                    } else {
                        waiters[generation, default: []].append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancel(generation) }
            }
        }

        func release(_ generation: Int) {
            released.insert(generation)
            waiters.removeValue(forKey: generation)?.forEach { $0.resume() }
        }

        func cancel(_ generation: Int) {
            cancelledGenerations.append(generation)
            waiters.removeValue(forKey: generation)?.forEach { $0.resume() }
        }

        func entered() -> [Int] { enteredGenerations }
        func cancelled() -> [Int] { cancelledGenerations }
    }

    private func descriptor(_ value: String) -> MarkdownTableDescriptor {
        let text = TextDescriptor(
            content: value,
            font: VFontDescriptor(size: 14, weight: 0),
            color: .primary,
            lineLimit: nil,
            lineBreakMode: VLineBreakMode.byWordWrapping.rawValue,
            layoutHash: 0,
            appearanceHash: 0
        )
        return MarkdownTableDescriptor(
            cells: [[text]], alignments: [.none], blockID: nil, lifecycle: .hot,
            layoutHash: 0, appearanceHash: 0
        )
    }

    private func snapshot(_ value: String, key: BlockKey, isFinal: Bool = false) -> HotTableRenderSnapshot {
        HotTableRenderSnapshot(
            key: key, generation: 0, descriptor: descriptor(value), width: 240, scale: 1,
            isFinal: isFinal
        )
    }

    private func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true", file: file, line: line)
    }

    func testRapidMutationsKeepOneActiveAndLatestPendingThenDeliverProgressiveAndFinal() async {
        let store = HotTableRasterizerStore()
        let gate = RenderGate()
        let key = BlockKey(itemID: "message", index: 0)
        let deliveries = DeliveryLog()
        let resultImage = image()
        let renderer: HotTableRasterizerStore.Renderer = { snapshot in
            await gate.wait(snapshot.generation)
            return HotTableRenderResult(
                key: snapshot.key, generation: snapshot.generation, image: resultImage, size: .init(width: 1, height: 1)
            )
        }

        for index in 0..<20 {
            store.submit(snapshot("row \(index)", key: key, isFinal: index == 19), renderer: renderer) { result, isFinal in
                deliveries.append(result.generation, isFinal: isFinal)
            }
        }
        await waitUntil { (await gate.entered()).count == 1 }
        let firstEntered = await gate.entered()
        XCTAssertEqual(firstEntered, [1], "rapid submissions must leave only the first render active")

        await gate.release(1)
        await waitUntil { (await gate.entered()).count == 2 }
        let enteredAfterProgressive = await gate.entered()
        XCTAssertEqual(enteredAfterProgressive, [1, 20], "intermediate pending snapshots must be replaced by the latest")
        XCTAssertEqual(deliveries.generations, [1], "the active render must deliver progressively before final work starts")

        await gate.release(20)
        await waitUntil { deliveries.generations.count == 2 }
        XCTAssertEqual(deliveries.generations, [1, 20])
        XCTAssertEqual(deliveries.finalFlags, [false, true])
    }

    func testOlderCompletionCannotOverwriteDeliveredGeneration() async {
        let store = HotTableRasterizerStore()
        let gate = RenderGate()
        let key = BlockKey(itemID: "message", index: 1)
        let deliveries = DeliveryLog()
        let resultImage = image()
        let renderer: HotTableRasterizerStore.Renderer = { snapshot in
            await gate.wait(snapshot.generation)
            let generation = snapshot.generation == 2 ? 1 : snapshot.generation
            return HotTableRenderResult(key: snapshot.key, generation: generation, image: resultImage, size: .init(width: 1, height: 1))
        }

        store.submit(snapshot("first", key: key), renderer: renderer) { result, isFinal in
            deliveries.append(result.generation, isFinal: isFinal)
        }
        await waitUntil { (await gate.entered()).count == 1 }
        await gate.release(1)
        await waitUntil { deliveries.generations == [1] }

        store.submit(snapshot("second", key: key), renderer: renderer) { result, isFinal in
            deliveries.append(result.generation, isFinal: isFinal)
        }
        await waitUntil { (await gate.entered()).count == 2 }
        await gate.release(2)
        await Task.yield()
        XCTAssertEqual(deliveries.generations, [1], "a completion older than the delivery watermark must be ignored")
    }

    func testFinalDeliveryEvictsStateAndEvictionCancelsActiveAndPending() async {
        let store = HotTableRasterizerStore()
        let gate = RenderGate()
        let key = BlockKey(itemID: "message", index: 2)
        let deliveries = DeliveryLog()
        let resultImage = image()
        let renderer: HotTableRasterizerStore.Renderer = { snapshot in
            await gate.wait(snapshot.generation)
            return HotTableRenderResult(key: snapshot.key, generation: snapshot.generation, image: resultImage, size: .init(width: 1, height: 1))
        }
        let delivery: HotTableRasterizerStore.Delivery = { result, isFinal in
            deliveries.append(result.generation, isFinal: isFinal)
        }

        store.submit(snapshot("final", key: key, isFinal: true), renderer: renderer, onDelivery: delivery)
        await waitUntil { (await gate.entered()).count == 1 }
        await gate.release(1)
        await waitUntil { deliveries.finalFlags == [true] }

        let resetGate = RenderGate()
        let resetRenderer: HotTableRasterizerStore.Renderer = { snapshot in
            await resetGate.wait(snapshot.generation)
            return HotTableRenderResult(key: snapshot.key, generation: snapshot.generation, image: resultImage, size: .init(width: 1, height: 1))
        }
        store.submit(snapshot("after final", key: key), renderer: resetRenderer, onDelivery: delivery)
        await waitUntil { (await resetGate.entered()).count == 1 }
        let enteredAfterReset = await resetGate.entered()
        XCTAssertEqual(enteredAfterReset, [1], "final delivery must remove keyed state and reset generations")
        store.evict([key])
        await waitUntil { !(await resetGate.cancelled()).isEmpty }

        await resetGate.release(1)
        let enteredAfterEviction = await resetGate.entered()
        XCTAssertEqual(enteredAfterEviction, [1], "eviction must release the active request without starting retained pending work")
    }

    private final class DeliveryLog: @unchecked Sendable {
        var generations: [Int] = []
        var finalFlags: [Bool] = []

        func append(_ generation: Int, isFinal: Bool) {
            generations.append(generation)
            finalFlags.append(isFinal)
        }
    }
}
#endif

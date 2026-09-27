// StreamingDeliveryCoordinatorTests.swift

#if canImport(UIKit)
import XCTest
@testable import VelocityUI

@MainActor
final class StreamingDeliveryCoordinatorTests: XCTestCase {
    private func makeEnvironment(
        streamingDeliveryCoordinator: StreamingDeliveryCoordinator
    ) -> RenderEnvironment {
        let dc = DimensionCache()
        let videoPrep = VideoPreparationActor()
        return RenderEnvironment(
            textPool: .init(), layoutCache: .init(), dimensionCache: dc,
            imageActor: ImageActor(dimensionCache: dc), gifActor: .init(),
            videoController: VideoController(videoPreparation: videoPrep, maxAttached: 1),
            videoPreparation: videoPrep, frozenBitmapStore: .init(),
            hotBlockRasterizerStore: .init(), hotCodeStreamStore: .init(),
            hotTableRasterizerStore: .init(),
            streamingDeliveryCoordinator: streamingDeliveryCoordinator
        )
    }

    /// No static/shared instance: two environments built with distinct coordinators via the
    /// designated init must not observe each other's revisions.
    func testDesignatedInitInjectsDistinctInstances() {
        let coordinatorA = StreamingDeliveryCoordinator()
        let coordinatorB = StreamingDeliveryCoordinator()
        let envA = makeEnvironment(streamingDeliveryCoordinator: coordinatorA)
        let envB = makeEnvironment(streamingDeliveryCoordinator: coordinatorB)

        XCTAssertTrue(envA.streamingDeliveryCoordinator === coordinatorA)
        XCTAssertTrue(envB.streamingDeliveryCoordinator === coordinatorB)
        XCTAssertFalse(envA.streamingDeliveryCoordinator === envB.streamingDeliveryCoordinator)
    }

    /// The @MainActor convenience init's default (`.init()`) reaches a real, usable coordinator.
    func testConvenienceInitDefaultsToUsableCoordinator() {
        let env = RenderEnvironment()
        env.streamingDeliveryCoordinator.noteDocumentRevision(itemID: "msg-1", revision: 1)
        env.streamingDeliveryCoordinator.noteDocumentRevision(itemID: "msg-1", revision: 2)
    }

    /// Lifetime matches RenderEnvironment: once the environment is released with no other strong
    /// references, its coordinator deinits too.
    func testCoordinatorDeinitsWithEnvironment() {
        weak var weakCoordinator: StreamingDeliveryCoordinator?
        autoreleasepool {
            var env: RenderEnvironment? = makeEnvironment(
                streamingDeliveryCoordinator: StreamingDeliveryCoordinator()
            )
            weakCoordinator = env?.streamingDeliveryCoordinator
            XCTAssertNotNil(weakCoordinator)
            env = nil
        }
        XCTAssertNil(weakCoordinator)
    }
}
#endif

// RetainedDocumentNode.swift

import CoreGraphics

/// Stands in for a `StreamingMarkdownController`'s whole document as a single `RenderNode` —
/// return it from an ordinary `RenderView.renderBody` in place of
/// `VStackNode { controller.renderNodes }`. `flatten()`'s general path expands it to the full
/// block list like any container node; `FeedScrollView` additionally recognizes this exact type
/// and, when `revision` only grew by an append, splices in `changedSuffix(since:)`'s result
/// instead of re-flattening and re-diffing every block.
public struct RetainedDocumentNode: RenderNode {
    let documentID: ObjectIdentifier
    let revision: UInt64
    let alignment: VHorizontalAlignment
    let spacing: CGFloat
    private let box: ControllerBox

    init(
        documentID: ObjectIdentifier, revision: UInt64,
        alignment: VHorizontalAlignment, spacing: CGFloat,
        controller: StreamingMarkdownController
    ) {
        self.documentID = documentID
        self.revision = revision
        self.alignment = alignment
        self.spacing = spacing
        self.box = ControllerBox(controller)
    }

    /// Revision alone stands in for content hashing — sealed blocks never change once sealed, so
    /// a higher revision is proof enough that something may have changed, without walking blocks.
    public var layoutHash: Int {
        var h = Hasher()
        h.combine(documentID)
        h.combine(revision)
        h.combine(alignment)
        h.combine(spacing)
        return h.finalize()
    }

    public var appearanceHash: Int { layoutHash }

    /// `flatten()`'s general path only — expands every block, sealed and hot alike.
    @MainActor
    func fullBlocks() -> [any RenderNode] { box.controller.renderNodes }

    /// `FeedScrollView`'s fast path only. `nil` asks the caller to fall back to `fullBlocks()`.
    @MainActor
    func changedSuffix(since revision: UInt64?) -> (startBlock: Int, blocks: [any RenderNode])? {
        box.controller.changedSuffix(since: revision)
    }

    /// Single-owner-per-message wrapper around the deliberately non-Sendable `@MainActor`
    /// controller (same pooled/single-owner shape as `TextMeasurementContext`). Every access to
    /// `controller` happens on `@MainActor`, through `flatten()` or `FeedScrollView`, both
    /// `@MainActor`-bound, so this is never read from another isolation domain.
    private final class ControllerBox: @unchecked Sendable {
        let controller: StreamingMarkdownController
        init(_ controller: StreamingMarkdownController) { self.controller = controller }
    }
}

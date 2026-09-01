// MarkdownTableNode.swift

import Foundation

/// A grouped GFM table: header row + zero or more body rows, one column alignment per column.
///
/// Unlike `CodeBlockNode`, this isn't meant for direct developer authoring — its raw model
/// (`TableCell`) is the parser's internal cell type, produced only by grouping consecutive
/// `tableRow` blocks (see `IncrementalMarkdownParser`'s `.table(alignments:)` case). Internal
/// on purpose; stays fully visible to tests via `@testable import VelocityUI`, same as
/// `CodeBlockChrome`/`CodeBlockRole`.
///
/// `flatten()` preserves this as one direct table leaf, mirroring `CodeBlockNode` — no nested
/// container, no expanded per-cell children at this layer. Column-width solving, cell layout,
/// and rasterization (VelocityUI-8ge8.2–.4) run downstream of `descriptor`.
struct MarkdownTableNode: RenderNode {
    /// Row 0 is the header row, `[1...]` are body rows — `ParsedMDBlock.tableRows`' convention.
    let tableRows: [[TableCell]]
    let alignments: [TableColumnAlignment]
    let font: VFontDescriptor
    let color: VColorDescriptor
    let blockID: BlockID?
    let blockLifecycle: BlockLifecycle

    init(
        tableRows: [[TableCell]],
        alignments: [TableColumnAlignment],
        font: VFontDescriptor = .body,
        color: VColorDescriptor = .primary,
        blockID: BlockID? = nil,
        blockLifecycle: BlockLifecycle = .positional
    ) {
        self.tableRows = tableRows
        self.alignments = alignments
        self.font = font
        self.color = color
        self.blockID = blockID
        self.blockLifecycle = blockLifecycle
    }

    /// Covers every cell's raw text plus the font metrics that affect wrapping/measurement —
    /// the same content-and-font split `CodeBlockNode.layoutHash` uses. Per-cell inline runs
    /// (bold/italic spans) are appearance-only ink, not geometry, so they're excluded here.
    var layoutHash: Int {
        var h = Hasher()
        for row in tableRows {
            for cell in row { h.combine(cell.text) }
        }
        h.combine(font.size)
        h.combine(font.weight)
        h.combine(font.family)
        h.combine(font.traits)
        return h.finalize()
    }

    /// Covers column alignment and text color — the paint-only dimensions this node carries
    /// before rasterization introduces grid/background chrome.
    var appearanceHash: Int {
        var h = Hasher()
        h.combine(alignments)
        h.combine(color)
        return h.finalize()
    }

    var descriptor: MarkdownTableDescriptor {
        let cells = makeTableCellDescriptors(tableRows: tableRows, font: font, color: color)
        return MarkdownTableDescriptor(
            cells: cells,
            alignments: alignments,
            blockID: blockID,
            lifecycle: blockLifecycle,
            layoutHash: layoutHash,
            appearanceHash: appearanceHash
        )
    }
}

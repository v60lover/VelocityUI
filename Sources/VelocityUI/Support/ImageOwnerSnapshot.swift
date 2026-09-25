// ImageOwnerSnapshot.swift

import CoreGraphics
import Foundation

/// One image reference held by a named owner. `id` is the `CGImage` object identity.
public struct ImageRef: Sendable, Hashable {
    public let id: ObjectIdentifier
    public let bytes: Int

    public init(_ image: CGImage) {
        id = ObjectIdentifier(image)
        bytes = image.bytesPerRow * image.height
    }
}

/// Debug-only view of the images one owner (store, cache, mounted layers) holds right now.
public struct ImageOwnerSnapshot: Sendable {
    public let owner: String
    public let refs: [ImageRef]

    public init(owner: String, images: [CGImage]) {
        self.owner = owner
        self.refs = images.map(ImageRef.init)
    }
}

/// Per-owner bytes plus a deduped total. An image shared by two owners counts once in
/// `uniqueBytes` (charged to the first owner listed) but stays visible in each owner's row.
public struct ImageOwnershipReport: Sendable {
    public struct Row: Sendable {
        public let owner: String
        public let refCount: Int
        public let heldBytes: Int
        public let uniqueBytes: Int
    }

    public let rows: [Row]
    public let uniqueImageCount: Int
    public let uniqueBytes: Int

    public init(_ snapshots: [ImageOwnerSnapshot]) {
        var seen = Set<ObjectIdentifier>()
        var rows: [Row] = []
        for snap in snapshots {
            var unique = 0
            for ref in snap.refs where seen.insert(ref.id).inserted { unique += ref.bytes }
            rows.append(Row(
                owner: snap.owner, refCount: snap.refs.count,
                heldBytes: snap.refs.reduce(0) { $0 + $1.bytes }, uniqueBytes: unique
            ))
        }
        self.rows = rows
        uniqueImageCount = seen.count
        uniqueBytes = rows.reduce(0) { $0 + $1.uniqueBytes }
    }

    public var summaryLine: String {
        let parts = rows.map {
            "\($0.owner)=held \($0.heldBytes / 1024)KB/new \($0.uniqueBytes / 1024)KB/\($0.refCount)refs"
        }
        return "images unique=\(uniqueImageCount) bytes=\(uniqueBytes / 1024)KB " + parts.joined(separator: " ")
    }
}

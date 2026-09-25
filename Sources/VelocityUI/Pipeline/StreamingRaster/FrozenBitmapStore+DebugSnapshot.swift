// FrozenBitmapStore+DebugSnapshot.swift

import CoreGraphics

extension FrozenBitmapStore {
    public func debugImageSnapshot() -> ImageOwnerSnapshot {
        ImageOwnerSnapshot(owner: "frozen", images: state.withLock { $0.entries.values.map(\.bitmap) })
    }
}

extension VisibleBlockStore {
    public func debugImageSnapshot() -> ImageOwnerSnapshot {
        ImageOwnerSnapshot(owner: "visible", images: state.withLock { $0.entries.values.map(\.bitmap) })
    }
}

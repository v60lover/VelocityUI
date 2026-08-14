// DescriptorTestFactories.swift

import CoreGraphics
@testable import VelocityUI

/// Explicit sentinel-zero factories for hand-built test fixtures that don't care about
/// stack-descriptor hash values. Production code (flatten()) never calls these — it always
/// supplies real hashes via the descriptors' designated init. Grep for `.test(` to find every
/// call site that intentionally opted into hash=0.
extension VStackDescriptor {
    static func test(alignment: Int = 0, spacing: CGFloat = 0) -> Self {
        .init(alignment: alignment, spacing: spacing, layoutHash: 0, appearanceHash: 0)
    }
}

extension HStackDescriptor {
    static func test(alignment: Int = 0, spacing: CGFloat = 0) -> Self {
        .init(alignment: alignment, spacing: spacing, layoutHash: 0, appearanceHash: 0)
    }
}

extension ZStackDescriptor {
    static func test(alignment: Int = 0) -> Self {
        .init(alignment: alignment, layoutHash: 0, appearanceHash: 0)
    }
}

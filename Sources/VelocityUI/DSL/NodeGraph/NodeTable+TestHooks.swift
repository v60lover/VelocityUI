// NodeTable+TestHooks.swift

extension NodeTable {
    // No-singletons exemption: test-only instrumentation. Injecting this through the nonisolated
    // pure helpers would violate their "no implicit cache lookup" contract; static placement is
    // the lesser violation.
    //
    // Counts every .itemID read. RenderDiffer.diff reads it 4x per surviving item — a regression
    // that rebuilds an [AnyHashable: _] dict for height-forwarding raises the count to 6×N.
    //
    // NOT thread-safe: assumes serial access, no concurrent Task reading .itemID during measurement.
    nonisolated(unsafe) static var _itemIDCounter: Int = 0
}

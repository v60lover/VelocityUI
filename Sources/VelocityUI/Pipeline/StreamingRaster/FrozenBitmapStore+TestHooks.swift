// FrozenBitmapStore+TestHooks.swift

#if canImport(XCTest)
extension FrozenBitmapStore {
    /// Test-only check that the linked list is internally consistent with `entries`
    /// and `currentByteTotal`.
    func debugValidateListInvariants() -> Bool {
        state.withLock { st in
            var walked: Set<BlockKey> = []
            var summedCost = 0
            var previous: FrozenBitmapStore.Node?
            var current = st.head
            while let node = current {
                guard node.prev === previous else { return false }
                walked.insert(node.key)
                summedCost += node.cost
                previous = node
                current = node.next
            }
            guard previous === st.tail else { return false }
            guard summedCost == st.currentByteTotal else { return false }
            guard walked == Set(st.entries.keys) else { return false }
            guard walked.count == st.entries.count else { return false }
            return true
        }
    }
}
#endif

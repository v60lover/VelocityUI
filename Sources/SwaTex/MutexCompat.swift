// MutexCompat.swift

import Foundation

/// Drop-in stand-in for `Synchronization.Mutex` (iOS 18+) so this package
/// can target iOS 17 / macOS 13. Same `init(_:)` / `withLock` shape, backed
/// by `NSLock` instead of the OS-level lock primitive the real `Mutex` uses.
public final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ initialValue: Value) {
        self.value = initialValue
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

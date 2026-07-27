// DecodeScratchBufferPool.swift

#if canImport(UIKit)
import Foundation
import os

/// Bounded pool of reusable raw buffers backing `normaliseAndRound`'s CGContext draw surface.
///
/// Sized to match the max concurrent callers (`ImageActor.decodeSemaphore`'s value) so a
/// checkout never blocks. Buffers grow (never shrink) to the largest request seen; a smaller
/// subsequent request reuses without reallocating. Turns "malloc a full bitmap every decode"
/// into "reuse one of N," removing the transient CGContext-owned scratch allocation — half of
/// every decode's footprint spike per VelocityUI-zgs — from the per-frame allocation profile.
///
/// A pooled buffer never backs the CGImage `normaliseAndRound` returns — see that function's
/// docstring for why the rendered bytes are copied out before returning.
final class DecodeScratchBufferPool: @unchecked Sendable {
    // @unchecked: UnsafeMutableRawPointer itself isn't Sendable-checked by the compiler.
    // Safety comes from OSAllocatedUnfairLock — a Buffer is only ever touched while the
    // lock's critical section holds it, so there's no concurrent access to the raw memory.
    private struct Buffer: @unchecked Sendable {
        var pointer: UnsafeMutableRawPointer
        var capacity: Int
    }

    private let lock: OSAllocatedUnfairLock<[Buffer]>

    /// - Parameter capacity: number of buffers to keep. Must match the max concurrent callers
    ///   so `withBuffer` never blocks waiting for a slot.
    init(capacity: Int) {
        let initial = (0..<max(1, capacity)).map { _ in
            Buffer(pointer: UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 16), capacity: 1)
        }
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    deinit {
        lock.withLock { buffers in
            for buffer in buffers { buffer.pointer.deallocate() }
        }
    }

    /// Checks out a buffer with at least `byteCount` capacity, runs `body` with it, and
    /// returns the buffer to the pool before returning `body`'s result.
    func withBuffer<T>(byteCount: Int, _ body: (UnsafeMutableRawPointer) -> T) -> T {
        var buffer = lock.withLock { buffers in buffers.removeLast() }

        if buffer.capacity < byteCount {
            buffer.pointer.deallocate()
            buffer.pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            buffer.capacity = byteCount
        }

        let result = body(buffer.pointer)

        let checkedOut = buffer
        lock.withLock { buffers in buffers.append(checkedOut) }
        return result
    }
}
#endif

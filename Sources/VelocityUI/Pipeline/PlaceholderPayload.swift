// PlaceholderPayload.swift

import Foundation

/// The data handed to a `PlaceholderRenderer` for one image fragment's first paint.
///
/// `.thumbnail`/`.blurHash` are built-in, decoded by `DefaultPlaceholderRenderer`. `.custom`
/// is the open door for a consumer's own first-paint strategy (dominant color, ThumbHash, a
/// pre-decoded low-res `CGImage`, skeleton art) — set via `AsyncImageNode.placeholder(custom:)`
/// and interpreted only by a renderer injected through `RenderEnvironment`.
public enum PlaceholderPayload: Sendable, Hashable {
    case thumbnail(Data)
    case blurHash(String)
    case custom(AnyPlaceholderPayload)
}

/// Type-erased box carrying a consumer-defined placeholder payload through `NodeTable`
/// (which must stay generic-free — see the "no existentials past Layer 1" architecture
/// invariant) while still folding into `AsyncImageNode.appearanceHash` so changing the
/// payload triggers a repaint.
///
/// Equality and hashing bridge through `AnyHashable`, which already knows how to compare
/// two `any Hashable` values of possibly-different concrete types without crashing.
public struct AnyPlaceholderPayload: Sendable, Hashable {
    private let value: any Hashable & Sendable

    public init<T: Hashable & Sendable>(_ value: T) {
        self.value = value
    }

    /// Recovers the concrete payload a custom `PlaceholderRenderer` expects to receive.
    /// Returns `nil` if `T` doesn't match the type this box was constructed with.
    public func unwrap<T: Hashable & Sendable>(as type: T.Type = T.self) -> T? {
        value as? T
    }

    public static func == (lhs: AnyPlaceholderPayload, rhs: AnyPlaceholderPayload) -> Bool {
        AnyHashable(lhs.value) == AnyHashable(rhs.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(AnyHashable(value))
    }
}

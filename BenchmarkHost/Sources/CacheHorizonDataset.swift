// CacheHorizonDataset.swift

import Foundation
import VelocityUI

/// One transcript entry for the cache-horizon scenario. Content is derived from `id` and `kind`
/// only, so every run builds byte-identical items.
struct HorizonItem: Identifiable, Sendable, Equatable {
    enum Kind: Int, CaseIterable, Sendable {
        case plainText, markdown, code, table, math, image
    }

    let id: Int
    let kind: Kind
}

/// Deterministic mixed transcript sized to cross every cache limit: more items than `LayoutCache`
/// holds, more sealed rasters than `FrozenBitmapStore` budgets, more distinct images than
/// `ImageActor`'s 64 MB cache holds.
enum CacheHorizonDataset {
    static let defaultItemCount = 2_400

    static func items(count: Int = defaultItemCount) -> [HorizonItem] {
        (0..<count).map { HorizonItem(id: $0, kind: kind(forItem: $0)) }
    }

    /// Fixed cycle: mostly text, with a code/table/math/image every few items.
    static func kind(forItem id: Int) -> HorizonItem.Kind {
        switch id % 12 {
        case 0, 3, 7: return .plainText
        case 1, 5, 9: return .markdown
        case 2, 10: return .code
        case 4: return .table
        case 6: return .math
        case 8, 11: return .image
        default: return .plainText
        }
    }

    /// Unique per id so `LayoutCache` (keyed by content hash) cannot share entries between items.
    static func markdown(for item: HorizonItem) -> String {
        let n = item.id
        switch item.kind {
        case .plainText:
            return "Message \(n): the quick brown fox jumps over the lazy dog, then reads a longer line so this wraps onto a second line at phone width (\(n * 7919 % 1009))."
        case .markdown:
            return "## Section \(n)\n\nSome **bold** and `inline` text for item \(n).\n\n- first point \(n)\n- second point \(n * 3)\n- third point \(n * 5)"
        case .code:
            return "```swift\nfunc item\(n)(_ x: Int) -> Int {\n    let y = x * \(n)\n    return y + \(n % 97)\n}\n```"
        case .table:
            return "| Key | Value |\n| :-- | :-- |\n| id | \(n) |\n| square | \(n * n) |\n| mod | \(n % 13) |"
        case .math:
            return "$$ x_{\(n)} = \\frac{\(n) + 1}{2} $$"
        case .image:
            return "Photo \(n)"
        }
    }

    /// Distinct URL per image item (the `sig` query is ignored by the CDN) so each is its own cache key.
    static func imageURL(for item: HorizonItem) -> URL {
        let photo = BenchmarkPhotoIDs.table[item.id % BenchmarkPhotoIDs.table.count]
        return URL(string: "https://images.unsplash.com/photo-\(photo)?w=800&h=450&fit=crop&q=80&sig=\(item.id)")!
    }
}

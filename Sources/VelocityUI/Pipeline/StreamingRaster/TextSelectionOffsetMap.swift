// TextSelectionOffsetMap.swift

import Foundation

/// Maps UTF-16 offsets in the TextKit string back to `TextDescriptor.content`. They differ
/// once an inline formula is typeset: N content units become one attachment character.
struct TextSelectionOffsetMap: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let kitStart: Int
        let kitLength: Int
        let contentStart: Int
        let contentLength: Int
        let isMath: Bool
    }

    private(set) var segments: [Segment] = []

    mutating func append(kitLength: Int, contentStart: Int, contentLength: Int, isMath: Bool) {
        let kitStart = segments.last.map { $0.kitStart + $0.kitLength } ?? 0
        segments.append(Segment(
            kitStart: kitStart, kitLength: kitLength,
            contentStart: contentStart, contentLength: contentLength, isMath: isMath
        ))
    }

    /// Raw text for `kitRange`. A formula in range copies as `$source$`; plain runs map 1:1.
    func copiedText(kitRange: NSRange, content: String) -> String {
        let ns = content as NSString
        var out = ""
        for seg in segments {
            let lo = max(kitRange.location, seg.kitStart)
            let hi = min(NSMaxRange(kitRange), seg.kitStart + seg.kitLength)
            guard lo < hi else { continue }
            if seg.isMath {
                out += "$" + ns.substring(with: NSRange(location: seg.contentStart, length: seg.contentLength)) + "$"
            } else {
                let start = seg.contentStart + (lo - seg.kitStart)
                out += ns.substring(with: NSRange(location: start, length: hi - lo))
            }
        }
        return out
    }
}

// TextNode+MessageRole.swift

import CoreGraphics

/// Developer-facing role for a chat message's text row. Picks between the asymmetric user-bubble
/// look and today's default full-width look via a single `.messageRole(_:)` call.
public enum MessageRole: Sendable, Hashable {
    case user
    case assistant
}

extension VColorDescriptor {
    /// Default fill for a `.messageRole(.user)` bubble background.
    public static let messageBubbleBackground = VColorDescriptor(red: 0.85, green: 0.91, blue: 1.0, alpha: 1)
}

extension TextNode {
    /// Stamps this row's alignment/maxWidthFraction/background fields (from `VelocityUI-8otc.1`
    /// and `.3`) for a chat message. No new layout or render path — measure/place (`.2`) and the
    /// background fragment (`.3`) already consume these fields.
    ///
    /// `.user` — right-aligned bubble, ~0.8 of the column width, rounded background.
    /// `.assistant` — full width, no background; identical to `TextNode`'s own defaults, so
    /// omitting this modifier is equivalent to calling `.messageRole(.assistant)`.
    ///
    /// Preserves every other field (unlike `.font()`/`.lineLimit()`/etc., which silently drop
    /// alignment/maxWidthFraction/backgroundChrome — see `VelocityUI-8rin`), matching
    /// `.roundedBackground(cornerRadius:color:)`'s field-preserving pattern.
    public func messageRole(_ role: MessageRole) -> TextNode {
        let alignment: VHorizontalAlignment
        let maxWidthFraction: Double
        let backgroundChrome: TextBackgroundChrome?
        switch role {
        case .user:
            alignment = .trailing
            maxWidthFraction = 0.8
            backgroundChrome = TextBackgroundChrome(cornerRadius: 12, color: .messageBubbleBackground)
        case .assistant:
            alignment = .leading
            maxWidthFraction = 1.0
            backgroundChrome = nil
        }
        return TextNode(
            content, font: font, color: color, lineLimit: lineLimit, lineBreakMode: lineBreakMode,
            underlineStyle: underlineStyle, strikethroughStyle: strikethroughStyle,
            kerning: kerning, lineSpacing: lineSpacing, runs: runs,
            leadingBarColor: leadingBarColor, leadingBarWidth: leadingBarWidth, leadingBarGap: leadingBarGap,
            ruleColor: ruleColor, alignment: alignment, maxWidthFraction: maxWidthFraction,
            blockID: blockID, blockLifecycle: blockLifecycle, codeBlockRole: codeBlockRole,
            backgroundChrome: backgroundChrome
        )
    }
}

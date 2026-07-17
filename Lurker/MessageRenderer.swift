// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import LurkerKit
import UIKit

/// Turns a `Message` into styled text, mirroring the web client: a colored nick prefix
/// (per-type), then the body with mIRC formatting, colors, and auto-linked URLs. One font
/// size throughout — hierarchy comes from weight, italics, and color, never size.
///
/// Two entry points, because a message renders one of two ways:
///  - `renderBubble` — just the body. `BubbleCell` draws the nick and time itself, once
///    per run, so they must not also be baked into the text.
///  - `render` — the whole line, prefix included, for the events that stay full-width
///    (actions, notices, and the system buffer).
enum MessageRenderer {

    // MARK: - Bubbles

    /// The body alone, for a bubble. On our own tinted bubble the default `.label` would
    /// be near-black on blue, so the fallback flips to white — but an mIRC-colored run
    /// still wins, because the sender chose that color on purpose.
    static func renderBubble(_ message: Message) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        return body(message, base: base, fallback: message.isSelf ? .white : .label)
    }

    // MARK: - Full-width lines

    /// A complete line: timestamp, prefix, body. `networkName` labels a system line with
    /// the network it's about, and is ignored for every other type.
    static func render(_ message: Message, networkName: String? = nil) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        let nick = message.nick ?? "*"
        let line = NSMutableAttributedString()

        if let stamp = timestamp(message.date) {
            line.append(NSAttributedString(
                string: stamp + "  ", attributes: [.font: base, .foregroundColor: UIColor.tertiaryLabel]
            ))
        }

        switch message.type {
        case .system:
            // The system buffer is app-scoped, so a line names the network it's about (or
            // "System" when it's about the app itself) where a channel line would name a
            // nick. Severity rides `level`, never the type.
            line.append(NSAttributedString(
                string: (networkName ?? "System") + "  ",
                attributes: [.font: base.bold, .foregroundColor: color(for: message.level ?? .info)]
            ))
            line.append(body(message, base: base, fallback: color(for: message.level ?? .info)))
        case .action:
            // "* " muted marker, then the actor's nick + body, italicized.
            line.append(NSAttributedString(string: "* ", attributes: [.font: base, .foregroundColor: UIColor.secondaryLabel]))
            line.append(NSAttributedString(
                string: nick + " ", attributes: [.font: base.italic, .foregroundColor: nickColor(message)]
            ))
            line.append(body(message, base: base.italic, fallback: .label))
        case .notice:
            line.append(NSAttributedString(
                string: "-\(nick)- ", attributes: [.font: base.bold, .foregroundColor: nickColor(message)]
            ))
            line.append(body(message, base: base, fallback: .label))
        default:
            line.append(NSAttributedString(string: nick, attributes: [.font: base.bold, .foregroundColor: nickColor(message)]))
            line.append(NSAttributedString(string: "  ", attributes: [.font: base]))
            line.append(body(message, base: base, fallback: .label))
        }
        return line
    }

    // MARK: - Body

    private static func body(_ message: Message, base: UIFont, fallback: UIColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for run in IRCFormatting.parse(message.text ?? "") {
            // Always set an explicit color: unlike a label, a UITextView's attributed runs
            // without a foreground color fall back to a static black, not the dynamic
            // `.label`, so uncolored text would be unreadable in dark mode.
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(base, bold: run.bold, italic: run.italic),
                .foregroundColor: run.fg.flatMap(mircColor) ?? fallback,
            ]
            if let bg = run.bg, let color = mircColor(bg) { attributes[.backgroundColor] = color }
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributed.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        // Auto-link URLs over the assembled plain text (control codes already stripped).
        // The cell's `linkTextAttributes` colors + underlines them; here we only mark them.
        for match in URLMatcher.matches(in: attributed.string) {
            guard let url = URL(string: match.href) else { continue }
            attributed.addAttribute(.link, value: url, range: match.range)
        }
        return attributed
    }

    // MARK: - Timestamps

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short // locale-aware 12/24h, shown in local time
        return formatter
    }()

    /// A short local time (nil if the event had no readable one). Parsing already happened
    /// at the wire boundary (`ISOTime`), so this only formats.
    static func timestamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        return timeFormatter.string(from: date)
    }

    // MARK: - Colors

    /// A system line's severity color, matching the web client's indicator palette. Info
    /// stays muted: most of the system buffer is routine, and coloring all of it would
    /// leave nothing for the lines that matter.
    private static func color(for level: SystemLevel) -> UIColor {
        switch level {
        case .info: .secondaryLabel
        case .warn: Palette.warn
        case .error: Palette.bad
        }
    }

    static func nickColor(_ message: Message) -> UIColor {
        if message.isSelf { return .tintColor }
        let hex = IRCPalette.nick[NickColor.index(for: message.nick ?? "")]
        return UIColor(hex: hex) ?? .secondaryLabel
    }

    /// mIRC index → color. The theme slots (0/1/14/15) map to system colors; 16+ don't
    /// render.
    private nonisolated static func mircColor(_ index: Int) -> UIColor? {
        guard index >= 0, index < IRCPalette.mirc.count else { return nil }
        if let hex = IRCPalette.mirc[index] { return UIColor(hex: hex) }
        switch index {
        case 0: return .label
        case 1: return .systemBackground
        case 14: return .secondaryLabel
        case 15: return .tertiaryLabel
        default: return nil
        }
    }

    private static func font(_ base: UIFont, bold: Bool, italic: Bool) -> UIFont {
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

extension UIFont {
    var bold: UIFont { withTrait(.traitBold) }
    var italic: UIFont { withTrait(.traitItalic) }

    /// One weight step up, for the nick above a bubble and the pill's title. `size: 0`
    /// keeps the descriptor's own size, so a text style's Dynamic Type scaling survives.
    var semibold: UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold],
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }

    func withTrait(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

extension UIColor {
    /// `#rrggbb` → color, or nil if malformed.
    nonisolated convenience init?(hex: String) {
        var string = hex
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

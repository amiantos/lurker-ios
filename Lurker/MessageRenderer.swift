// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Turns a `Message` into a styled line, mirroring the web client: a colored nick prefix
/// (per-type), then the body with mIRC formatting, colors, and auto-linked URLs. One font
/// size throughout — hierarchy comes from weight, italics, and color, never size.
enum MessageRenderer {

    static func render(_ message: Message) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        let nick = message.nick ?? "*"
        let line = NSMutableAttributedString()

        if let stamp = timestamp(message.time) {
            line.append(NSAttributedString(
                string: stamp + "  ", attributes: [.font: base, .foregroundColor: UIColor.tertiaryLabel]
            ))
        }

        switch message.type {
        case .action:
            // "* " muted marker, then the actor's nick + body, italicized.
            line.append(NSAttributedString(string: "* ", attributes: [.font: base, .foregroundColor: UIColor.secondaryLabel]))
            line.append(NSAttributedString(
                string: nick + " ", attributes: [.font: base.italic, .foregroundColor: nickColor(message)]
            ))
            line.append(body(message, base: base.italic))
        case .notice:
            line.append(NSAttributedString(
                string: "-\(nick)- ", attributes: [.font: base.bold, .foregroundColor: nickColor(message)]
            ))
            line.append(body(message, base: base))
        default:
            line.append(NSAttributedString(string: nick, attributes: [.font: base.bold, .foregroundColor: nickColor(message)]))
            line.append(NSAttributedString(string: "  ", attributes: [.font: base]))
            line.append(body(message, base: base))
        }
        return line
    }

    // MARK: - Body

    private static func body(_ message: Message, base: UIFont) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for run in IRCFormatting.parse(message.text ?? "") {
            var attributes: [NSAttributedString.Key: Any] = [.font: font(base, bold: run.bold, italic: run.italic)]
            if let fg = run.fg, let color = mircColor(fg) { attributes[.foregroundColor] = color }
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

    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoParserPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short // locale-aware 12/24h, shown in local time
        return formatter
    }()

    /// The server's ISO time → a short local time (nil if absent/unparseable).
    private static func timestamp(_ iso: String?) -> String? {
        guard let iso else { return nil }
        guard let date = isoParser.date(from: iso) ?? isoParserPlain.date(from: iso) else { return nil }
        return timeFormatter.string(from: date)
    }

    // MARK: - Colors

    private static func nickColor(_ message: Message) -> UIColor {
        if message.isSelf { return .tintColor }
        let hex = IRCPalette.nick[NickColor.index(for: message.nick ?? "")]
        return UIColor(hex: hex) ?? .secondaryLabel
    }

    /// mIRC index → color. The theme slots (0/1/14/15) map to system colors; 16+ don't
    /// render.
    private static func mircColor(_ index: Int) -> UIColor? {
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

private extension UIFont {
    var bold: UIFont { withTrait(.traitBold) }
    var italic: UIFont { withTrait(.traitItalic) }
    func withTrait(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

extension UIColor {
    /// `#rrggbb` → color, or nil if malformed.
    convenience init?(hex: String) {
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

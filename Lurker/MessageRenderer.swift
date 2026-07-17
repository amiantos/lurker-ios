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
    /// One text color inside every bubble, whatever the line is. A bubble already says
    /// what kind of line it is — by its caption, and by that caption's color — so tinting
    /// the words too said it twice and left server text reading as permanently dimmed.
    /// Severity still shows: it rides the caption, where `captionColor` puts it.
    static func renderBubble(_ message: Message) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        // Server text stays monospaced inside its bubble: it's still terminal output, and
        // the alignment is half of what it's saying.
        let font = message.type == .motd ? mono(base) : base
        return body(message, base: font, fallback: message.isSelf ? .white : .label)
    }

    /// What captions a bubble's run. Nil leaves it uncaptioned.
    static func caption(_ message: Message, networkName: String?) -> String? {
        switch message.type {
        // IRC's own mark for a notice, in the place that names the speaker — the only
        // thing separating "NickServ said this" from "NickServ noticed this".
        case .notice: "-\(message.nick ?? "")-"
        // App-scoped, so it names the network it's *about* rather than a nick.
        case .system: networkName ?? "System"
        // Raw server text has no author but the server itself.
        case .motd, .other: networkName
        default: message.nick
        }
    }

    /// The caption's color, which is not always a nick color — a system line's says how
    /// bad it is, and server text isn't anyone.
    static func captionColor(_ message: Message) -> UIColor {
        switch message.type {
        case .system: color(for: message.level ?? .info)
        case .motd, .other: .secondaryLabel
        default: nickColor(message)
        }
    }

    // MARK: - Blocks

    /// The same point size as everything else, in a monospaced face. A family change, not a
    /// second type scale.
    private static func mono(_ base: UIFont) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
    }

    // MARK: - Full-width lines

    /// A complete line: prefix, then body. `networkName` labels a system line with the
    /// network it's about, and is ignored for every other type.
    ///
    /// No timestamp. It used to be stamped inline down the left because a full-width line
    /// can't slide aside the way a bubble does — but that put a column of identical times
    /// beside every line of a MOTD to say one thing, and made the times the first thing
    /// you read on every row. `LineCell` reserves a trailing gutter instead, and the time
    /// slides into that on a drag like everywhere else.
    static func render(_ message: Message, networkName: String? = nil) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        let nick = message.nick ?? "*"
        // Built as two halves rather than appended in one run, so the indent below can
        // measure the prefix exactly instead of trying to find where it ended by scanning
        // the assembled string — the separators differ per type, and a MOTD body can
        // contain the same run of spaces a prefix ends with.
        let prefixText = NSMutableAttributedString()
        let bodyText: NSAttributedString
        let line = NSMutableAttributedString()

        switch message.type {
        case .system:
            // The system buffer is app-scoped, so a line names the network it's about (or
            // "System" when it's about the app itself) where a channel line would name a
            // nick. Severity rides `level`, never the type.
            prefixText.append(NSAttributedString(
                string: (networkName ?? "System") + "  ",
                attributes: [.font: base.bold, .foregroundColor: color(for: message.level ?? .info)]
            ))
            bodyText = body(message, base: base, fallback: color(for: message.level ?? .info))
        case .action:
            // An asterisk marker, then the actor's nick and what they did — the whole line
            // in their color, italic. Actions are content, not metadata: alice *did* this,
            // so it's tinted like she said it rather than muted like a join. The tint is
            // what separates it from a bubble at a glance.
            let color = nickColor(message)
            prefixText.append(asterisk(color: color, base: base))
            prefixText.append(NSAttributedString(
                string: " " + nick + " ", attributes: [.font: base.italic, .foregroundColor: color]
            ))
            bodyText = body(message, base: base.italic, fallback: color)
        case .notice:
            prefixText.append(NSAttributedString(
                string: "-\(nick)- ", attributes: [.font: base.bold, .foregroundColor: nickColor(message)]
            ))
            bodyText = body(message, base: base, fallback: .label)
        default:
            if let prefix = prefix(message) {
                prefixText.append(NSAttributedString(
                    string: prefix.text, attributes: [.font: base.bold, .foregroundColor: prefix.color]
                ))
                prefixText.append(NSAttributedString(string: "  ", attributes: [.font: base]))
            }
            // Everything down here except a plain message is *about* the conversation
            // rather than part of it, so it recedes: muted, and italic unless it's server
            // text (the web client's `meta-body`).
            let meta = !message.type.isSpeech
            let font = message.type == .motd ? mono(base) : (meta ? base.italic : base)
            bodyText = body(message, base: font, fallback: meta ? .secondaryLabel : .label)
        }

        line.append(prefixText)
        line.append(bodyText)

        // Wrap continuation lines clear of the prefix rather than back under it. A server
        // log wraps constantly — a MOTD is long prose in a narrow column — and without
        // this the second line of every one starts back at the far-left margin, level with
        // the `--`, so the prefix stops reading as a column at all.
        //
        // Capped at the glyph column rather than set to the prefix's own width: aligning
        // continuations under the body is exactly right for a `--`, and absurd for a
        // `-NickServ-` or a server's hostname, which would hang the wrap halfway across
        // the screen. So a glyph line aligns precisely and a long prefix gets the same
        // modest indent, which keeps one left rail down the whole list either way.
        if line.length > 0, prefixText.length > 0 {
            let style = NSMutableParagraphStyle()
            style.headIndent = min(ceil(prefixText.size().width), glyphColumnWidth(base))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        }
        return line
    }

    /// The width of a `--`-style prefix plus its separator, at the current type size.
    /// Computed rather than a constant so it tracks Dynamic Type.
    private static func glyphColumnWidth(_ base: UIFont) -> CGFloat {
        ceil(NSAttributedString(string: "--  ", attributes: [.font: base.bold]).size().width)
    }

    /// The action marker, as SF Symbols' `asterisk` rather than the `*` character.
    ///
    /// A typed asterisk is a superscript glyph — it sits up on the cap line, sized for a
    /// footnote reference, and next to a nick it reads as a typo rather than a marker. The
    /// symbol is drawn on the text baseline at the weight of the surrounding font.
    ///
    /// The color is baked in (`alwaysOriginal`) because a text attachment's image ignores
    /// `.foregroundColor`. That's safe here: a nick color is a fixed hex from the palette,
    /// not a dynamic system color, so there's no light/dark resolution to lose — with the
    /// one exception of our own actions, which use `.tintColor`.
    private static func asterisk(color: UIColor, base: UIFont) -> NSAttributedString {
        let configuration = UIImage.SymbolConfiguration(font: base, scale: .small)
        guard let image = UIImage(systemName: "asterisk", withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        else {
            // Never seen in practice; the character is the honest fallback if the symbol
            // ever isn't there, rather than a line that silently loses its marker.
            return NSAttributedString(string: "*", attributes: [.font: base, .foregroundColor: color])
        }
        return NSAttributedString(attachment: NSTextAttachment(image: image))
    }

    /// What names a structural line's origin. Ported from the web client's `prefixText` and
    /// its prefix palette, so the same event reads the same in both clients — a glyph, not
    /// a nick, because these lines are the channel talking about itself.
    ///
    /// Nil means "no prefix at all", which is the web's `default: return ''`: an unknown or
    /// unmapped type (a `usermode` line, say) is shown as its own text rather than under a
    /// glyph that would be a guess about what it is.
    private static func prefix(_ message: Message) -> (text: String, color: UIColor)? {
        switch message.type {
        case .message: (message.nick ?? "*", nickColor(message))
        case .join: ("-->", Palette.good)
        case .part, .quit: ("<--", .secondaryLabel)
        case .kick: ("<--", Palette.bad)
        case .nick, .mode, .topic, .invite: ("--", .secondaryLabel)
        case .error: ("!!", Palette.bad)
        // Raw server text — numerics, the MOTD, the capability summary, your hostmask —
        // all of which the server flattens into `motd`. It's already a line the server
        // wrote to be read as-is, so it wears no glyph and just gets monospaced.
        case .motd: nil
        case .e2e: ("E2E", Palette.good)
        case .ctcp: ("CTCP", .secondaryLabel)
        // Handled by their own branches above; listed rather than defaulted so a new
        // EventType has to come back here and decide.
        case .action, .notice, .system: nil
        case .other: nil
        }
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

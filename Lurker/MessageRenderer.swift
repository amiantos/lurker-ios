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

    /// The body alone, for a bubble. On our own tinted bubble the default `.label` would be
    /// near-black on blue, so the fallback flips to white — but an mIRC-colored run still
    /// wins, because the sender chose that color on purpose.
    ///
    /// One color and one font inside every bubble, whatever the line is: the bubble already
    /// says what kind of line it is by its caption and that caption's color, so tinting the
    /// words too said it twice, and a per-type font (monospaced server text) was a second
    /// type system to maintain. A customizable font is a later feature.
    static func renderBubble(_ message: Message) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        return body(message, base: base, fallback: message.isSelf ? .white : .label)
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

    /// The caption's color. Usually a nick color, but a system line names a *network*, and
    /// server text is nobody.
    static func captionColor(_ message: Message, networkName: String?) -> UIColor {
        switch message.type {
        // A network-tied system line hashes its network name through the same palette as
        // nicks, so each network gets a stable, distinguishable color — matching the web.
        // The app speaking in its own voice ("System", no network) stays muted.
        case .system: networkName.map { hashedColor($0) } ?? .secondaryLabel
        case .motd, .other: .secondaryLabel
        default: nickColor(message)
        }
    }

    // MARK: - Full-width lines

    /// A full-width line. Two kinds reach it: an `action` (`/me`), and the structural
    /// `isActivity` events — joins, parts, quits, nick changes, modes, kicks, topics,
    /// invites. An action is tinted content; an activity line is muted narration with the
    /// names it mentions in their nick colors.
    ///
    /// No timestamp. `LineCell` reserves a trailing gutter and the time slides into it on a
    /// drag, the same as a bubble; it used to be stamped inline down the left, which put a
    /// column of identical times beside a block of server text.
    static func render(_ message: Message) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        return message.type == .action ? renderAction(message, base: base) : renderActivity(message, base: base)
    }

    /// "* alice waves" — an asterisk marker, then the actor and what they did, the whole
    /// line in their color and italic. An action is content, not metadata: alice *did* this,
    /// so it's tinted like she said it. The tint is what separates it from a bubble.
    private static func renderAction(_ message: Message, base: UIFont) -> NSAttributedString {
        let color = nickColor(message)
        let prefixText = NSMutableAttributedString()
        prefixText.append(asterisk(color: color, base: base))
        prefixText.append(NSAttributedString(
            string: " " + (message.nick ?? "*") + " ", attributes: [.font: base.italic, .foregroundColor: color]
        ))

        let line = NSMutableAttributedString()
        line.append(prefixText)
        line.append(body(message, base: base.italic, fallback: color))

        // Wrap continuation lines clear of the prefix rather than back under it — but capped
        // at a two-glyph column, so a long nick doesn't hang the wrap halfway across the
        // screen. The prefix is measured exactly (built as its own string) rather than found
        // by scanning the assembled line.
        let style = NSMutableParagraphStyle()
        style.headIndent = min(ceil(prefixText.size().width), glyphColumnWidth(base))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// A structural line — "alice joined", "bob is now bob_afk", "chan set +o dave". The
    /// actor and any nicks it names are colored; the connective words are muted, so the line
    /// reads as narration about the room rather than something someone said in it.
    private static func renderActivity(_ message: Message, base: UIFont) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let actor = nickToken(message.nick, isSelf: message.isSelf, base: base)
        switch message.type {
        case .join:
            line.append(actor)
            line.append(muted(" joined", base: base))
        case .part:
            line.append(actor)
            line.append(muted(" left", base: base))
            appendReason(message.text, to: line, base: base)
        case .quit:
            line.append(actor)
            line.append(muted(" quit", base: base))
            appendReason(message.text, to: line, base: base)
        case .nick:
            line.append(actor)
            line.append(muted(" is now ", base: base))
            line.append(nickToken(message.newNick, isSelf: message.isSelf, base: base))
        case .kick:
            line.append(nickToken(message.kicked, base: base))
            line.append(muted(" was kicked by ", base: base))
            line.append(actor)
            appendReason(message.text, to: line, base: base)
        case .mode:
            line.append(actor)
            line.append(muted(" set ", base: base))
            line.append(muted(modeDescription(message), base: base))
        case .topic:
            line.append(actor)
            line.append(muted(" set the topic", base: base))
            if let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                line.append(muted(": ", base: base))
                line.append(body(message, base: base, fallback: .secondaryLabel))
            }
        case .invite:
            line.append(actor)
            line.append(muted(" invited ", base: base))
            line.append(nickToken(message.invited, base: base))
        default:
            // render() only routes actions and activity types here, but a line still has to
            // show *something* if that ever changes: the actor, then whatever text it has.
            line.append(actor)
            if let text = message.text, !text.isEmpty { line.append(muted(" " + text, base: base)) }
        }
        return line
    }

    /// A collapsed run — "alice, bob and 3 others joined; chan set +o dave". Nicks keep
    /// their colors; the categories, connectives, and mode annotations are muted. Mirrors
    /// how the web client colors its `NickRef`s and leaves the rest as meta text.
    static func renderConsolidation(_ summary: ConsolidationSummary) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        var clauses = summary.groups.map { identityClause($0, base: base) }
        clauses.append(contentsOf: summary.modeGroups.map { modeClause($0, base: base) })

        let line = NSMutableAttributedString()
        for (index, clause) in clauses.enumerated() {
            if index > 0 { line.append(muted("; ", base: base)) }
            line.append(clause)
        }
        return line
    }

    // MARK: - Line building blocks

    /// A nick in its own color (or the tint, when it's you). Falls back to "someone" for the
    /// nick-less event that shouldn't happen but mustn't render blank.
    private static func nickToken(_ nick: String?, isSelf: Bool = false, base: UIFont) -> NSAttributedString {
        let name = (nick?.isEmpty == false) ? nick! : "someone"
        let color = isSelf ? UIColor.tintColor : hashedColor(nick ?? "")
        return NSAttributedString(string: name, attributes: [.font: base, .foregroundColor: color])
    }

    private static func muted(_ text: String, base: UIFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: UIColor.secondaryLabel])
    }

    /// A part/quit reason in parentheses, or nothing when there isn't one.
    private static func appendReason(_ text: String?, to line: NSMutableAttributedString, base: UIFont) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        line.append(muted(" (" + text + ")", base: base))
    }

    /// The change list of a mode event as text — "+o alice", or "+o alice +nt". Prefers the
    /// structured `modes` (so it stays clean); falls back to the raw `text` the server sends.
    private static func modeDescription(_ message: Message) -> String {
        guard !message.modes.isEmpty else { return message.text ?? "" }
        return message.modes
            .map { change in change.param.map { "\(change.mode) \($0)" } ?? change.mode }
            .joined(separator: " ")
    }

    private static func identityClause(
        _ group: ConsolidationSummary.IdentityGroup, base: UIFont
    ) -> NSAttributedString {
        let clause = NSMutableAttributedString()
        for (index, entry) in group.visible.enumerated() {
            if index > 0 {
                // "and" before the final name only when the list isn't truncated; a
                // truncated list ends "…, and N others" instead.
                let isLast = index == group.visible.count - 1
                clause.append(muted(isLast && group.hidden == 0 ? " and " : ", ", base: base))
            }
            clause.append(entryToken(entry, base: base))
        }
        if group.hidden > 0 {
            clause.append(muted(", and \(group.hidden) other\(group.hidden == 1 ? "" : "s")", base: base))
        }
        clause.append(muted(verb(group.kind), base: base))
        return clause
    }

    private static func entryToken(_ entry: ConsolidationSummary.Entry, base: UIFont) -> NSAttributedString {
        switch entry {
        case .nick(let nick):
            return nickToken(nick, base: base)
        case .renamed(let from, let to):
            let token = NSMutableAttributedString()
            token.append(nickToken(from, base: base))
            token.append(muted(" → ", base: base))
            token.append(nickToken(to, base: base))
            return token
        }
    }

    private static func modeClause(
        _ mode: ConsolidationSummary.ModeSummary, base: UIFont
    ) -> NSAttributedString {
        let clause = NSMutableAttributedString()
        clause.append(nickToken(mode.setter, base: base))
        clause.append(muted(" set ", base: base))
        let changes = mode.changes.map { change in
            change.params.isEmpty ? change.mode : "\(change.mode) \(change.params.joined(separator: ", "))"
        }
        clause.append(muted(changes.joined(separator: ", "), base: base))
        return clause
    }

    private static func verb(_ kind: ConsolidationSummary.IdentityGroup.Kind) -> String {
        switch kind {
        case .joined: " joined"
        case .left: " left"
        case .reconnected: " reconnected"
        case .joinedAndLeft: " joined briefly"
        case .renamed: "" // the → in the name conveys it
        }
    }

    /// The width of a two-glyph prefix column at the current type size — the cap on how far
    /// a wrapped line's continuation indents. Computed so it tracks Dynamic Type.
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

    static func nickColor(_ message: Message) -> UIColor {
        if message.isSelf { return .tintColor }
        return hashedColor(message.nick ?? "")
    }

    /// A stable color for a name, from the shared nick palette. Nicks and network names
    /// both run through it, so the same name is always the same color and different ones
    /// are told apart.
    static func hashedColor(_ name: String) -> UIColor {
        UIColor(hex: IRCPalette.nick[NickColor.index(for: name)]) ?? .secondaryLabel
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

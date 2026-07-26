// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import LurkerKit
import UIKit

/// Turns a `Message` into styled text, mirroring the web client: mIRC formatting, colors, and
/// auto-linked URLs. One font size throughout — hierarchy comes from weight, italics, and color,
/// never size.
///
/// The list draws in one shape (see `MessageListRenderer`), so what comes back is a *body*: the
/// author and the time belong to the cell, drawn once per block, and must not also be baked into
/// the text. `caption`/`captionColor` say what to call a line's author for that header.
extension NSAttributedString.Key {
    /// A URL this client will open itself, stamped by `MessageRenderer` and read back by
    /// `MessageTextView.url(at:)`.
    ///
    /// Deliberately not `.link`: that one is UIKit's, and UIKit insists on restyling it. See the
    /// note where links are marked.
    static let messageLink = NSAttributedString.Key("chat.lurker.messageLink")
}

enum MessageRenderer {

    // MARK: - Bubbles

    /// What names a message's author in its block header. Nil leaves the block unheaded.
    ///
    /// `modePrefix` is the speaker's channel-mode glyph (`@`, `+`, …) when
    /// `look.nick.show_mode_prefix` is on and they're a current member — the caller resolves
    /// it, because it comes from the nicklist rather than from the message. It prefixes a
    /// nick only: a network or a notice's `-mark-` isn't a channel member.
    static func caption(_ message: Message, networkName: String?, modePrefix: String = "") -> String? {
        switch message.type {
        // IRC's own mark for a notice, in the place that names the speaker — the only
        // thing separating "NickServ said this" from "NickServ noticed this".
        case .notice: "-\(message.nick ?? "")-"
        // App-scoped, so it names the network it's *about* rather than a nick.
        case .system: networkName ?? "System"
        // Raw server text has no author but the server itself.
        case .motd, .other: networkName
        default: message.nick.map { modePrefix + $0 }
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

    /// A structural line — "alice joined", "bob is now bob_afk", "chan set +o dave". The
    /// actor and any nicks it names are colored; the connective words are muted, so the line
    /// reads as narration about the room rather than something someone said in it.
    private static func renderActivity(
        _ message: Message, base: UIFont, settings: Settings = Settings()
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let actor = nickToken(message.nick, isSelf: message.isSelf, base: base)
        // Both off by default, matching the registry. The account sits between the nick and
        // the host, as it does on the web (and in weechat, irssi and thelounge).
        let account = settings.bool("chat.show_join_account", default: false)
            ? message.account.map { " [\($0)]" } ?? "" : ""
        let host = settings.bool("chat.show_event_host", default: false)
            ? message.userHostMask.map { " (\($0))" } ?? "" : ""
        switch message.type {
        case .join:
            line.append(actor)
            line.append(muted(account + host + " joined", base: base))
        case .part:
            line.append(actor)
            line.append(muted(host + " left", base: base))
            appendReason(message.text, to: line, base: base)
        case .quit:
            line.append(actor)
            line.append(muted(host + " quit", base: base))
            appendReason(message.text, to: line, base: base)
        case .nick:
            line.append(actor)
            line.append(muted(" is now ", base: base))
            line.append(nickToken(message.newNick, isSelf: message.isSelf, base: base))
            line.append(muted(host, base: base))
        case .kick:
            line.append(nickToken(message.kicked, base: base))
            line.append(muted(" was kicked by ", base: base))
            line.append(actor)
            appendReason(message.text, to: line, base: base)
        case .mode:
            line.append(actor)
            line.append(muted(" set ", base: base))
            line.append(muted(modeDescription(message), base: base))
        case .chghost:
            // The suffix here is the mask *before* the change — the new one is the body of
            // the line — which is what makes weechat's "nick (old) has changed host to new"
            // shape readable.
            line.append(actor)
            line.append(muted(host + " changed host to " + message.chghostMask, base: base))
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

    /// A collapsed run — "alice, bob and 3 others joined; dave left". Nicks keep their
    /// colors; the categories and connectives are muted. Mirrors how the web client colors
    /// its `NickRef`s and leaves the rest as meta text.
    static func renderConsolidation(
        _ summary: ConsolidationSummary, base: UIFont = .preferredFont(forTextStyle: .subheadline)
    ) -> NSAttributedString {
        let clauses = summary.groups.map { identityClause($0, base: base) }

        let line = NSMutableAttributedString()
        for (index, clause) in clauses.enumerated() {
            if index > 0 { line.append(muted("; ", base: base)) }
            line.append(clause)
        }
        return line
    }

    /// "alice is typing…" — the live composing line that sits at the foot of the buffer.
    ///
    /// Built like a consolidation summary rather than as a bubble: it's narration about the
    /// room, not speech in it, and it has no author to caption. Names keep their palette
    /// colors so you can pick out who without reading; the connective text is muted, which
    /// with the absent timestamp is enough to place it as an aside rather than a record.
    ///
    /// Upright, not italic. The line already reads as apart from the conversation — it sits
    /// below the newest message, carries no bubble and no time — and setting the one row that
    /// changes most often in a second style made it pull the eye harder than a thing that says
    /// nothing has earned.
    ///
    /// Returns nil for an empty list so the caller has one thing to check rather than
    /// rendering a stray " is typing…".
    static func renderTyping(
        _ nicks: [String], base: UIFont = .preferredFont(forTextStyle: .subheadline)
    ) -> NSAttributedString? {
        guard !nicks.isEmpty else { return nil }
        // Past three names the list stops being scannable and starts being a wall — the same
        // judgement `Consolidation` makes about a join flood, and the same phrasing.
        let visible = nicks.prefix(3)
        let hidden = nicks.count - visible.count

        let line = NSMutableAttributedString()
        for (index, nick) in visible.enumerated() {
            if index > 0 {
                // "and" before the final name only when nothing is truncated; a truncated
                // list ends "…, and N others" instead.
                let isLast = index == visible.count - 1
                line.append(muted(isLast && hidden == 0 ? " and " : ", ", base: base))
            }
            line.append(nickToken(nick, base: base))
        }
        if hidden > 0 {
            line.append(muted(", and \(hidden) other\(hidden == 1 ? "" : "s")", base: base))
        }
        // Singular only for one name: "alice and bob are", "alice, bob, and 2 others are".
        line.append(muted(nicks.count == 1 ? " is typing…" : " are typing…", base: base))
        return line
    }

    // MARK: - Compact (terminal) style

    /// The gap between two consecutive lines in the compact style.
    ///
    /// One constant because it has to be one number: it's applied *inside* a message as
    /// `lineSpacing` (between wrapped lines) and *around* one as `CompactCell`'s vertical inset
    /// (half at each end, so two adjacent cells add up to the same gap). Any drift between the two
    /// and the rhythm stutters at every message boundary, which is what stops a log reading as a
    /// grid — a wrapped line and a new message have to be equally far apart.
    static let compactLineGap: CGFloat = 3

    /// The gap between an author header and the first line of their message.
    ///
    /// Its own constant rather than half the line gap: the header is a different kind of thing
    /// from the words under it, so it wants a little more air than two body lines want from each
    /// other — and the line gap is now tight enough that sharing it clamped the name to the text.
    static let compactHeaderGap: CGFloat = 4

    /// How much of the block gap belongs *inside* a block's own background rather than between
    /// two of them.
    ///
    /// A matched block whose wash starts at the cap-height of its first line and stops at the
    /// baseline of its last reads as a highlighter dragged across the text. Giving the fill a third
    /// of the gap at each end makes it a band the text sits inside. The remaining third stays
    /// outside as background, so the distance between two blocks is unchanged — the gap is split,
    /// not added to.
    static func compactWashPadding(compatibleWith traits: UITraitCollection = .current) -> CGFloat {
        compactBlockGap(compatibleWith: traits) / 3
    }

    /// The gap after the last message of an author block, so blocks read as blocks.
    ///
    /// Three quarters of a line rather than a whole one: a full blank line between every block is
    /// most of the height a bubble list spends, which is the thing this style exists to avoid.
    /// Scaled off the face so it tracks Dynamic Type with everything else.
    static func compactBlockGap(compatibleWith traits: UITraitCollection = .current) -> CGFloat {
        ceil(compactFont(compatibleWith: traits).lineHeight * 0.75)
    }

    /// The monospaced face the compact style draws in — a fixed-width log, the way irssi and
    /// weechat look. Scaled through `UIFontMetrics` so it still answers to Dynamic Type, and sized
    /// off `.subheadline` so it matches the rest of the app rather than introducing a second size.
    ///
    /// Resolved against the caller's `traits`, never `UITraitCollection.current` — the same rule
    /// `render` follows above, and for the same reason: `.current` isn't reliably set during
    /// `cellForRowAt`, which is exactly where every one of these is asked for.
    ///
    /// Cached with the character width beside it, because between them they're wanted five times
    /// per row — building a font and measuring a glyph each time, for every visible cell on every
    /// reload. Keyed on the content size category *of those traits*, so a Dynamic Type change
    /// rebuilds them and a stray resolution can't leave a wrong entry behind.
    static func compactFont(compatibleWith traits: UITraitCollection = .current) -> UIFont {
        compactMetrics(traits).font
    }

    /// One character of that face — the amount a message body sits in from its author, and the
    /// amount a wrapped narration line sits in from where it started.
    static func compactIndent(compatibleWith traits: UITraitCollection = .current) -> CGFloat {
        compactMetrics(traits).indent
    }

    private static var cachedCompactMetrics: (category: UIContentSizeCategory, font: UIFont, indent: CGFloat)?

    private static func compactMetrics(_ traits: UITraitCollection) -> (font: UIFont, indent: CGFloat) {
        let category = traits.preferredContentSizeCategory
        if let cached = cachedCompactMetrics, cached.category == category {
            return (cached.font, cached.indent)
        }
        let reference = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedSystemFont(ofSize: reference.pointSize, weight: .regular),
            compatibleWith: traits
        )
        let indent = (" " as NSString).size(withAttributes: [.font: font]).width
        cachedCompactMetrics = (category, font, indent)
        return (font, indent)
    }

    /// The body of a compact row — the text alone, with no time and no author.
    ///
    /// Those are the cell's (`CompactCell` draws the header), which is what lets several messages
    /// from one person stack under a single nick. What comes back is the same text the bubble
    /// style would render, in the monospaced face: same mIRC colours, same auto-linking, same
    /// nick colouring inside the body.
    static func renderCompactBody(
        _ message: Message,
        traits: UITraitCollection = .current,
        settings: Settings = Settings(),
        highlighter: NickHighlighter? = nil
    ) -> NSAttributedString {
        let base = compactFont(compatibleWith: traits)

        // A line that names its own actor keeps doing so: it has no header to be named by.
        if message.type == .action {
            let color = nickColor(message)
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(
                string: "* \(message.nick ?? "*") ", attributes: [.font: base, .foregroundColor: color]
            ))
            line.append(body(message, base: base, fallback: color, highlighter: highlighter))
            // Two, to clear the `* ` this line opens with.
            return spaced(line, flushFirstLine: true, indentCharacters: 2, traits: traits)
        }
        if message.type.isActivity {
            // No arrow column. "alice joined" already says which direction it went, and the
            // narration starts flush with the nicks above it now, so the arrows were an extra
            // column of punctuation buying nothing.
            return spaced(
                NSMutableAttributedString(
                    attributedString: renderActivity(message, base: base, settings: settings)
                ),
                flushFirstLine: true, traits: traits
            )
        }
        return spaced(
            NSMutableAttributedString(
                attributedString: body(message, base: base, fallback: .label, highlighter: highlighter)
            ),
            flushFirstLine: false, traits: traits
        )
    }

    /// A collapsed run in the compact style — header-less, like the activity lines it stands for.
    static func renderCompactConsolidation(
        _ summary: ConsolidationSummary, traits: UITraitCollection = .current
    ) -> NSAttributedString {
        spaced(
            NSMutableAttributedString(
                attributedString: renderConsolidation(summary, base: compactFont(compatibleWith: traits))
            ),
            flushFirstLine: true, traits: traits
        )
    }

    /// The typing line in the compact style.
    static func renderCompactTyping(
        _ nicks: [String], traits: UITraitCollection = .current
    ) -> NSAttributedString? {
        guard let typists = renderTyping(nicks, base: compactFont(compatibleWith: traits)) else { return nil }
        return spaced(
            NSMutableAttributedString(attributedString: typists), flushFirstLine: true, traits: traits
        )
    }

    /// `14:42` for a compact header.
    ///
    /// Minutes, not seconds: the stamp only appears when the minute changes, so a seconds field
    /// would be showing the precise moment of whichever message happened to start the minute —
    /// precision the format doesn't actually carry. Fixed 24-hour through a POSIX locale, since
    /// `HH` still renders 12-hour under some region settings.
    static func compactHeaderTime(_ date: Date) -> String {
        compactTimeFormatter.string(from: date)
    }

    private static let compactTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Space a body's wrapped rows apart by `compactLineGap`, so they sit the same distance from
    /// each other as they do from the row above and below — and indent it.
    ///
    /// Indentation is a paragraph style rather than the cell's inset because the two kinds of row
    /// want different first lines. A message body is indented throughout, sitting under its author.
    /// Narration that names its own actor — a `/me`, a join, a collapsed run — starts flush with
    /// where a nick would be, since it *is* the nick line, and only its wrapped continuations tuck
    /// in.
    ///
    /// `indentCharacters` is how far. One for most things; two for a `/me`, whose `* ` prefix is
    /// two characters wide, so a one-character hang put the wrap under the space rather than under
    /// the words.
    ///
    /// Set on the whole range last, which also clears any paragraph style a shared builder applied
    /// for the bubble style (a `/me`'s own hanging indent, for one).
    private static func spaced(
        _ line: NSMutableAttributedString,
        flushFirstLine: Bool,
        indentCharacters: Int = 1,
        traits: UITraitCollection
    ) -> NSAttributedString {
        let indent = compactIndent(compatibleWith: traits) * CGFloat(indentCharacters)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = compactLineGap
        style.headIndent = indent
        style.firstLineHeadIndent = flushFirstLine ? 0 : indent
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    // MARK: - Line building blocks

    /// A nick in its own color. Falls back to "someone" for the nick-less event that shouldn't
    /// happen but mustn't render blank.
    private static func nickToken(_ nick: String?, isSelf: Bool = false, base: UIFont) -> NSAttributedString {
        let name = (nick?.isEmpty == false) ? nick! : "someone"
        return NSAttributedString(
            string: name, attributes: [.font: base, .foregroundColor: nickColor(nick, isSelf: isSelf)]
        )
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

    private static func verb(_ kind: ConsolidationSummary.IdentityGroup.Kind) -> String {
        switch kind {
        case .joined: " joined"
        case .left: " left"
        case .reconnected: " reconnected"
        case .joinedAndLeft: " joined briefly"
        case .renamed: "" // the → in the name conveys it
        case .rehosted: " changed host"
        }
    }

    // MARK: - Body

    private static func body(
        _ message: Message, base: UIFont, fallback: UIColor, highlighter: NickHighlighter? = nil
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        // The spans the sender colored themselves with mIRC codes — an explicit color wins
        // over nick coloring, so these are off-limits to the mention pass below.
        var mircColored: [NSRange] = []
        for run in IRCFormatting.parse(message.text ?? "") {
            // Always set an explicit color: unlike a label, a UITextView's attributed runs
            // without a foreground color fall back to a static black, not the dynamic
            // `.label`, so uncolored text would be unreadable in dark mode.
            let explicitFg = run.fg.flatMap(mircColor)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(base, bold: run.bold, italic: run.italic),
                .foregroundColor: explicitFg ?? fallback,
            ]
            if let bg = run.bg, let color = mircColor(bg) { attributes[.backgroundColor] = color }
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let start = attributed.length
            attributed.append(NSAttributedString(string: run.text, attributes: attributes))
            if explicitFg != nil { mircColored.append(NSRange(location: start, length: attributed.length - start)) }
        }
        // Auto-link URLs over the assembled plain text (control codes already stripped).
        //
        // Marked with `.messageLink`, NOT `.link`. A UITextView restyles every `.link` range with
        // its `linkTextAttributes` — one dictionary for the whole view — over whatever the string
        // says. That can't express what links need here, because the right color depends on the
        // line: a `/me`'s body is the nick's color (see `action`), a sender's mIRC run is whatever
        // they chose, and everything else is `.label`. Forcing one color flattened all three, which
        // is how `/me` links came out white. Nothing needs `.link` anymore — taps are hit-tested
        // against this key instead (`MessageTextView.url(at:)`) — so the string keeps full control.
        //
        // A link therefore takes no color of its own: it's the color of the text around it, with a
        // dimmed underline, matching the web's `--link` treatment (40% underline).
        var links: [NSRange] = []
        for match in URLMatcher.matches(in: attributed.string) {
            guard let url = URL(string: match.href) else { continue }
            attributed.addAttribute(.messageLink, value: url, range: match.range)
            // Per color run, not once for the range: a URL can straddle a color change if the
            // sender put one mid-link, and the underline should follow the text above it.
            attributed.enumerateAttribute(.foregroundColor, in: match.range) { value, range, _ in
                let color = (value as? UIColor) ?? .label
                attributed.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: color.withAlphaComponent(0.4),
                    ],
                    range: range
                )
            }
            links.append(match.range)
        }
        // Color known nicks named in the body, in their palette color — but never over a span
        // the sender colored, nor inside a link, both of which own their styling.
        if let highlighter, !highlighter.isEmpty {
            let text = attributed.string as NSString
            for range in highlighter.matches(in: attributed.string) {
                let taken = mircColored.contains { NSIntersectionRange($0, range).length > 0 }
                    || links.contains { NSIntersectionRange($0, range).length > 0 }
                if taken { continue }
                attributed.addAttribute(.foregroundColor, value: hashedColor(text.substring(with: range)), range: range)
            }
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        // "Today"/"Yesterday" where the locale has words for them, the full date otherwise.
        // The web uses a plain `dateStyle: 'full'` here; this is the platform convention
        // (Messages, Mail) and it earns its keep on a divider the reader passes every day.
        formatter.doesRelativeDateFormatting = true
        // A `DateFormatter` otherwise snapshots `Locale.current` at init, and this one is a
        // `static let` that outlives any region change — so it would keep formatting in the
        // old locale for the rest of the process. Pairs with the redraw `ChatViewController`
        // does on `NSLocale.currentLocaleDidChangeNotification`.
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    /// The label on a day-change divider — "Today", "Yesterday", or "Friday, 25 July 2026".
    static func dayLabel(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - Colors

    static func nickColor(_ message: Message) -> UIColor {
        nickColor(message.nick, isSelf: message.isSelf)
    }

    /// Your own nick is the plain foreground, not the accent.
    ///
    /// Matches the web, whose `look.nick.self_color` defaults to `var(--fg)`. The accent is the
    /// app's voice — the send button, a live control — and wearing it in the log made every line
    /// you'd written look like a piece of UI rather than a thing you said. It's also the one nick
    /// you never need to pick out of a crowd.
    ///
    /// (The in-body pass agrees by omission: `NickHighlighter` is built without your own nick, so
    /// a self-mention keeps the body's color rather than taking a palette one.)
    static func nickColor(_ nick: String?, isSelf: Bool) -> UIColor {
        isSelf ? .label : hashedColor(nick ?? "")
    }

    /// The nick palette as trait-keyed colors, built once and indexed by the djb2 hash. A
    /// fixed set (dark hex + light variant per slot), so there's no reason to re-parse the
    /// hex and allocate a dynamic UIColor on every lookup.
    private nonisolated static let nickColors: [UIColor] =
        zip(IRCPalette.nick, IRCPalette.nickLight).map { dynamicHex(dark: $0, light: $1) }

    /// The mIRC palette's chromatic slots as trait-keyed colors, built once; `nil` is a theme
    /// slot that resolves to a system color instead (see `mircColor`).
    private nonisolated static let mircColors: [UIColor?] = IRCPalette.mirc.indices.map { index in
        IRCPalette.mirc[index].map { dynamicHex(dark: $0, light: IRCPalette.mircLight[index] ?? $0) }
    }

    /// A stable color for a name, from the shared nick palette. Nicks and network names
    /// both run through it, so the same name is always the same color and different ones
    /// are told apart. Dynamic: the Monokai hex in dark mode, its light variant in light.
    static func hashedColor(_ name: String) -> UIColor {
        nickColors[NickColor.index(for: name)]
    }

    /// A `UIColor` that resolves `dark` in dark mode and `light` in light mode. The nick and
    /// mIRC palettes are fixed hex, but each needs a different variant per theme, and a
    /// trait-keyed color adapts everywhere it's drawn (captions, tokens, in-body mentions)
    /// with no work at the call site.
    nonisolated static func dynamicHex(dark: String, light: String) -> UIColor {
        guard let darkColor = UIColor(hex: dark), let lightColor = UIColor(hex: light) else {
            return .secondaryLabel
        }
        return UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
    }

    /// mIRC index → color. The theme slots (0/1/14/15) map to system colors; 16+ don't
    /// render. Chromatic slots are dynamic, like nick colors.
    private nonisolated static func mircColor(_ index: Int) -> UIColor? {
        guard index >= 0, index < IRCPalette.mirc.count else { return nil }
        if let color = mircColors[index] { return color }
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

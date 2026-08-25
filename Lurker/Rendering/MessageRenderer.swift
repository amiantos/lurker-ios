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

    /// Marks a spoiler run, valued with its ordinal within the message so a tap can say *which*
    /// one it hit — a line can hold several. Present whether the run is hidden or revealed: it's
    /// what makes the tap target exist in both states, so a reveal can be taken back.
    static let spoiler = NSAttributedString.Key("chat.lurker.spoiler")

    /// Present only while a spoiler run is still hidden, valued with **what to say instead** of
    /// the text underneath. Separate from `.spoiler`, which stays on the run in both states so
    /// the tap target survives a reveal — this is the one that says the text must not be spoken.
    ///
    /// The wording rides along rather than living in `spoken(_:)` because it isn't always the
    /// same: a run the reader can't open (see `.spoiler`) must not be announced as though they
    /// could. See `MessageRenderer.spoken(_:)`.
    static let spoilerHidden = NSAttributedString.Key("chat.lurker.spoilerHidden")
}

enum MessageRenderer {

    // MARK: - Authors

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
        case .system: networkName.map { hashedColor($0) } ?? Palette.fgMuted
        case .motd, .other: Palette.fgMuted
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
            for segment in ModeNarration.describe(message.modes, rawText: message.text) {
                switch segment {
                case .text(let t), .arg(let t):
                    line.append(muted(t, base: base))
                case .nick(let n):
                    // Only ever emitted for a `prefix` change, so this is a real member and
                    // never a mask — a ban's target must not get a nick's colour and menu.
                    line.append(nickToken(n, base: base))
                }
            }
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
                // The same muted as the ": " immediately before it — two greys mid-sentence read
                // as a seam, and the topic text is a continuation of the narration, not a quote.
                line.append(body(message, base: base, fallback: Palette.fgMuted))
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

    /// "⌨ alice, bob" — the live composing line that sits at the foot of the buffer.
    ///
    /// Built like a consolidation summary rather than as a bubble: it's narration about the
    /// room, not speech in it, and it has no author to caption. Names keep their palette
    /// colors so you can pick out who without reading; the keyboard glyph and the separators
    /// are muted, which with the absent timestamp is enough to place it as an aside rather
    /// than a record.
    ///
    /// A symbol and a bare list rather than a sentence, matching the web status bar: the row
    /// exists to be glanced at, and "is typing…"/"are typing…" spent a third of a phone-width
    /// line restating what the glyph already says — while the singular/plural swap made the
    /// most-often-redrawn row in the buffer reflow as people joined and left the list.
    ///
    /// Upright, not italic. The line already reads as apart from the conversation — it sits
    /// below the newest message, carries no bubble and no time — and setting the one row that
    /// changes most often in a second style made it pull the eye harder than a thing that says
    /// nothing has earned.
    ///
    /// Returns nil for an empty list so the caller has one thing to check rather than
    /// rendering a lone glyph.
    static func renderTyping(
        _ nicks: [String],
        base: UIFont = .preferredFont(forTextStyle: .subheadline),
        traits: UITraitCollection = .current
    ) -> NSAttributedString? {
        guard !nicks.isEmpty else { return nil }
        // Past three names the list stops being scannable and starts being a wall. Fixed, unlike
        // `Consolidation`'s `chat.consolidate_max_names`: that setting is about how much of a
        // netsplit you want written into the log permanently, and this line isn't a record — it's
        // gone the moment they stop. The web hardcodes its own cap for the same reason. The
        // overflow is the web's `+N` rather than "and N others": prose the glyph replaced
        // everywhere else.
        let visible = nicks.prefix(3)
        let hidden = nicks.count - visible.count

        let line = NSMutableAttributedString(attributedString: typingGlyph(base: base, traits: traits))
        // Non-breaking, so the row can't wrap here. A breakable space let TextKit end line one
        // after the glyph — a first line holding nothing but a keyboard symbol, which the old
        // wording couldn't produce because it opened with a name.
        line.append(muted("\u{00A0}", base: base))
        for (index, nick) in visible.enumerated() {
            if index > 0 { line.append(muted(", ", base: base)) }
            line.append(nickToken(nick, base: base))
        }
        if hidden > 0 {
            line.append(muted(", +\(hidden)", base: base))
        }
        return line
    }

    /// The keyboard symbol that opens the typing line, sized and colored like the muted text
    /// beside it.
    ///
    /// `withTintColor(.alwaysOriginal)` rather than leaving it a template: a text attachment
    /// doesn't take the label's color the way glyphs do, and a template one would draw in the
    /// text view's tint — the accent — which is louder than an aside wants to be.
    ///
    /// The color has to be *resolved* here rather than handed over dynamic: baking a color
    /// into an image is a draw, and it happens with whatever traits are current at the moment
    /// this runs. Those aren't the row's during `cellForRowAt` (the same trap the rest of the
    /// renderer takes `traits` for), so a dark-mode buffer would get the light-mode grey.
    ///
    /// Sized off `base.pointSize` rather than `SymbolConfiguration(font:)`. A configuration
    /// built from a font carries that font's *text style* and rescales at image-creation time
    /// against whatever traits are current then — which puts `.current` back in the path the
    /// `traits` parameter exists to keep it out of, and lands a glyph sized for one category
    /// beside text sized for another. A point size is just a number: `base` is already scaled
    /// for `traits`, so the symbol tracks the text at every size.
    ///
    /// Centered on the cap height instead of sitting on the baseline, where a square symbol
    /// reads as riding low next to lowercase nicks. The `.font` is carried on the attachment's
    /// own run too — a run with no font is laid out in TextKit's ~12pt default, which made the
    /// typing row taller than every other row at small text sizes.
    ///
    /// `accessibilityLabel` is what `spoken(_:)` substitutes for the attachment character —
    /// without it the row is read out as a bare list of names with no hint of what they're doing.
    /// The colon is doing work in speech that the glyph does in print: it's what makes the word
    /// a lead-in to the list rather than the first word of one phrase ("Typing: alice, bob", not
    /// "Typing alice bob"). It's never drawn.
    private static func typingGlyph(base: UIFont, traits: UITraitCollection) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.accessibilityLabel = "Typing:"
        if let image = UIImage(
            systemName: "keyboard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: base.pointSize)
        )?.withTintColor(
            Palette.fgMuted.resolvedColor(with: traits), renderingMode: .alwaysOriginal
        ) {
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0, y: (base.capHeight - image.size.height) / 2,
                width: image.size.width, height: image.size.height
            )
        }
        let glyph = NSMutableAttributedString(attachment: attachment)
        glyph.addAttribute(.font, value: base, range: NSRange(location: 0, length: glyph.length))
        return glyph
    }

    /// A rendered line as VoiceOver should hear it: attachment characters swapped for the
    /// words they stand in for.
    ///
    /// `NSAttributedString.string` keeps an attachment as U+FFFC, which is spoken as nothing —
    /// so any meaning carried by a glyph rather than by text is simply lost from a label built
    /// out of it. Anything without a label of its own drops out rather than leaving the
    /// placeholder in the sentence.
    ///
    /// ⚠⚠ A still-hidden spoiler is substituted too, and that one is not cosmetic: without it a
    /// screen reader announces the secret while the screen shows a blank box. The web stops this
    /// with `aria-hidden`; here the label is built out of the string, so the string is where it
    /// has to be stopped. The words name the affordance rather than describing a redaction,
    /// because to VoiceOver this is a thing you can activate.
    ///
    /// One attribute walk, always — the previous U+FFFC fast path can't cover spoilers, which
    /// have no marker character to scan for. The walk is over a single message's runs and is
    /// cheap; what it still guards is the DEEP COPY below, which only happens once something is
    /// actually found. A row with nothing to substitute also returns the plain string untouched,
    /// so the trim can't turn a whitespace-only body into an empty label.
    static func spoken(_ attributed: NSAttributedString) -> String {
        let plain = attributed.string
        let whole = NSRange(location: 0, length: attributed.length)

        var ranges: [(NSRange, String)] = []
        if plain.utf16.contains(0xFFFC) {
            attributed.enumerateAttribute(.attachment, in: whole) { value, range, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                ranges.append((range, attachment.accessibilityLabel ?? ""))
            }
        }
        attributed.enumerateAttribute(.spoilerHidden, in: whole) { value, range, _ in
            guard let announcement = value as? String else { return }
            ranges.append((range, announcement))
        }
        guard !ranges.isEmpty else { return plain }

        let text = NSMutableAttributedString(attributedString: attributed)
        // Backwards, so replacing one range doesn't shift the ranges of the ones before it.
        // Sorted first: the two passes above collect independently, so they don't arrive in
        // document order and a raw reverse would corrupt an interleaved pair.
        for (range, label) in ranges.sorted(by: { $0.0.location < $1.0.location }).reversed() {
            text.replaceCharacters(in: range, with: label)
        }
        return text.string.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// weechat look. Sized off `.subheadline` at the caller's traits, so it answers to Dynamic Type
    /// and matches the rest of the app rather than introducing a second size.
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
        // `preferredFont(compatibleWith:)` has *already* applied `traits` — its point size is the
        // scaled one. Handing that to `UIFontMetrics.scaledFont(for:)`, which exists to scale a
        // font written at the default (Large) size, scaled it a second time: 142pt where 49pt is
        // right at AX-XXXL, and 10pt where 12pt is right at extraSmall, since a double scale
        // over-shrinks below Large as surely as it overshoots above it. The two agree exactly at
        // Large, which is why it went unseen. A monospaced face at an already-scaled size needs no
        // metrics of its own.
        let reference = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let font = UIFont.monospacedSystemFont(ofSize: reference.pointSize, weight: .regular)
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
        highlighter: NickHighlighter? = nil,
        revealed: Set<Int> = [],
        hiddenUrls: Set<String> = []
    ) -> NSAttributedString {
        let base = compactFont(compatibleWith: traits)

        // A line that names its own actor keeps doing so: it has no header to be named by.
        if message.type == .action {
            let color = nickColor(message)
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(
                string: "* \(message.nick ?? "*") ", attributes: [.font: base, .foregroundColor: color]
            ))
            line.append(
                body(
                    message, base: base, fallback: color, highlighter: highlighter,
                    revealed: revealed, hiddenUrls: hiddenUrls))
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
                // `Palette.fg`, not `.label`, and not left to the text view's `textColor` either:
                // `body` stamps an explicit foreground on every run (see the note there), so a
                // colour set on the label never reaches a single character of message text. This
                // fallback IS the log's primary text colour.
                attributedString: body(
                    message, base: base, fallback: Palette.fg,
                    highlighter: highlighter, revealed: revealed, hiddenUrls: hiddenUrls
                )
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
    ///
    /// Hangs by the glyph's width on top of the usual one character, so a list long enough to
    /// wrap puts its continuation under the first *name* rather than under the middle of the
    /// keyboard. One character was the right hang while the line opened with a nick; the glyph
    /// is about two and a half characters wide at default size, and the ratio drifts with
    /// Dynamic Type — so it's measured, not guessed.
    static func renderCompactTyping(
        _ nicks: [String], traits: UITraitCollection = .current
    ) -> NSAttributedString? {
        guard let typists = renderTyping(
            nicks, base: compactFont(compatibleWith: traits), traits: traits
        ) else { return nil }
        // Read back off the attachment rather than re-rendering the symbol to measure it.
        let glyph = typists.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        return spaced(
            NSMutableAttributedString(attributedString: typists), flushFirstLine: true,
            extraIndent: glyph?.bounds.width ?? 0, traits: traits
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
    /// the words. `extraIndent` is for a prefix that isn't a whole number of characters wide at
    /// all — the typing line's keyboard symbol, which has to be measured.
    ///
    /// Set on the whole range last, so it wins over any paragraph style a shared builder left on
    /// the text.
    private static func spaced(
        _ line: NSMutableAttributedString,
        flushFirstLine: Bool,
        indentCharacters: Int = 1,
        extraIndent: CGFloat = 0,
        traits: UITraitCollection
    ) -> NSAttributedString {
        let indent = compactIndent(compatibleWith: traits) * CGFloat(indentCharacters) + extraIndent
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
        NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: Palette.fgMuted])
    }

    /// A part/quit reason in parentheses, or nothing when there isn't one.
    private static func appendReason(_ text: String?, to line: NSMutableAttributedString, base: UIFont) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        line.append(muted(" (" + text + ")", base: base))
    }

    /// The change list of a mode event as text — "+o alice", or "+o alice +nt". Prefers the
    /// structured `modes` (so it stays clean); falls back to the raw `text` the server sends.
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
        clause.append(muted(verb(group), base: base))
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

    private static func verb(_ group: ConsolidationSummary.IdentityGroup) -> String {
        switch group.kind {
        case .joined: return " joined"
        case .left: return " left"
        case .reconnected: return " reconnected"
        case .joinedAndLeft: return " joined briefly"
        case .renamed: return "" // the → in the name conveys it
        case .rehosted: return " changed host"
        default: return modeVerb(group)
        }
    }

    /// What a member-prefix letter grants, for the summary's "were opped" phrasing.
    ///
    /// Only the LETTER travels on the group — the words are each client's own business, the
    /// same way "joined" and "changed host" are — so this table lives here rather than in
    /// LurkerKit, mirroring how the web client does it.
    ///
    /// `o` and `v` are effectively all real traffic and get proper verbs. Anything else falls
    /// back to the token: inventing English for `+a` on an ircd nobody in the room runs would
    /// be guessing, and "was given +a" is honest and readable.
    private static let modeVerbs: [String: (on: String, off: String)] = [
        "o": (on: "opped", off: "deopped"),
        "v": (on: "voiced", off: "devoiced"),
    ]

    private static func modeVerb(_ group: ConsolidationSummary.IdentityGroup) -> String {
        guard let letter = group.kind.modeLetter else { return "" }
        let be = group.visible.count + group.hidden == 1 ? " was " : " were "
        if let verb = modeVerbs[letter] {
            switch group.kind {
            case .modeGranted: return "\(be)\(verb.on)"
            case .modeRevoked: return "\(be)\(verb.off)"
            case .modeBriefly: return "\(be)briefly \(verb.on)"
            default: return "\(be)\(verb.on) again"
            }
        }
        switch group.kind {
        case .modeGranted: return "\(be)given +\(letter)"
        case .modeRevoked: return " lost +\(letter)"
        case .modeBriefly: return " briefly had +\(letter)"
        default: return "\(be)given +\(letter) again"
        }
    }

    // MARK: - Body

    private static func body(
        _ message: Message, base: UIFont, fallback: UIColor,
        highlighter: NickHighlighter? = nil, revealed: Set<Int> = [],
        hiddenUrls: Set<String> = []
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        // The spans the sender colored themselves with mIRC codes — an explicit color wins
        // over nick coloring, so these are off-limits to the mention pass below.
        var mircColored: [NSRange] = []
        // Spoilers are off-limits to BOTH later passes, revealed or not — see `spoilered`.
        var spoilered: [NSRange] = []
        // -1 so the first box becomes 0; see the coalescing note where it's bumped.
        var spoilerOrdinal = -1
        var previousRunWasSpoiler = false
        var previousSpoilerColor: Int?
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

            // A run whose foreground and background match is the IRC spoiler convention: text
            // the sender deliberately made invisible. Hidden, it already renders as a solid box
            // because that is literally what was sent — nothing here has to hide it. Revealed,
            // the text takes the ordinary message colour over a faint wash of the sender's,
            // which is the web's treatment and for its reason: the two commonest spoiler colours
            // are black and white, and either as *text* on a tint of itself is unreadable in the
            // scheme that matches it. A reveal that reveals nothing is the one failure here.
            // ⚠ `explicitFg != nil`, not just `fg == bg`. The palette has 16 entries, so slots
            // 16–98 and mIRC's 99 ("default") resolve to nil — and `\u{3}99,99text\u{3}` satisfies
            // fg == bg while drawing no fill at all. Marking that as a spoiler announced "hidden
            // spoiler" to VoiceOver over text rendered in the clear, and a tap revealed nothing,
            // which is precisely the failure the comment below calls the one we can't have.
            let isSpoiler = explicitFg != nil && run.fg == run.bg
            if isSpoiler {
                // ⚠ `id` is 0 for every ephemeral event (see `Message`), so a reveal keyed by it
                // would be shared by all of them in a buffer, and the redraw — which finds the
                // FIRST row with that id — would flip a different line than the one tapped. An
                // id-less line therefore gets no tap target: still hidden, still kept out of the
                // spoken label, just not openable. Rare (notices, MOTD), and the alternative is
                // a control that acts on the wrong message.
                let revealable = message.id != 0
                // ⚠ Ordinals count spoiler BOXES, not formatting runs. A bold or italic inside a
                // spoiler splits it into several runs, and numbering those would make one visual
                // box take three taps to open — each revealing only the fragment under the
                // finger. Consecutive spoiler runs sharing a colour are one box and one ordinal.
                if !previousRunWasSpoiler || previousSpoilerColor != run.fg {
                    spoilerOrdinal += 1
                }
                let ordinal = spoilerOrdinal
                if revealable { attributes[.spoiler] = ordinal }
                if revealable, revealed.contains(ordinal) {
                    attributes[.foregroundColor] = fallback
                    attributes[.backgroundColor] = Palette.translucent(explicitFg!, alpha: 0.22)
                } else {
                    attributes[.spoilerHidden] = revealable
                        ? "hidden spoiler, double tap to reveal"
                        : "hidden spoiler"
                }
            }
            previousRunWasSpoiler = isSpoiler
            previousSpoilerColor = isSpoiler ? run.fg : nil

            let start = attributed.length
            attributed.append(NSAttributedString(string: run.text, attributes: attributes))
            let range = NSRange(location: start, length: attributed.length - start)
            if explicitFg != nil { mircColored.append(range) }
            if isSpoiler { spoilered.append(range) }
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
            // ⚠ Never inside a spoiler, and not only while it's hidden. A link there would be
            // tappable through the box — opening the secret without revealing it — and it would
            // also underline the run, drawing the shape of hidden text. The web skips URL and
            // nick splitting inside a spoiler for exactly this. The cost is that a URL in a
            // spoiler isn't tappable even once revealed; it's readable, and both clients agree.
            if spoilered.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
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
                    // A nick coloured inside a hidden spoiler would be a visible word in a box
                    // of invisible ones — the shape of the secret, and possibly the secret.
                    || spoilered.contains { NSIntersectionRange($0, range).length > 0 }
                if taken { continue }
                attributed.addAttribute(.foregroundColor, value: hashedColor(text.substring(with: range)), range: range)
            }
        }
        // ⚠⚠ Both deletions happen HERE, last, after every pass that holds ranges into the
        // assembled string — `mircColored`, `spoilered` and `links` are plain arrays and do not
        // move when characters do, so deleting earlier silently mis-styles whatever follows.
        // (The attributed string's OWN attributes survive a deletion; the bookkeeping beside it
        // does not, and that is the trap.) One pass, back to front, so each deletion leaves the
        // earlier offsets untouched.
        //
        // Two jobs:
        //
        // 1. `<https://example.com>` renders WITHOUT its brackets — RFC 3986 Appendix C's
        //    delimiter convention, which Discord borrowed as "link, but no unfurl".
        //    `PreviewSelection` already declines to resolve one; this is the other half, and
        //    without it the convention is visible punctuation that appears to do nothing.
        //    ⚠ This changes rendering for EVERY message, not only previewed ones — the two
        //    settings are off by default and this is the app-wide linkifier. Deliberate, and it
        //    matches the web: the convention is about how a person writes a link.
        //
        // 2. Addresses whose picture is about to stand in for them come out entirely.
        for match in URLMatcher.matches(in: attributed.string).reversed() {
            if hiddenUrls.contains(match.href) {
                // ⚠⚠ The RAW match, not the trimmed one. `PreviewText.UrlSpan.end` deliberately
                // measures the untrimmed match, so the hiding rule counted a trailing `.` or `)`
                // as part of the address when it decided the URL sat against the edge — and
                // deleting only the trimmed span orphans exactly that punctuation. `look at this
                // https://e.test/a.png.` became `look at this .`; a message that was ONLY
                // `https://e.test/shot.png.` collapsed to a body of one full stop, which is not
                // empty, so the blank-body collapse never fired and a line holding a lone `.`
                // was painted above the picture. Delete what the rule measured.
                attributed.deleteCharacters(in: match.delimiters ?? match.raw)
                continue
            }
            guard let delimiters = match.delimiters,
                !spoilered.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { continue }
            attributed.deleteCharacters(
                in: NSRange(location: delimiters.location + delimiters.length - 1, length: 1))
            attributed.deleteCharacters(in: NSRange(location: delimiters.location, length: 1))
        }
        // Trim the ends, which is what makes a body that lost a URL read as a sentence rather
        // than as one with a hole in it: dropping the address from "look at this: <url>" leaves
        // a colon and a trailing space, and dropping it from a message that WAS only a link
        // leaves pure whitespace, which still paints a blank line above the picture.
        if !hiddenUrls.isEmpty {
            let text = attributed.string as NSString
            let firstInk = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
            if firstInk.location == NSNotFound {
                attributed.deleteCharacters(in: NSRange(location: 0, length: attributed.length))
            } else {
                let lastInk = text.rangeOfCharacter(
                    from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
                let tail = lastInk.location + lastInk.length
                if tail < text.length {
                    attributed.deleteCharacters(
                        in: NSRange(location: tail, length: text.length - tail))
                }
                if firstInk.location > 0 {
                    attributed.deleteCharacters(
                        in: NSRange(location: 0, length: firstInk.location))
                }
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

    /// The label on the away marker (#68). The reason rides the same line when there is one —
    /// it's the useful half of the marker for anyone reading their own scrollback later ("was
    /// I at lunch or asleep?"), and it's short by construction.
    static func awayLabel(message: String?) -> String {
        // Tested and shown as the same value. The server trims before it stores one, so this
        // only ever differs on a reason that arrived some other way — and testing one string
        // while printing another is the kind of seam that outlives the reason it was fine.
        let reason = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "You went away" : "You went away: \(reason)"
    }

    /// The label on the back marker. The duration is what makes it worth a row at all — "back"
    /// alone says nothing the reader can't see — so it's dropped only when the two instants
    /// can't be subtracted into one, which is a clock disagreeing with itself rather than a
    /// span. (The away instant itself is always there: `AwayState.since` is non-optional.)
    static func backLabel(awayAt: Date, backAt: Date) -> String {
        guard let gone = awayDuration(from: awayAt, to: backAt) else { return "You're back" }
        return "You're back — away \(gone)"
    }

    /// How long an away lasted, abbreviated and localized ("45m", "1h 5m", "2d 3h").
    ///
    /// Clamped up to a minute rather than shown as "0s": the marker is about a span the reader
    /// missed, and a sub-minute one is better described by its floor than by its precision.
    /// Nil for a backwards interval — that's a clock disagreeing with itself, not a duration.
    private static func awayDuration(from: Date, to: Date) -> String? {
        let seconds = to.timeIntervalSince(from)
        guard seconds >= 0 else { return nil }
        return durationFormatter.string(from: max(60, seconds))
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        // Without this a 65-minute away reads "1h 5m 0s"-style padding; the marker wants the
        // units that carry information and nothing else.
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

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
        isSelf ? Palette.fg : hashedColor(nick ?? "")
    }

    /// The nick palette as trait-keyed colors, built once and indexed by the djb2 hash. A
    /// fixed set (dark hex + light variant per slot), so there's no reason to re-parse the
    /// hex and allocate a dynamic UIColor on every lookup.
    private nonisolated static let nickColors: [UIColor] =
        zip(IRCPalette.nick, IRCPalette.nickLight).map { Palette.dynamicHex(dark: $0, light: $1) }

    /// The mIRC palette as trait-keyed colors, built once. Sixteen entries, no gaps.
    private nonisolated static let mircColors: [UIColor] = zip(IRCPalette.mirc, IRCPalette.mircLight)
        .map { Palette.dynamicHex(dark: $0, light: $1) }

    /// A stable color for a name, from the shared nick palette. Nicks and network names
    /// both run through it, so the same name is always the same color and different ones
    /// are told apart. Dynamic: the Monokai hex in dark mode, its light variant in light.
    static func hashedColor(_ name: String) -> UIColor {
        nickColors[NickColor.index(for: name)]
    }

    /// mIRC index → color. Every slot in range is a literal from the palette; 16+ don't render.
    ///
    /// There is no theme-slot branch any more, and there must not be one again — see the ⚠ on
    /// `IRCPalette.mirc`. A run can carry its own background, so a slot that resolved against the
    /// theme was being resolved against the wrong surface.
    private nonisolated static func mircColor(_ index: Int) -> UIColor? {
        guard index >= 0, index < mircColors.count else { return nil }
        return mircColors[index]
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

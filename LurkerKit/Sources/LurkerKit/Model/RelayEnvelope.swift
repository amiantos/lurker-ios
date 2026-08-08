// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

// Relay/bridge-bot message parsing (#277), ported from the web's `shared/parseRelay.ts`.
//
// A relay bot posts other people's messages on IRC — bridged in from Discord, Telegram, Matrix,
// another network — wrapped in a fixed envelope like `[Discord] <alice> hello`. When the user
// marks the bot's nick as a relay, the client parses that envelope and attributes the line to the
// embedded speaker instead of to the bot.
//
// Parsing is template-driven, not free regex: a template is literal text with `{source}`,
// `{nick}` and `{message}` placeholders. The literals are escaped and the placeholders compiled
// to capture groups, so a user-supplied pattern can't inject regex or trigger catastrophic
// backtracking. `{nick}` and `{message}` are required; `{source}` is optional.
//
// ⚠ That escaping is load-bearing and easy to lose on this side of the port: `NSRegularExpression`
// will happily accept whatever a user types, so a pattern reaching it unescaped would be a live
// regex — and one written into the message-render path, where it runs against every line a marked
// bot has ever said. Nothing here may pass a raw template to a regex initializer.

/// A relay bot's envelope, taken apart.
public struct RelayParse: Equatable, Sendable {
    /// The `[source]` tag (e.g. "Discord"), or nil when the template carries no `{source}`.
    public let source: String?
    /// The embedded speaker's nick. Never empty on a successful parse.
    public let nick: String
    /// The message itself, envelope stripped, with its own mIRC formatting intact.
    public let text: String

    public init(source: String?, nick: String, text: String) {
        self.source = source
        self.nick = nick
        self.text = text
    }
}

/// One compiled template: the anchored regex, plus what each of its capture groups holds.
///
/// A value rather than something cached globally. Compiling is the expensive half, so the cost is
/// paid once per *list* of messages by `RelayBotSet.reattributing`, which builds these and reuses
/// them across every row it walks — the same eager-compile trade `IgnoreSet` makes, and the reason
/// this type needs no cache and therefore no shared mutable state.
public struct RelayTemplate {
    /// Which captured value a group holds, in left-to-right order.
    enum Slot {
        case source
        case nick
        case message

        /// The capture group a placeholder compiles to.
        ///
        /// `{message}` is greedy to the end of the line; `{nick}` and `{source}` are lazy so the
        /// literals that follow them (`>`, `]`, a space) bound the match. A nick can't contain
        /// whitespace; a source tag might, so it's the permissive one.
        var group: String {
            switch self {
            case .source: #"(.+?)"#
            case .nick: #"(\S+?)"#
            case .message: #"(.*)"#
            }
        }
    }

    let regex: NSRegularExpression
    let slots: [Slot]
}

public enum RelayEnvelope {

    /// Built-in formats, tried in order. The bracketed-source form first because it's the common
    /// bridge shape (matterbridge, the ##videogames relay on Libera, most operator-run bots); the
    /// bare `<nick>` form second for relays that don't prefix a platform tag. A marked bot whose
    /// format matches neither needs a custom template.
    public static let defaultPatterns = ["[{source}] <{nick}> {message}", "<{nick}> {message}"]

    /// Channel-membership prefix glyphs (PREFIX in ISUPPORT). A relay bot often carries the
    /// speaker's status from the source channel — `<+FAST>` — but those glyphs aren't part of the
    /// nick, so a leading run of them is dropped. Safe because a real nick can't begin with one.
    private static let memberPrefixes: Set<Character> = ["~", "&", "@", "%", "+"]

    /// The compiled built-ins, built once. Every marked bot with no custom pattern shares them.
    private nonisolated static let defaultTemplates: [RelayTemplate] =
        defaultPatterns.compactMap { compile($0) }

    /// The templates to try for a bot whose stored pattern is `pattern`. An empty or
    /// whitespace-only pattern means "use the built-ins", which is what the server stores for a
    /// bot marked without one.
    ///
    /// A custom pattern that fails to compile yields *no* templates rather than falling back to
    /// the defaults: the user asked for a specific shape, and quietly re-attributing by some other
    /// rule would be the client inventing a speaker. The line just renders as the bot said it.
    public static func templates(for pattern: String?) -> [RelayTemplate] {
        let custom = (pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return defaultTemplates }
        return [compile(custom)].compactMap { $0 }
    }

    /// Compile a template into an anchored regex plus the slot order of its capture groups.
    ///
    /// Returns nil when the template lacks the required `{nick}`/`{message}` placeholders, or
    /// produces a regex the engine won't take.
    ///
    /// Anchored with `\A`/`\z` rather than `^`/`$`: ICU's `$` also matches *before* a final line
    /// terminator, where JavaScript's (without `m`) does not — so the two clients would disagree
    /// about a body with a trailing newline. These two anchors mean exactly end-of-input in both.
    public static func compile(_ template: String) -> RelayTemplate? {
        var slots: [RelayTemplate.Slot] = []
        var pattern = ""
        var literal = ""
        var index = template.startIndex
        while index < template.endIndex {
            if let (slot, next) = placeholder(in: template, at: index) {
                pattern += NSRegularExpression.escapedPattern(for: literal)
                literal = ""
                slots.append(slot)
                pattern += slot.group
                index = next
            } else {
                literal.append(template[index])
                index = template.index(after: index)
            }
        }
        pattern += NSRegularExpression.escapedPattern(for: literal)
        guard slots.contains(.nick), slots.contains(.message) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"\A"# + pattern + #"\z"#) else { return nil }
        return RelayTemplate(regex: regex, slots: slots)
    }

    /// The placeholder starting at `index`, and where it ends — or nil when the text there is
    /// ordinary literal. Hand-scanned rather than found with a regex of its own so that the one
    /// regex in this file is the one built out of escaped input.
    private static func placeholder(
        in template: String, at index: String.Index
    ) -> (RelayTemplate.Slot, String.Index)? {
        for (name, slot) in [("{source}", RelayTemplate.Slot.source), ("{nick}", .nick), ("{message}", .message)] {
            guard let end = template.index(index, offsetBy: name.count, limitedBy: template.endIndex),
                  template[index..<end] == name
            else { continue }
            return (slot, end)
        }
        return nil
    }

    /// Parse a relay bot's message body into its embedded speaker and text, trying `templates` in
    /// order. Nil when none matches — the caller then renders the line unchanged, attributed to
    /// the bot, which is the honest fallback for a bot whose format we don't know.
    public static func parse(_ body: String?, templates: [RelayTemplate]) -> RelayParse? {
        guard let body, !body.isEmpty else { return nil }
        // Relay bots colour the source tag and nick (mIRC \x03 codes, bold, …), and those control
        // characters sit right inside the [source]/<nick> being matched — so formatting comes off
        // before matching or the envelope never lines up. The source and nick come back plain (the
        // nick gets re-coloured by the renderer anyway); the message keeps its own formatting,
        // recovered below by mapping the match back onto the raw body.
        let stripped = IRCFormatting.strip(body)
        let ns = stripped as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for template in templates {
            guard let match = template.regex.firstMatch(in: stripped, options: [], range: whole) else { continue }
            var source: String?
            var nick = ""
            var text = ""
            var textStart: Int?
            for (position, slot) in template.slots.enumerated() {
                let range = match.range(at: position + 1)
                let value = range.location == NSNotFound ? "" : ns.substring(with: range)
                switch slot {
                case .source: source = value
                case .nick: nick = value
                case .message:
                    text = value
                    textStart = range.location == NSNotFound ? nil : range.location
                }
            }
            // Drop any channel-membership prefix the bot carried into the nick, so the speaker
            // reads as `FAST`, not `+FAST` — and so Reply and Copy target the real nick.
            nick = String(nick.drop { memberPrefixes.contains($0) })
            if nick.isEmpty { continue }
            // Recover the message's original formatting. `{message}` is the trailing group in
            // every sane template, so map where its stripped form begins back into the raw body
            // and slice from there. (A custom template that puts `{message}` elsewhere falls back
            // to the plain text — there's no single raw slice that would answer.)
            var displayText = text
            if template.slots.last == .message, let textStart {
                let rawStart = IRCFormatting.rawIndex(in: body, visibleOffset: textStart)
                displayText = (body as NSString).substring(from: rawStart)
            }
            return RelayParse(source: source, nick: nick, text: displayText)
        }
        return nil
    }

    /// Convenience for a single stored pattern — what a test or a one-off lookup wants. The
    /// render path goes through `RelayBotSet.reattributing`, which compiles once per list instead.
    public static func parse(_ body: String?, pattern: String? = nil) -> RelayParse? {
        parse(body, templates: templates(for: pattern))
    }
}

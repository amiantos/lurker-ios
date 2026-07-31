// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One irssi-style ignore rule, as the server stores and ships it (lurker #301).
///
/// A rule AND-s together the optional dimensions it carries — **who** (`mask`), **where**
/// (`channels`), **what** (`pattern`), **which** (`levels`) — so an unset dimension matches
/// everything. `isExcept` inverts the whole thing into a whitelist entry (longest mask wins),
/// and `expiresAt` lapses it.
///
/// The rules themselves are server-authoritative: `/ignore` here (#86) and on the web both
/// *ask*, and the list only changes when the server fans `ignore-list-updated` back. Nothing
/// on this client mutates a rule locally, which is what makes a rule made anywhere apply
/// everywhere.
public struct IgnoreRule: Equatable, Sendable {
    /// The server's row id, and how `/unignore <n>` addresses a rule (#86): the listed index
    /// resolves to this. Zero for a rule this client has just parsed off a command line and
    /// not yet sent — identity is the server's to assign, and it arrives on the echo.
    public let id: Int
    /// Who this rule is about: nil or `*` means anyone, a bare token is a nick glob, and a
    /// `nick!user@host` form globs each part. See `IgnoreMatch.maskMatcher`.
    public let mask: String?
    /// Which buffers it applies in. Nil/empty means every buffer on the rule's network(s);
    /// entries are globs matched case-insensitively against the target.
    public let channels: [String]?
    /// A content pattern the message body must match, or nil for "any body".
    public let pattern: String?
    public let patternKind: IgnorePatternKind
    /// Canonical level tokens (`ALL`, `PUBLIC`, `JOINS`, `NOHIGHLIGHT`, …). The server
    /// canonicalizes aliases before storing, so these arrive in `IgnoreLevels`' vocabulary and
    /// this client never has to parse irssi's singular/plural spellings.
    public let levels: [String]
    /// Inverts the rule into a whitelist entry: a matching `-except` with a *longer* mask
    /// beats the hide/mute it would otherwise take.
    public let isExcept: Bool
    /// When the rule lapses, parsed at the wire boundary. A lapsed rule never matches — the
    /// server sweeps expired rows every minute, but expiry is honored here too so a rule stops
    /// biting the instant it runs out rather than up to a minute later.
    public let expiresAt: Date?

    public init(
        id: Int = 0,
        mask: String? = nil,
        channels: [String]? = nil,
        pattern: String? = nil,
        patternKind: IgnorePatternKind = .substr,
        levels: [String] = ["ALL"],
        isExcept: Bool = false,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.mask = mask
        self.channels = channels
        self.pattern = pattern
        self.patternKind = patternKind
        self.levels = levels
        self.isExcept = isExcept
        self.expiresAt = expiresAt
    }

    /// One line naming every dimension the rule constrains — `*zzz*  [global]  NICKS  #chan
    /// "spam"  [except]  (expires Today at 4:15 PM)` — for the `/ignore` listing and the
    /// confirmations `/ignore`/`/unignore` print (#86).
    ///
    /// `global` is the rule's *scope*, which isn't on the rule: the server keeps globals and
    /// per-network rules in separate buckets and the row is identical in both, so the caller
    /// (which knows which bucket it read) supplies it. See `IgnoreSet.listing(for:)`.
    ///
    /// Mirrors the web's `summarizeIgnoreEntry` field for field, so the same rule reads the
    /// same on both clients — except the expiry, which is a wall-clock stamp for a person to
    /// read rather than the web's raw ISO string.
    public func summary(global: Bool) -> String {
        var parts = [mask ?? "*"]
        if global { parts.append("[global]") }
        if !levels.isEmpty { parts.append(levels.joined(separator: ",")) }
        if let channels, !channels.isEmpty { parts.append(channels.joined(separator: ",")) }
        if let pattern, !pattern.isEmpty {
            parts.append(patternKind == .regex ? "/\(pattern)/" : "\"\(pattern)\"")
        }
        if isExcept { parts.append("[except]") }
        if let expiresAt { parts.append("(expires \(ExpiryText.of(expiresAt)))") }
        return parts.joined(separator: "  ")
    }
}

/// When a rule lapses, as a person reads it: local time, short, and relative where the locale
/// has a word for the day ("Today at 4:15 PM").
///
/// Built once rather than per call — a `DateFormatter` is expensive to construct, and a rule
/// listing formats one per line. The locale is `autoupdatingCurrent` because a `static let`
/// outlives a region change, the same care `MessageRenderer.dayFormatter` takes for the day
/// dividers.
private enum ExpiryText {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static func of(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

/// How a rule's `pattern` is matched against a message body. Mirrors the server's
/// `patternKindToTextKind`, including its fallback: anything unrecognized is a substring
/// match, which is the least surprising reading of a pattern we can't classify.
public enum IgnorePatternKind: String, Sendable {
    /// Case-insensitive substring — irssi's default `-pattern`.
    case substr
    /// Whole-word match of a literal (word-boundary anchored).
    case full
    /// A raw regular expression.
    case regex

    public static func from(_ raw: String?) -> IgnorePatternKind {
        guard let raw else { return .substr }
        if raw == "plain" { return .full } // the highlight engine's alias for the same thing
        return IgnorePatternKind(rawValue: raw) ?? .substr
    }
}

/// The ignore-level vocabulary (lurker #301), ported from `shared/ignoreLevels.ts`.
///
/// Two halves, and until #86 this client only needed one. **Matching** needs the event types
/// each canonical token covers — rules arrive off the wire already canonicalized, so the
/// matcher never sees an alias. **Authoring** needs the rest: `/ignore bob nohilight` is a
/// person typing irssi's spelling, and the command line is parsed here now, so the alias table
/// and the canonical order have to be here too. The server canonicalizes again on insert; that
/// they agree is what keeps the stored CSV identical whichever client wrote the rule.
public enum IgnoreLevels {

    /// Level token → the event types it covers. `PUBLIC` and `MSGS` split `message` by
    /// channel-vs-DM, which is what `dm` disambiguates; every other level ignores it.
    ///
    /// `ALL` and the modifier levels are absent because they aren't event-type tokens — the
    /// matcher handles them. `CTCPS` is accepted and maps to nothing: Lurker never persists
    /// CTCP as a type, a documented no-op the server carries too.
    static let defs: [String: (types: Set<EventType>, dm: Bool?)] = [
        "PUBLIC": ([.message], false),
        "MSGS": ([.message], true),
        "NOTICES": ([.notice], nil),
        "ACTIONS": ([.action], nil),
        "JOINS": ([.join], nil),
        "PARTS": ([.part], nil),
        // Host changes ride with QUITS rather than getting their own level: a chghost IS what
        // a client without the cap would have shown as a quit/rejoin pair, so someone who
        // silenced a nick's quits already expects these gone too (lurker #591).
        "QUITS": ([.quit, .chghost], nil),
        "NICKS": ([.nick], nil),
        "KICKS": ([.kick], nil),
        "MODES": ([.mode], nil),
        "TOPICS": ([.topic], nil),
        "CTCPS": ([], nil),
    ]

    /// What an `ALL` rule covers — everything with a sender to ignore, so the system/self
    /// rows (motd, error, usermode, names, the app's own system lines) are deliberately out.
    ///
    /// Listed literally rather than derived as the union of `defs`, which today it happens to
    /// equal. The two answer different questions and are free to diverge: `defs` maps the
    /// tokens a user can *name*, and `CTCPS` is already in it mapping to nothing. Deriving
    /// would silently couple "what ALL means" to that vocabulary. `shared/ignoreLevels.ts`
    /// spells out its `ALL_TYPES` for the same reason, so the two stay comparable by eye.
    static let all: Set<EventType> = [
        .message, .action, .notice, .join, .part, .quit, .nick, .kick, .mode, .topic, .chghost,
    ]

    /// The types a highlight can land on, and therefore the only ones `NOHIGHLIGHT` bounds.
    static let highlightable: Set<EventType> = [.message, .action]

    /// The "modifier" levels: they don't name a type to hide, they change how a still-visible
    /// message is treated. Filtered out of the hide-level set so a modifier-only rule keeps
    /// `hides` false (lurker #301 for NOHIGHLIGHT, #359 for the two mute rungs).
    static let modifiers: Set<String> = ["NOHIGHLIGHT", "NOUNREAD", "NONOTIFY"]

    /// What an `ALL` token expands to before a subtractive level is taken off it
    /// (`ALL -PUBLIC`, irssi's form). Derived from `defs` — the tokens a user can *name* — so
    /// it can't drift from the vocabulary, and deliberately not from `all`, which answers the
    /// different question of which event types `ALL` hides. Unordered, because the result goes
    /// through `canonicalize` before anyone sees it.
    static var concrete: [String] { Array(defs.keys) }

    /// alias → canonical token, accepting irssi's singular/plural and legacy spellings. The
    /// only place a level token is spelled more than one way; everything downstream of
    /// `canonical(_:)` is in canonical form.
    static let aliases: [String: String] = [
        "PUBLIC": "PUBLIC", "PUBLICS": "PUBLIC",
        "MSG": "MSGS", "MSGS": "MSGS",
        "NOTICE": "NOTICES", "NOTICES": "NOTICES",
        "ACTION": "ACTIONS", "ACTIONS": "ACTIONS",
        "JOIN": "JOINS", "JOINS": "JOINS",
        "PART": "PARTS", "PARTS": "PARTS",
        "QUIT": "QUITS", "QUITS": "QUITS",
        "NICK": "NICKS", "NICKS": "NICKS",
        "KICK": "KICKS", "KICKS": "KICKS",
        "MODE": "MODES", "MODES": "MODES",
        "TOPIC": "TOPICS", "TOPICS": "TOPICS",
        "CTCP": "CTCPS", "CTCPS": "CTCPS",
        "ALL": "ALL",
        // Lurker calls them "highlights", so NOHIGHLIGHT(S) is canonical; irssi's
        // NOHILIGHT/NOHILITE spellings are accepted as aliases.
        "NOHIGHLIGHT": "NOHIGHLIGHT", "NOHIGHLIGHTS": "NOHIGHLIGHT",
        "NOHILIGHT": "NOHIGHLIGHT", "NOHILITE": "NOHIGHLIGHT",
        // The mute rungs (lurker #359). NOUNREAD suppresses the plain-unread signal (≙ irssi's
        // NO_ACT); NONOTIFY suppresses toast/push/sound.
        "NOUNREAD": "NOUNREAD", "NOUNREADS": "NOUNREAD",
        "NO_ACT": "NOUNREAD", "NOACT": "NOUNREAD", "NOACTIVITY": "NOUNREAD",
        "NONOTIFY": "NONOTIFY", "NONOTIFYS": "NONOTIFY",
        "NONOTIFICATION": "NONOTIFY", "NONOTIFICATIONS": "NONOTIFY",
    ]

    /// The order a rule's levels are stored and listed in. Deterministic because the server
    /// dedupes rules by comparing the stored CSV *as a string*: two clients that canonicalize
    /// the same set into different orders would write the same rule twice.
    static let canonicalOrder = [
        "ALL", "PUBLIC", "MSGS", "NOTICES", "ACTIONS", "JOINS", "PARTS", "QUITS", "NICKS",
        "KICKS", "MODES", "TOPICS", "CTCPS", "NOHIGHLIGHT", "NOUNREAD", "NONOTIFY",
    ]

    /// Resolve one token to its canonical form, or nil if it names no level. Nil is what tells
    /// the parser a token is a mask or a flag rather than a level, so "unknown" has to be
    /// answerable rather than defaulted.
    static func canonical(_ token: String) -> String? {
        aliases[token.uppercased()]
    }

    /// Canonicalize a level list: resolve aliases, drop unknowns, dedupe, and order.
    static func canonicalize(_ levels: [String]) -> [String] {
        let set = Set(levels.compactMap(canonical))
        return canonicalOrder.filter(set.contains)
    }
}

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
/// Read-only here on purpose. Authoring rules is `/ignore` on the web (and the settings pane
/// it feeds); this client only *honors* what the account already has, which is what makes a
/// rule made anywhere apply everywhere.
public struct IgnoreRule: Equatable, Sendable {
    /// The server's row id. Nothing on this client addresses a rule by id yet — it's carried
    /// because it's the rule's identity, and a list diffed without one can only compare
    /// contents.
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
/// Only the half this client needs: which event types each level token covers. The alias
/// table (irssi's `PUBLICS`/`NOHILITE`/`NO_ACT` spellings) lives on the server, which
/// canonicalizes before storing — so a rule always arrives here spelled one way.
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
}

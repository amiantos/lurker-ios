// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The irssi-style ignore matcher (lurker #301), ported from `shared/ignoreMatch.ts`.
///
/// The server evaluates the same rules at insert time — it stamps `from_ignored` and drops a
/// highlight a `NOHIGHLIGHT` rule covers — but that stamp is frozen at the moment the line
/// arrived. Filtering *again* at render time is what makes a rule retroactive in both
/// directions: adding one hides backlog the server had already sent, and removing one brings
/// those lines back without a refetch. That's why this exists client-side at all, and why it
/// has to agree with the server's copy exactly rather than approximate it.
public enum IgnoreMatch {

    // MARK: - Glob

    /// Translate a glob into an anchored regex, mirroring the shared matcher's translation
    /// exactly: `*` and `?` are the only wildcards, every other regex metacharacter is escaped.
    static func globToRegex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        var source = "^"
        for character in pattern {
            switch character {
            case "*": source += ".*"
            case "?": source += "."
            case ".", "+", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\":
                source += "\\\(character)"
            default: source.append(character)
            }
        }
        source += "$"
        return try? NSRegularExpression(
            pattern: source, options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    /// Split a mask into its three globbable parts, defaulting each missing one to `*`.
    ///
    /// The three shapes a mask can take, and what each leaves unconstrained:
    /// `bob` (nick only), `*@host` / `user@host` (no `!`, so the part before `@` is the
    /// *user*), and the full `nick!user@host`.
    static func splitMask(_ mask: String) -> (nick: String, user: String, host: String) {
        var nick = "*"
        var user = "*"
        var host = "*"
        var pre = Substring(mask)
        let at = mask.firstIndex(of: "@")
        if let at {
            pre = mask[mask.startIndex..<at]
            let rest = mask[mask.index(after: at)...]
            host = rest.isEmpty ? "*" : String(rest)
        }
        if let bang = pre.firstIndex(of: "!") {
            let head = pre[pre.startIndex..<bang]
            let tail = pre[pre.index(after: bang)...]
            nick = head.isEmpty ? "*" : String(head)
            user = tail.isEmpty ? "*" : String(tail)
        } else if at != nil {
            user = pre.isEmpty ? "*" : String(pre)
        } else {
            nick = pre.isEmpty ? "*" : String(pre)
        }
        return (nick, user, host)
    }

    /// How a compiled rule decides whether a sender is the one it's about.
    ///
    /// The nick half is always case-insensitive (IRC nicks are); the user and host halves are
    /// not, matching the shared matcher — a hostmask is closer to a literal address.
    enum MaskMatcher {
        /// No mask, or `*`: anyone.
        case anyone
        /// A bare token with no wildcards in it — `/ignore bob`, far and away the commonest
        /// rule there is. Held as an already-lowered literal so the per-row cost is a string
        /// compare rather than an ICU regex execution; the glob cases below are what the
        /// wildcards are for.
        case literalNick(String)
        /// A bare token — a nick glob, and nothing said about the hostmask.
        case nick(NSRegularExpression)
        /// A `nick!user@host` form, each part globbed independently.
        case identity(
            nick: NSRegularExpression,
            user: NSRegularExpression,
            host: NSRegularExpression,
            /// Whether the user and host halves were both `*`. That's what decides the
            /// hostmask-less case: a rule that constrains only the nick still matches a
            /// sender whose mask the server never sent, but one that names a user or host
            /// cannot be judged without one.
            hostmaskOptional: Bool
        )

        func matches(nick: String?, userhost: String?) -> Bool {
            switch self {
            case .anyone:
                return true
            case .literalNick(let lowered):
                guard let nick else { return false }
                return nick.lowercased() == lowered
            case .nick(let regex):
                guard let nick else { return false }
                return regex.matches(nick)
            case .identity(let nickRegex, let userRegex, let hostRegex, let hostmaskOptional):
                guard let nick, nickRegex.matches(nick) else { return false }
                guard let userhost else { return hostmaskOptional }
                // The wire form is `nick!user@host`; the `@` is looked for *after* the `!` so
                // an `@` inside a nick can't split it in the wrong place.
                guard let bang = userhost.firstIndex(of: "!") else { return hostmaskOptional }
                let afterBang = userhost.index(after: bang)
                guard let at = userhost[afterBang...].firstIndex(of: "@") else {
                    return hostmaskOptional
                }
                let user = String(userhost[afterBang..<at])
                let host = String(userhost[userhost.index(after: at)...])
                return userRegex.matches(user) && hostRegex.matches(host)
            }
        }
    }

    /// A rule's buffer scope: every buffer, or a set of case-insensitive target globs.
    enum ChannelMatcher {
        case any
        /// Wildcard-free targets — the shape every mute rule and most `-channels` scopes take.
        /// Pre-lowered literals, so scoping a rule to a channel costs a string compare per
        /// buffer rather than an ICU execution.
        case literals([String])
        case globs([NSRegularExpression])

        func matches(_ target: String) -> Bool {
            switch self {
            case .any: return true
            case .literals(let lowered):
                guard !target.isEmpty else { return false }
                let folded = target.lowercased()
                return lowered.contains(folded)
            case .globs(let regexes):
                guard !target.isEmpty else { return false }
                return regexes.contains { $0.matches(target) }
            }
        }
    }

    /// A rule's content pattern.
    enum TextMatcher {
        /// No pattern: any body.
        case any
        /// Case-insensitive substring, holding the already-lowercased needle.
        case substring(String)
        case regex(NSRegularExpression)
        /// A pattern that wouldn't compile. It matches nothing, so the rule is inert — which
        /// drops one broken rule rather than throwing away the whole set.
        case never

        /// `lowered` is `text` case-folded, computed once per event by the caller rather than
        /// once per rule here — it's a full Unicode-folding allocation, and a message matched
        /// against several substring rules would otherwise pay for it several times over.
        func matches(_ text: String, lowered: String) -> Bool {
            switch self {
            case .any: return true
            case .substring(let needle): return lowered.contains(needle)
            case .regex(let regex): return regex.matches(text)
            case .never: return false
            }
        }
    }

    /// One rule with its globs and patterns compiled. Built once per list change, then read on
    /// every rendered row.
    ///
    /// `@unchecked Sendable` because `NSRegularExpression` isn't marked `Sendable` but is
    /// documented thread-safe, and every stored property here is a `let` fixed at compile time.
    struct CompiledRule: @unchecked Sendable {
        let isExcept: Bool
        /// The mask's length, which is the whole of "longest mask wins": a more specific mask
        /// is a longer string, so an `-except` only beats a hide it's more specific than.
        let maskLength: Int
        let expiresAt: Date?
        /// Whether the rule carries any hide levels at all (a modifier-only rule doesn't).
        let hides: Bool
        let nohilight: Bool
        let nounread: Bool
        let nonotify: Bool
        let hasPattern: Bool
        /// Whether the mask matches everyone (absent or `*`) — what `channelMutesUnread`
        /// requires, since a per-sender mute can't speak for a whole buffer's badge.
        let anyNick: Bool
        let hasAll: Bool
        /// The non-modifier levels, resolved to the types they cover. Unknown tokens are
        /// dropped at compile time rather than checked for on every row.
        let hideDefs: [(types: Set<EventType>, dm: Bool?)]
        let mask: MaskMatcher
        let channels: ChannelMatcher
        let text: TextMatcher

        /// Whether this rule hides an event of `type`. `ALL` covers the whole ignorable set;
        /// otherwise each level names its types, and `PUBLIC`/`MSGS` additionally split on
        /// channel-vs-DM.
        func hidesLevel(_ type: EventType, isDm: Bool) -> Bool {
            if hasAll { return IgnoreLevels.all.contains(type) }
            for def in hideDefs where def.types.contains(type) {
                if def.dm == nil || def.dm == isDm { return true }
            }
            return false
        }

        func isLive(at now: Date) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt > now
        }
    }

    /// A compiled rule list plus the one fact the evaluator needs about it as a whole.
    struct CompiledSet: Sendable {
        let rules: [CompiledRule]
        /// Whether any rule carries a content pattern. When none does, the URL/formatting
        /// strip is skipped entirely — which is most accounts, on every rendered row.
        let hasPattern: Bool

        var isEmpty: Bool { rules.isEmpty }

        /// Concatenate two sets — how a network's effective rules are formed from the global
        /// bucket and its own. The short-circuit is for the common account that has only
        /// network rules or only global ones, and keeps the union free of a copy there.
        static func merged(_ first: CompiledSet, _ second: CompiledSet) -> CompiledSet {
            if first.isEmpty { return second }
            return CompiledSet(
                rules: first.rules + second.rules,
                hasPattern: first.hasPattern || second.hasPattern
            )
        }
    }

    // MARK: - Compile

    static func compile(_ rules: [IgnoreRule]) -> CompiledSet {
        var compiled: [CompiledRule] = []
        var hasPattern = false
        for rule in rules {
            let hideLevels = rule.levels.filter { !IgnoreLevels.modifiers.contains($0) }
            let pattern = rule.pattern.flatMap { $0.isEmpty ? nil : $0 }
            if pattern != nil { hasPattern = true }
            compiled.append(
                CompiledRule(
                    isExcept: rule.isExcept,
                    maskLength: rule.mask?.count ?? 0,
                    expiresAt: rule.expiresAt,
                    hides: !hideLevels.isEmpty,
                    nohilight: rule.levels.contains("NOHIGHLIGHT"),
                    nounread: rule.levels.contains("NOUNREAD"),
                    nonotify: rule.levels.contains("NONOTIFY"),
                    hasPattern: pattern != nil,
                    anyNick: rule.mask == nil || rule.mask == "*",
                    hasAll: hideLevels.contains("ALL"),
                    hideDefs: hideLevels.compactMap { IgnoreLevels.defs[$0] },
                    mask: maskMatcher(rule.mask),
                    channels: channelMatcher(rule.channels),
                    text: textMatcher(pattern, kind: rule.patternKind)
                )
            )
        }
        return CompiledSet(rules: compiled, hasPattern: hasPattern)
    }

    /// Whether a glob has any wildcard in it at all. A pattern without one is a literal, and
    /// compiling it to `^literal$` only to run ICU over it per row is the single most
    /// avoidable cost on this path — `/ignore bob` is the rule people actually write.
    private static func hasWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    static func maskMatcher(_ mask: String?) -> MaskMatcher {
        guard let mask, !mask.isEmpty, mask != "*" else { return .anyone }
        guard mask.contains("!") || mask.contains("@") else {
            guard hasWildcard(mask) else { return .literalNick(mask.lowercased()) }
            guard let regex = globToRegex(mask, caseInsensitive: true) else { return .anyone }
            return .nick(regex)
        }
        let parts = splitMask(mask)
        guard let nick = globToRegex(parts.nick, caseInsensitive: true),
              let user = globToRegex(parts.user, caseInsensitive: false),
              let host = globToRegex(parts.host, caseInsensitive: false)
        else { return .anyone }
        return .identity(
            nick: nick, user: user, host: host,
            hostmaskOptional: parts.user == "*" && parts.host == "*"
        )
    }

    static func channelMatcher(_ channels: [String]?) -> ChannelMatcher {
        guard let channels, !channels.isEmpty else { return .any }
        guard channels.contains(where: hasWildcard) else {
            return .literals(channels.map { $0.lowercased() })
        }
        let regexes = channels.compactMap { globToRegex($0, caseInsensitive: true) }
        return regexes.isEmpty ? .any : .globs(regexes)
    }

    /// A word character for whole-word matching: any Unicode letter or number, or underscore.
    ///
    /// Deliberately not `\w`, which is ASCII-only in the web's engine and would treat `ł` as a
    /// boundary — making the keyword `em` match inside `zrozumiałem`. ICU's `\w` is
    /// Unicode-aware by default, so the two engines would *disagree* if each used its own
    /// shorthand; spelling the class out is what keeps them identical.
    private static let wordCharacter = "[\\p{L}\\p{N}_]"
    private static let nonWordCharacter = "[^\\p{L}\\p{N}_]"

    static func textMatcher(_ pattern: String?, kind: IgnorePatternKind) -> TextMatcher {
        guard let pattern, !pattern.isEmpty else { return .any }
        switch kind {
        case .substr:
            return .substring(pattern.lowercased())
        case .regex:
            // A user-authored regex compiles as written. One that doesn't compile makes its
            // rule inert rather than taking the rest of the set down with it.
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { return .never }
            return .regex(regex)
        case .full:
            // The leading boundary is a *consuming* negated class rather than a lookbehind,
            // matching the web (whose engine has to run on Safari < 16.4). Consuming it is
            // harmless here — nothing reads the match's position, only whether there was one.
            let body = NSRegularExpression.escapedPattern(for: pattern)
            let source = "(?:^|\(nonWordCharacter))(?:\(body))(?!\(wordCharacter))"
            guard let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
            else { return .never }
            return .regex(regex)
        }
    }

    /// Normalize a body for pattern matching: drop IRC formatting codes, then blank out URLs.
    ///
    /// The formatting strip is not cosmetic. A colored word arrives as `\u{03}04QUACK`, which
    /// leaves the digit `4` glued to the front of QUACK — enough to break a whole-word match
    /// and let a rule silently miss the line it was written for.
    static func cleanForMatch(_ text: String) -> String {
        URLMatcher.blanked(IRCFormatting.strip(text))
    }

    // MARK: - Evaluate

    /// Evaluate `input` against a compiled set.
    ///
    /// Every verdict is decided the same way: the longest matching mask wins, and an
    /// `-except` at that length or longer vetoes it. The three are tracked independently
    /// because a rule can carry hide levels and modifiers at once, and an `-except` written
    /// against one shouldn't quietly lift the others.
    ///
    /// `now` is a parameter rather than a `Date()` inside so expiry is testable without
    /// waiting for it.
    static func evaluate(
        _ compiled: CompiledSet,
        _ input: IgnoreInput,
        now: Date = Date()
    ) -> IgnoreVerdict {
        guard !compiled.isEmpty else { return .visible }
        // Only pay for the strip when some rule actually reads the text — which, for most
        // accounts, is never: a content pattern is the rarest thing a rule carries.
        let text = compiled.hasPattern && !input.text.isEmpty ? cleanForMatch(input.text) : ""
        let lowered = text.isEmpty ? "" : text.lowercased()

        var bestHide = -1, bestHideExcept = -1
        var bestNohilight = -1, bestNohilightExcept = -1
        var bestNonotify = -1, bestNonotifyExcept = -1

        for rule in compiled.rules {
            guard rule.isLive(at: now) else { continue }
            // Computed once and shared by all three verdicts below: they ask the same
            // question of the same rule, and it's a set lookup per level token.
            let levelHit = rule.hides && rule.hidesLevel(input.type, isDm: input.isDm)
            let hideApplies = levelHit
            // NOHIGHLIGHT only sensibly applies to the types a highlight can land on; when the
            // rule also carries hide levels it's bounded to those as well.
            let nohilightApplies = rule.nohilight
                && IgnoreLevels.highlightable.contains(input.type)
                && (rule.hides ? levelHit : true)
            // NONOTIFY is NOT bounded to highlightable types. A channel's notify-always can
            // fire a notification for any event — a notice, a join — so muting a channel or
            // network has to veto those too ("quietest wins", lurker #359). Bounded only by
            // the rule's own hide levels, if it has any.
            let nonotifyApplies = rule.nonotify && (rule.hides ? levelHit : true)
            guard hideApplies || nohilightApplies || nonotifyApplies else { continue }
            guard rule.mask.matches(nick: input.nick, userhost: input.userhost) else { continue }
            guard rule.channels.matches(input.target) else { continue }
            guard rule.text.matches(text, lowered: lowered) else { continue }

            if hideApplies {
                if rule.isExcept {
                    bestHideExcept = max(bestHideExcept, rule.maskLength)
                } else {
                    bestHide = max(bestHide, rule.maskLength)
                }
            }
            if nohilightApplies {
                if rule.isExcept {
                    bestNohilightExcept = max(bestNohilightExcept, rule.maskLength)
                } else {
                    bestNohilight = max(bestNohilight, rule.maskLength)
                }
            }
            if nonotifyApplies {
                if rule.isExcept {
                    bestNonotifyExcept = max(bestNonotifyExcept, rule.maskLength)
                } else {
                    bestNonotify = max(bestNonotify, rule.maskLength)
                }
            }
        }

        return IgnoreVerdict(
            hide: bestHide >= 0 && bestHideExcept < bestHide,
            nohilight: bestNohilight >= 0 && bestNohilightExcept < bestNohilight,
            nonotify: bestNonotify >= 0 && bestNonotifyExcept < bestNonotify
        )
    }

    /// Whether a rule would erase someone's whole presence — the only thing that may drop a
    /// row from the nicklist, or a name from completion.
    ///
    /// A nicklist row carries a nick and a hostmask and nothing else: no body, no event type.
    /// So only a rule that needs neither counts — a non-except, pattern-free `ALL` rule scoped
    /// to every buffer or to this one. A `NOHIGHLIGHT`, content-pattern, or single-level rule
    /// deliberately does NOT remove anybody: they're still in the room and still talking, and
    /// vanishing them from the member list would misreport who is there.
    static func isMemberHidden(
        _ compiled: CompiledSet,
        nick: String,
        userhost: String?,
        channel: String,
        now: Date = Date()
    ) -> Bool {
        for rule in compiled.rules {
            guard !rule.isExcept, !rule.hasPattern, rule.hasAll else { continue }
            guard rule.isLive(at: now) else { continue }
            guard rule.channels.matches(channel) else { continue }
            if rule.mask.matches(nick: nick, userhost: userhost) { return true }
        }
        return false
    }

    /// Whether a whole buffer's plain-unread signal is muted (lurker #359).
    ///
    /// True when a non-except, pattern-free, everyone-mask rule carrying `NOUNREAD` covers
    /// this buffer — including a network-wide rule (no channel scope), which is what makes
    /// muting a network downgrade every buffer under it.
    ///
    /// A *masked* NOUNREAD rule deliberately doesn't count: silencing one person's traffic in
    /// a busy channel would need per-sender unread accounting, which is the server's to do and
    /// isn't done. Muting the whole badge on the strength of one ignored member would hide
    /// everybody else's messages from the list too.
    static func channelMutesUnread(
        _ compiled: CompiledSet,
        channel: String,
        now: Date = Date()
    ) -> Bool {
        for rule in compiled.rules {
            guard !rule.isExcept, !rule.hasPattern, rule.nounread, rule.anyNick else { continue }
            guard rule.isLive(at: now) else { continue }
            if rule.channels.matches(channel) { return true }
        }
        return false
    }
}

/// One event, in the terms a rule is written against.
public struct IgnoreInput: Sendable {
    public let nick: String?
    /// The sender's `nick!user@host`, when the server had one. A rule that names a user or
    /// host can't match without it.
    public let userhost: String?
    /// The buffer the event landed in — what a rule's channel scope is matched against.
    public let target: String
    public let text: String
    public let type: EventType
    /// Whether `target` is a DM rather than a channel — the whole of the `PUBLIC`/`MSGS` split.
    public let isDm: Bool

    public init(
        nick: String?,
        userhost: String?,
        target: String,
        text: String,
        type: EventType,
        isDm: Bool
    ) {
        self.nick = nick
        self.userhost = userhost
        self.target = target
        self.text = text
        self.type = type
        self.isDm = isDm
    }
}

/// What the rules say about one event.
public struct IgnoreVerdict: Equatable, Sendable {
    /// Don't render the row at all.
    public let hide: Bool
    /// Render it, but never as a highlight — the mention wash comes off.
    public let nohilight: Bool
    /// Render and count it, but don't make a sound about it.
    ///
    /// Nothing on this client reads it yet, and by design: whether a notification fires is the
    /// server's call (it folds `hide || nonotify` into the `notify` flag it decides push on),
    /// so a second opinion here could only disagree with it. It's part of the verdict because
    /// it's part of what a rule *says*, and computing two thirds of a verdict would make the
    /// matcher's agreement with the server's copy partial rather than checkable.
    public let nonotify: Bool

    public init(hide: Bool, nohilight: Bool, nonotify: Bool) {
        self.hide = hide
        self.nohilight = nohilight
        self.nonotify = nonotify
    }

    /// The verdict when no rule has anything to say.
    public static let visible = IgnoreVerdict(hide: false, nohilight: false, nonotify: false)
}

private extension NSRegularExpression {
    /// Whether the pattern matches anywhere in `text`. Anchoring is the pattern's own business
    /// — `globToRegex` builds `^…$`-anchored sources, a user's `-pattern regex` is matched as
    /// written — so there is one method rather than two names for the same call.
    ///
    /// The range is built from String indices rather than by bridging to `NSString`, matching
    /// `NickHighlighter.matches(in:)` and avoiding a bridge per call on the render path.
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

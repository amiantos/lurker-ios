// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// @‑mention completion: the pure logic behind the pill strip the composer floats when
/// the user types `@`. A faithful port of the web client's `nickCompletion.ts`, so the
/// two clients can't disagree about who leads the list:
///
///  - recent speakers first, most recent first — the people you're most likely answering;
///  - then the rest of the member list alphabetically, so someone who hasn't spoken is
///    still reachable by typing;
///  - you are never a candidate (self-mention is noise in your own suggestions);
///  - in a channel, a speaker who has since left is dropped — completing them would
///    address nobody;
///  - an ignored nick is dropped for the same reason it's dropped from the nicklist —
///    offering to address someone whose replies you won't see is offering a dead end.
///
/// The token scanner lives here too (not in the composer) so the whole feature is
/// unit-testable: what counts as an active mention, and what a completed one inserts.
public enum NickCompletion {

    // MARK: - Candidates

    /// Who `@query` offers, best first, capped at `limit`. `messages` supplies recency
    /// (newest last, as buffers hold them); `members` supplies the fallback pool and the
    /// still-here check.
    ///
    /// `ignores`/`networkId` strip ignored candidates. Taken as the shared type rather than an
    /// injected predicate: `IgnoreSet` lives in this module, is immutable, and already carries
    /// the cheap "no rules on this network" gate — so a closure would only move that gate to
    /// the caller and make every call site restate it. Defaulted to `.empty`, which answers
    /// "nobody is ignored" for the callers that don't care.
    ///
    /// A member's userhost is reconstructed from the member row when the server sent both
    /// halves; a speaker carries only a nick, so a hostmask-only rule can't suppress one
    /// (matching the web, which has the same information at the same point).
    public static func candidates(
        messages: [Message],
        members: [Member],
        selfNick: String?,
        query: String,
        isChannel: Bool,
        limit: Int = 4,
        ignores: IgnoreSet = .empty,
        networkId: Int? = nil,
        channel: String = ""
    ) -> [String] {
        let prefix = query.lowercased()
        var seen = Set<String>()
        if let selfNick { seen.insert(selfNick.lowercased()) }
        // One index over `members`, answering both "are they still here" and "what's their
        // hostmask" — the membership check is just a lookup that found something.
        var memberByNick: [String: Member] = [:]
        for member in members { memberByNick[member.nick.lowercased()] = member }
        let filtering = !ignores.isEmpty(for: networkId)
        func isIgnored(_ nick: String, _ userhost: String?) -> Bool {
            guard filtering else { return false }
            return ignores.isIgnored(
                networkId: networkId, nick: nick, userhost: userhost, channel: channel
            )
        }
        var out: [String] = []

        // Speakers, newest first. Only speech counts — the web records speakers on
        // message/action alone, so a notice bot or a join flood never crowds the list.
        for message in messages.reversed() {
            guard out.count < limit else { return out }
            guard message.type == .message || message.type == .action,
                  !message.isSelf, let nick = message.nick, !nick.isEmpty
            else { continue }
            let lc = nick.lowercased()
            guard !seen.contains(lc), lc.hasPrefix(prefix) else { continue }
            let member = memberByNick[lc]
            if isChannel, member == nil { continue }
            // Marked seen either way: an ignored nick is *decided*, and leaving it unseen would
            // let the member pass below offer the same person the speaker pass just refused.
            seen.insert(lc)
            if isIgnored(nick, message.userhost ?? member?.userhost) { continue }
            out.append(nick)
        }

        // Then everyone else who's here, in case-folded alphabetical order — the same
        // nick tiebreaker MemberPrefix's sort uses (rank doesn't apply here: completion
        // is about who you're addressing, not who has ops).
        for member in members.sorted(by: { $0.nick.lowercased() < $1.nick.lowercased() }) {
            guard out.count < limit else { return out }
            let lc = member.nick.lowercased()
            guard !seen.contains(lc), lc.hasPrefix(prefix) else { continue }
            seen.insert(lc)
            if isIgnored(member.nick, member.userhost) { continue }
            out.append(member.nick)
        }
        return out
    }

    // MARK: - Token

    /// An in-progress `@…` under the caret. Offsets are UTF-16 (`NSRange`'s currency, so
    /// the composer can hand `selectedRange` straight in).
    public struct MentionToken: Equatable {
        /// Offset of the `@` itself.
        public let start: Int
        /// One past the token's last character — the end of the whitespace-delimited
        /// word, which runs *past* the caret when the caret sits mid-word. Completion
        /// replaces `start..<end`: swallowing the tail is what keeps `@al|ice` from
        /// completing to "aliceice".
        public let end: Int
        /// What follows the `@`, up to the caret — the filter query. Deliberately not the
        /// whole word: the list should answer what's been typed so far.
        public let query: String
    }

    /// The active mention at `caret`, or nil. A token is the whitespace-delimited run the
    /// caret sits in, and it must *begin* with `@` at a word boundary — `user@host` is an
    /// email-shaped word, not a mention, exactly as the web treats it.
    public static func activeMention(in text: String, caret: Int) -> MentionToken? {
        let chars = Array(text.utf16)
        guard caret >= 0, caret <= chars.count else { return nil }
        let at = UnicodeScalar("@").value
        var index = caret - 1
        while index >= 0 {
            let unit = chars[index]
            if isWhitespace(unit) { return nil } // hit the word's start without finding @
            if UInt32(unit) == at {
                // The @ must open the word: start of text, or after whitespace. An @
                // mid-word (user@host) disqualifies the whole word, so stop either way.
                guard index == 0 || isWhitespace(chars[index - 1]) else { return nil }
                var end = caret
                while end < chars.count, !isWhitespace(chars[end]) { end += 1 }
                return MentionToken(
                    start: index,
                    end: end,
                    query: String(decoding: chars[(index + 1)..<caret], as: UTF16.self)
                )
            }
            index -= 1
        }
        return nil
    }

    /// What a completed nick carries after it: the addressing form when the mention opens
    /// the line, and a plain space mid-sentence. Same rule as the web's `isAtLineStart`
    /// (`/(^|\n)\s*$/`): any run of whitespace between the line's start and the token still
    /// counts as the start of the line.
    ///
    /// `punctuation` is the user's `input.completion.nick_suffix` — pass
    /// `addressPunctuation(settings)`. Not defaulted: the literal `":"` used to be baked in
    /// here, and a default would let a call site keep it silently.
    public static func addressingSuffix(
        beforeTokenAt start: Int, in text: String, punctuation: String
    ) -> String {
        let chars = Array(text.utf16.prefix(max(0, start)))
        var index = chars.count - 1
        while index >= 0 {
            let unit = chars[index]
            if UInt32(unit) == UnicodeScalar("\n").value { return punctuation + " " }
            if !isWhitespace(unit) { return " " }
            index -= 1
        }
        return punctuation + " "
    }

    // MARK: - The addressing suffix (#133 / web #835)

    /// The punctuation a nick takes when it opens the line, per
    /// `input.completion.nick_suffix`. The setting stores the mark *alone* — the space is
    /// always the client's to add — so "space only" is the empty string, and the registry
    /// default is `":"`.
    ///
    /// Trailing whitespace is dropped rather than doubled, matching the web's `addressPunct`:
    /// the setting's description shows the form as `nick: `, so typing exactly that into the
    /// field is the natural mistake, and it lets `/set … " "` land on "space only" too. Note
    /// this happens at *apply* time, not write time — a value written by the web keeps its
    /// spaces on the server, and both clients trim on the way out.
    public static func addressPunctuation(_ settings: Settings) -> String {
        addressPunctuation(settings.string("input.completion.nick_suffix", default: ":"))
    }

    /// The applied form of an already-read `input.completion.nick_suffix` — the trim above,
    /// on its own. Split out so a control that OFFERS values can match the stored one against
    /// them the same way the completion matches it: a value the web wrote as `", "` is the
    /// `","` choice, and a picker that couldn't see that would show the row as "custom".
    public static func addressPunctuation(_ stored: String) -> String {
        var punctuation = stored
        while let last = punctuation.unicodeScalars.last, isWhitespace(last) {
            punctuation.unicodeScalars.removeLast()
        }
        return punctuation
    }

    /// Whether `draft` already opens by addressing `nick`, so Reply is idempotent. A port of
    /// the web's `isAddressedTo` (`MessageInput.vue`), and it deliberately accepts more than
    /// the configured form:
    ///
    ///  - a draft can carry an *older* setting's punctuation, or one another client wrote —
    ///    drafts sync, and the web writes whatever its own setting says — so any run of
    ///    punctuation after the nick counts, not just today's mark;
    ///  - the configured mark counts verbatim whatever it is, since a multi-character or
    ///    nick-shaped mark (`->`) wouldn't survive the punctuation-run test;
    ///  - the bare `nick ` form counts *only* when it IS the configured form. Otherwise a
    ///    draft that merely opens with a nick that is also a word ("will you come?") would
    ///    swallow the Reply. Under an empty setting the two are the same text — that is the
    ///    ambiguity of the convention itself, not something to second-guess.
    ///
    /// The punctuation run may not contain a character that could *continue* a nick, or
    /// `bob_: hi` would read as addressing bob — and `bob_` is every ghost's nick.
    public static func isAddressed(_ draft: String, to nick: String, punctuation: String) -> Bool {
        guard !nick.isEmpty else { return false }
        let text = Array(draft.unicodeScalars)
        let name = Array(nick.unicodeScalars)
        guard text.count > name.count else { return false }
        // ASCII folding, the same rule the rest of the client uses for IRC targets: a nick's
        // case-insensitivity is the protocol's, not the locale's.
        for (index, scalar) in name.enumerated() where asciiLower(text[index]) != asciiLower(scalar) {
            return false
        }
        let rest = text[name.count...]

        // The configured mark, verbatim, then whitespace.
        let mark = Array(punctuation.unicodeScalars)
        if !mark.isEmpty, rest.count > mark.count, Array(rest.prefix(mark.count)) == mark,
           isWhitespace(rest[rest.startIndex + mark.count]) {
            return true
        }

        // Else a run of punctuation, then whitespace. Greedy with no backtracking is exact
        // here: the run excludes whitespace, so stopping short would only leave a non-space.
        var index = rest.startIndex
        while index < rest.endIndex, isMarkScalar(rest[index]) { index += 1 }
        let ranAtLeastOne = index > rest.startIndex
        // A bare `nick ` is an address only under the empty setting (see the doc comment).
        guard ranAtLeastOne || mark.isEmpty else { return false }
        return index < rest.endIndex && isWhitespace(rest[index])
    }

    /// A scalar that cannot continue a nick, which is what "punctuation after the nick" has to
    /// mean above: not a letter or digit, not whitespace, and not one of the RFC 2812 nick
    /// specials. Mirrors the web's `NOT_NICK_CHAR`, whose `\p{L}\p{N}` this reads as
    /// `.alphanumerics` — Unicode, because ASCII-only `\w` would let `bobł` parse as bob plus
    /// a mark.
    private static func isMarkScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isWhitespace(scalar) { return false }
        if CharacterSet.alphanumerics.contains(scalar) { return false }
        return !nickSpecials.contains(scalar)
    }

    private static let nickSpecials = Set("_[]\\`^{|}-".unicodeScalars)

    private static func asciiLower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (scalar.value >= 65 && scalar.value <= 90)
            ? Unicode.Scalar(scalar.value + 32) ?? scalar
            : scalar
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return isWhitespace(scalar)
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

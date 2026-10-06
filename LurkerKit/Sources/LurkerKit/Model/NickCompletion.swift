// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Nick completion: the pure logic behind the pill strip the composer floats when the
/// user types `@`, or the first letters of a nick (lurker-android#57). A faithful port of the web client's `nickCompletion.ts`, so the
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

    /// Who a nick query offers — after an `@`, or a bare word — best first, capped at
    /// `limit`. `speakers` supplies recency — the store's `SpeakerMap`, the web's
    /// `buf.speakers`, never a scan of the loaded messages: a bare word asks on most keystrokes,
    /// and the map is capped where the history is not. `members` supplies the fallback pool and
    /// the still-here check.
    ///
    /// `ignores`/`networkId` strip ignored candidates. Taken as the shared type rather than an
    /// injected predicate: `IgnoreSet` lives in this module, is immutable, and already carries
    /// the cheap "no rules on this network" gate — so a closure would only move that gate to
    /// the caller and make every call site restate it. Defaulted to `.empty`, which answers
    /// "nobody is ignored" for the callers that don't care.
    ///
    /// A member's userhost is reconstructed from the member row when the server sent both
    /// halves; a speaker carries only a nick, so a hostmask-only rule can't suppress a speaker
    /// who isn't a member: one who has left a channel, or a DM's peer, since a DM has no
    /// member list. The web has the same information at the same point and the same gap.
    /// Closing it would mean rescanning the loaded history on every keystroke, which is the
    /// cost `speakers` exists to avoid, all to hide a pill naming the one person whose DM is
    /// already open.
    public static func candidates(
        speakers: SpeakerMap,
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

        // Speakers, newest first. Only speech counts, and never our own — the map records
        // message/action from others alone, so a notice bot or a join flood never crowds it.
        for speaker in speakers.recent {
            guard out.count < limit else { return out }
            let nick = speaker.nick
            let lc = nick.lowercased()
            guard !seen.contains(lc), lc.hasPrefix(prefix) else { continue }
            let member = memberByNick[lc]
            if isChannel, member == nil { continue }
            // Marked seen either way: an ignored nick is *decided*, and leaving it unseen would
            // let the member pass below offer the same person the speaker pass just refused.
            seen.insert(lc)
            if isIgnored(nick, member?.userhost) { continue }
            out.append(nick)
        }

        // Then everyone else who's here, in case-folded alphabetical order — the same
        // nick tiebreaker MemberPrefix's sort uses (rank doesn't apply here: completion
        // is about who you're addressing, not who has ops). Filtered before the sort: a
        // bare word asks on most keystrokes, and a big channel's whole member list
        // shouldn't be sorted for the handful that match.
        let matching = members.filter { $0.nick.lowercased().hasPrefix(prefix) }
        for member in matching.sorted(by: { $0.nick.lowercased() < $1.nick.lowercased() }) {
            guard out.count < limit else { return out }
            let lc = member.nick.lowercased()
            guard !seen.contains(lc) else { continue }
            seen.insert(lc)
            if isIgnored(member.nick, member.userhost) { continue }
            out.append(member.nick)
        }
        return out
    }

    // MARK: - Token

    /// An in-progress nick under the caret — an `@…`, or a bare word long enough to ask.
    /// Offsets are UTF-16 (`NSRange`'s currency, so the composer can hand `selectedRange`
    /// straight in).
    public struct MentionToken: Equatable {
        /// Offset of the token's first character: the `@`, or a bare word's first letter.
        /// Completion replaces from here, so the `@` goes and the nick stands alone.
        public let start: Int
        /// One past the token's last character — the end of the whitespace-delimited
        /// word, which runs *past* the caret when the caret sits mid-word. Completion
        /// replaces `start..<end`: swallowing the tail is what keeps `@al|ice` from
        /// completing to "aliceice".
        public let end: Int
        /// What's been typed of the nick, up to the caret — after the `@`, or from a bare
        /// word's start. The filter query. Deliberately not the whole word: the list should
        /// answer what's been typed so far.
        public let query: String
    }

    /// How much of a bare word must be typed before it asks for nicks — the web's mobile
    /// strip threshold, so a one-letter word ("I", "a") never floats the pills. Counted in
    /// Unicode scalars, so one emoji is one, not the two UTF-16 units it occupies.
    public static let bareWordMinimum = 2

    /// The nick being typed at `caret`, or nil. A token is the whitespace-delimited run the
    /// caret sits in, and it asks in one of two shapes:
    ///
    ///  - `@…`, explicit, so it asks from the first keystroke — a lone `@` lists everyone —
    ///    on any line, and with the caret anywhere in the word;
    ///  - a bare word of at least `bareWordMinimum` characters, the web's mobile suggestion
    ///    strip (lurker-android#57), so a nick can be finished without the `@`. Narrower than
    ///    the `@`, because it fires on words the user never meant as nicks: only with the
    ///    caret at the word's END (a caret placed inside a word is editing it, and a pick
    ///    would replace the rest of it), never in a word opening with `/` or a channel sigil,
    ///    and never on a command line but `/me` — a command's arguments are keys, passwords
    ///    and new nicks, where a nick pick is only ever a mistake.
    ///
    /// An `@` anywhere but the word's start disqualifies the word in both shapes: `user@host`
    /// is an email-shaped word, not a mention, exactly as the web treats it — and completion
    /// replaces the whole word, so it would take an `@host` after the caret with it.
    public static func activeMention(in text: String, caret: Int) -> MentionToken? {
        let chars = Array(text.utf16)
        guard caret >= 0, caret <= chars.count else { return nil }
        var start = caret
        while start > 0, !isWhitespace(chars[start - 1]) { start -= 1 }
        var end = caret
        while end < chars.count, !isWhitespace(chars[end]) { end += 1 }
        guard start < caret, !chars[(start + 1)..<end].contains(atSign) else { return nil }

        if chars[start] == atSign {
            return MentionToken(
                start: start,
                end: end,
                query: String(decoding: chars[(start + 1)..<caret], as: UTF16.self)
            )
        }

        guard caret == end, !isCommandLine(chars) else { return nil }
        let word = String(decoding: chars[start..<end], as: UTF16.self)
        guard word.unicodeScalars.count >= bareWordMinimum,
              !word.hasPrefix("/"), !ChannelName.isChannelTarget(word)
        else { return nil }
        return MentionToken(start: start, end: end, query: word)
    }

    private static let atSign = UInt16(UnicodeScalar("@").value)

    /// Whether the draft is a command whose arguments a bare word must stay out of: it opens
    /// (after any whitespace, which the composer trims before sending) with `/` and a verb
    /// other than `me` or `shrug`, whose arguments are chat text. `//` escapes a command, so
    /// that line is text.
    private static func isCommandLine(_ chars: [UInt16]) -> Bool {
        // The very first character, as `CommandParser` decides it: " /nick al" is text to the
        // channel (lurker-ios#210), so `al` there is a nick like any other.
        let index = 0
        let slash = UInt16(UnicodeScalar("/").value)
        guard index < chars.count, chars[index] == slash else { return false }
        let verb = chars[(index + 1)...].prefix { !isWhitespace($0) }
        if verb.first == slash { return false }
        return !["me", "shrug"].contains(String(decoding: verb, as: UTF16.self).lowercased())
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

    /// How the addressing punctuation should be READ ALOUD — for a settings control, whose
    /// visible label is a sample of the form (`nick:`) and so is nearly all punctuation.
    ///
    /// VoiceOver does not speak trailing punctuation at its default verbosity, so left alone
    /// every choice announces as "nick" and the row's value never changes however it is set.
    ///
    /// Derived from the Unicode names rather than a table of the marks we happen to offer: the
    /// value is free-form on the web, so a phone that could only name the four would be mute
    /// on exactly the value it can't otherwise explain — the setting a user would most need
    /// read back. A letter or digit is left as itself, because those already read aloud and
    /// "latin small letter p" is not an improvement on "p".
    public static func spokenPunctuation(_ punctuation: String) -> String {
        guard !punctuation.isEmpty else { return "Space only" }
        var spoken = punctuation.unicodeScalars.map { scalar -> (text: String, isName: Bool) in
            if CharacterSet.alphanumerics.contains(scalar) { return (String(scalar), false) }
            return (scalar.properties.name?.lowercased() ?? String(scalar), true)
        }
        // Sentence case, but only when the first piece is a NAME. Capitalising a character
        // kept as itself would change it: `p;` reads as a capital P, which is a different
        // suffix from the one that is set.
        if let first = spoken.first, first.isName {
            spoken[0].text = first.text.prefix(1).uppercased() + first.text.dropFirst()
        }
        return spoken.map(\.text).joined(separator: " ")
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
        addressLength(draft, to: nick, punctuation: punctuation) != nil
    }

    /// `draft` with the address `isAddressed` recognizes taken off its front — what cancelling a
    /// pending reply undoes (iOS #184), the web's `stripAddress`. One pattern for both, so what
    /// counts as an address and what a cancel takes back can't drift apart. Anything else in the
    /// draft stays; a draft that doesn't open with the address comes back as it was.
    public static func removingAddress(_ draft: String, to nick: String, punctuation: String) -> String {
        guard let length = addressLength(draft, to: nick, punctuation: punctuation) else { return draft }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: draft.unicodeScalars.dropFirst(length))
        return String(scalars)
    }

    /// A reply's text without the `nick: ` it opens with (iOS #184) — the web's
    /// `stripReplyAddress`. Stricter than `isAddressed` in one way and looser in another, both the
    /// web's: the nick must be followed by at least one punctuation mark (so a reply to `will`
    /// saying "will you come?" keeps its first word, whatever the setting), and every space after
    /// it goes. Never strips to nothing. Same scalar walk as `isAddressed`, so what the composer
    /// writes and what the timeline hides are one definition.
    public static func removingReplyAddress(_ text: String, to nick: String) -> String {
        guard !nick.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        let name = Array(nick.unicodeScalars)
        guard scalars.count > name.count else { return text }
        for (index, scalar) in name.enumerated() where asciiLower(scalars[index]) != asciiLower(scalar) {
            return text
        }
        var index = name.count
        while index < scalars.count, isMarkScalar(scalars[index]) { index += 1 }
        guard index > name.count, index < scalars.count, isWhitespace(scalars[index]) else { return text }
        while index < scalars.count, isWhitespace(scalars[index]) { index += 1 }
        guard index < scalars.count else { return text }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[index...])
        return String(out)
    }

    /// Whether two nicks are the same person's, folded the way IRC folds them — ASCII only, as
    /// the rest of the client compares nicks and targets.
    public static func sameNick(_ a: String, _ b: String) -> Bool {
        let left = Array(a.unicodeScalars), right = Array(b.unicodeScalars)
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { asciiLower($0) == asciiLower($1) }
    }

    /// How many scalars the address at the head of `draft` spans — nick, mark, and the one
    /// whitespace after it — or nil when it doesn't open with one.
    private static func addressLength(_ draft: String, to nick: String, punctuation: String) -> Int? {
        guard !nick.isEmpty else { return nil }
        let text = Array(draft.unicodeScalars)
        let name = Array(nick.unicodeScalars)
        guard text.count > name.count else { return nil }
        // ASCII folding, the same rule the rest of the client uses for IRC targets: a nick's
        // case-insensitivity is the protocol's, not the locale's.
        for (index, scalar) in name.enumerated() where asciiLower(text[index]) != asciiLower(scalar) {
            return nil
        }
        let rest = text[name.count...]

        // The configured mark, verbatim, then whitespace.
        let mark = Array(punctuation.unicodeScalars)
        if !mark.isEmpty, rest.count > mark.count, Array(rest.prefix(mark.count)) == mark,
           isWhitespace(rest[rest.startIndex + mark.count]) {
            return name.count + mark.count + 1
        }

        // Else a run of punctuation, then whitespace. Greedy with no backtracking is exact
        // here: the run excludes whitespace, so stopping short would only leave a non-space.
        var index = rest.startIndex
        while index < rest.endIndex, isMarkScalar(rest[index]) { index += 1 }
        let ranAtLeastOne = index > rest.startIndex
        // A bare `nick ` is an address only under the empty setting (see the doc comment).
        guard ranAtLeastOne || mark.isEmpty else { return nil }
        guard index < rest.endIndex, isWhitespace(rest[index]) else { return nil }
        return index + 1
    }

    /// A scalar that cannot continue a nick, which is what "punctuation after the nick" has to
    /// mean above: not a letter or digit, not whitespace, and not one of the RFC 2812 nick
    /// specials. Mirrors the web's `NOT_NICK_CHAR`, whose `\p{L}\p{N}` is Unicode rather than
    /// ASCII `\w` — or `bobł` would parse as bob plus a mark, and `bobł` is somebody else.
    ///
    /// The general categories are spelled out rather than reached through a `CharacterSet`,
    /// because none of them is the same set: `.alphanumerics` is `L* ∪ M* ∪ N*` (a combining
    /// mark would read as part of the nick where the web reads it as punctuation) and
    /// `.decimalDigits` is `Nd` alone (dropping `Nl`/`No`). Both divergences are unreachable
    /// in a real draft, which is exactly why they'd never be found again once written.
    private static func isMarkScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isWhitespace(scalar) { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return false
        default:
            return !nickSpecials.contains(scalar)
        }
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

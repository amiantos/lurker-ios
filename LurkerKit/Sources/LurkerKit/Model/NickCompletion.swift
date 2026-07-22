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
///    address nobody.
///
/// The token scanner lives here too (not in the composer) so the whole feature is
/// unit-testable: what counts as an active mention, and what a completed one inserts.
public enum NickCompletion {

    // MARK: - Candidates

    /// Who `@query` offers, best first, capped at `limit`. `messages` supplies recency
    /// (newest last, as buffers hold them); `members` supplies the fallback pool and the
    /// still-here check.
    public static func candidates(
        messages: [Message],
        members: [Member],
        selfNick: String?,
        query: String,
        isChannel: Bool,
        limit: Int = 4
    ) -> [String] {
        let prefix = query.lowercased()
        var seen = Set<String>()
        if let selfNick { seen.insert(selfNick.lowercased()) }
        let memberSet = Set(members.map { $0.nick.lowercased() })
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
            if isChannel, !memberSet.contains(lc) { continue }
            seen.insert(lc)
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

    /// What a completed nick carries after it: `": "` when the mention opens the line —
    /// the IRC addressing form — and a plain space mid-sentence. Same rule as the web's
    /// `isAtLineStart` (`/(^|\n)\s*$/`): any run of whitespace between the line's start
    /// and the token still counts as the start of the line.
    public static func addressingSuffix(beforeTokenAt start: Int, in text: String) -> String {
        let chars = Array(text.utf16.prefix(max(0, start)))
        var index = chars.count - 1
        while index >= 0 {
            let unit = chars[index]
            if UInt32(unit) == UnicodeScalar("\n").value { return ": " }
            if !isWhitespace(unit) { return " " }
            index -= 1
        }
        return ": "
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

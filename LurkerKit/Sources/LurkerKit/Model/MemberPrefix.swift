// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Channel user-mode prefixes, ported from the web client's `memberPrefix.ts` so the
/// @/+/%/~/& glyph and the ordering match between clients.
///
/// NOTE (inherited from the reference): the q/a/o/h/v → ~/&/@/%/+ mapping is the
/// conventional RFC/ISUPPORT default and is hardcoded. Neither client reads a network's
/// ISUPPORT PREFIX yet, so a server that diverges from the standard ordering won't be
/// honored — a known, deliberate limitation, not an oversight to fix here.
public enum MemberPrefix {
    /// Ranked owner > admin > op > halfop > voice. Highest held mode wins.
    public static let rank = ["q", "a", "o", "h", "v"]
    private static let glyph: [String: String] = ["q": "~", "a": "&", "o": "@", "h": "%", "v": "+"]

    /// The single highest-ranked prefix glyph for a set of channel modes, or "" when the
    /// member holds none.
    public static func of(_ modes: [String]) -> String {
        for letter in rank where modes.contains(letter) {
            return glyph[letter] ?? ""
        }
        return ""
    }

    /// Sort position: lower is higher-ranked; unprivileged members sort last.
    public static func order(_ modes: [String]) -> Int {
        for (index, letter) in rank.enumerated() where modes.contains(letter) {
            return index
        }
        return rank.count
    }

    /// The member list as it should read: by rank, then by nick.
    ///
    /// Nicks fold case for the comparison because IRC nick case is not meaningful — a
    /// raw `<` would sort every capitalized nick above every lowercase one, which reads
    /// as two separate alphabets rather than one list.
    public static func sorted(_ members: [Member]) -> [Member] {
        members.sorted { lhs, rhs in
            let (left, right) = (order(lhs.modes), order(rhs.modes))
            if left != right { return left < right }
            return lhs.nick.lowercased() < rhs.nick.lowercased()
        }
    }

    /// The glyphs themselves, derived from the map above rather than written out again —
    /// a second hand-typed copy of a sigil set is exactly how lurker-ios#98 got in.
    private static let glyphs = Set(glyph.values.compactMap(\.first))

    /// Split a `"@#foo"` token from RPL_WHOISCHANNELS into the sigils held there and the
    /// channel itself.
    ///
    /// ⚠⚠ **A greedy peel of `[~&@%+]` is wrong, and the web client (`UserProfileModal.vue`,
    /// `channelsList`) has that bug.** `&` and `+` are membership glyphs *and* channel sigils
    /// (RFC 2811 §2.1 — see `ChannelName`), so `@&chan` greedily peels `@&` and yields
    /// `chan`: a channel that doesn't exist, offered as something to tap.
    ///
    /// So peel as much as possible **while what's left is still a channel name**: take the
    /// largest split point whose remainder passes `ChannelName.isChannelTarget`.
    ///
    /// - `@#foo` → (`@`, `#foo`) — only one split works.
    /// - `&chan` → (``, `&chan`) — peeling the `&` leaves `chan`, which names no channel.
    /// - `@&chan` → (`@`, `&chan`) — the case the greedy version breaks.
    ///
    /// `+#chan` and `+chan` are genuinely ambiguous — both halves are legal readings, and
    /// without the network's ISUPPORT `PREFIX`/`CHANTYPES` nothing here can tell them apart.
    /// Preferring the largest split resolves them the way traffic actually runs: voiced in
    /// `#chan`, and the `+chan` channel (whose remainder `chan` is not a channel) is
    /// unaffected because that split isn't legal in the first place.
    ///
    /// Nil for a token that is **nothing but glyphs** — `"@"` names no channel, and a row for
    /// it is untappable furniture. Anything else keeps its whole self as the name even when no
    /// peel is legal, because a network whose `CHANTYPES` this client doesn't know still has
    /// real channels, and dropping those would be worse than showing them unpeeled.
    public static func splitChannelToken(_ token: String) -> (prefix: String, name: String)? {
        var best = 0
        var index = 0
        for character in token {
            guard glyphs.contains(character) else { break }
            index += 1
            if ChannelName.isChannelTarget(String(token.dropFirst(index))) { best = index }
        }
        // `index` is the whole glyph run; reaching the end of the token inside it means there
        // was never a name here.
        guard index < token.count else { return nil }
        return (String(token.prefix(best)), String(token.dropFirst(best)))
    }
}

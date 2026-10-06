// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Channel user-mode prefixes — a member's glyph, rank and glyph colour — read from the network's
/// own PREFIX (`Network.modeSpec.prefix`, highest rank first), as the web client's
/// `memberPrefix.ts` does since lurker#1032 (lurker-ios#191). Display only: rank gates go through
/// `ChannelRank`.
///
/// `prefix` is nil while the network hasn't sent its ISUPPORT yet; that falls back to the
/// conventional q/a/o/h/v → ~/&/@/%/+ table (`conventional`).
public enum MemberPrefix {
    /// The conventional PREFIX, `(qaohv)~&@%+`, for a network that hasn't said.
    public static let conventional: [PrefixMode] = [
        PrefixMode(mode: "q", symbol: "~"), PrefixMode(mode: "a", symbol: "&"),
        PrefixMode(mode: "o", symbol: "@"), PrefixMode(mode: "h", symbol: "%"),
        PrefixMode(mode: "v", symbol: "+"),
    ]

    /// The five glyph colours (`look.color.member.*`).
    public enum Tier: Equatable, Sendable {
        case owner, admin, op, halfop, voice
    }

    /// A member's glyph and the colour it wears.
    public struct Mark: Equatable, Sendable {
        public let glyph: String
        public let tier: Tier
    }

    /// The symbol of the highest-ranked prefix mode the member holds, or "" when they hold none.
    public static func of(_ modes: [String], prefix: [PrefixMode]?) -> String {
        mark(modes, prefix: prefix)?.glyph ?? ""
    }

    /// The glyph and its colour tier, or nil when the member holds no prefix mode.
    ///
    /// The tier is keyed by the LETTER's conventional role, not by the symbol and not by position:
    /// another symbol for op is still op, and on Libera's `(ov)@+` op is the top rank — by
    /// position it would take the owner colour. A letter outside q/a/o/h/v takes the tier of the
    /// nearest known letter that outranks it, or owner when none does: on `(Yqaohv)!~&@%+` a `Y`
    /// is coloured as an owner, whatever its symbol. The web's `prefixClass`.
    public static func mark(_ modes: [String], prefix: [PrefixMode]?) -> Mark? {
        let list = prefix ?? conventional
        guard let index = ChannelRank.index(modes, prefix: list) else { return nil }
        var tier = Tier.owner
        for candidate in list[...index].reversed() {
            if let known = tierByLetter[candidate.mode] {
                tier = known
                break
            }
        }
        return Mark(glyph: list[index].symbol, tier: tier)
    }

    private static let tierByLetter: [String: Tier] = ["q": .owner, "a": .admin, "o": .op, "h": .halfop, "v": .voice]

    /// Sort position: 0 for the top rank, and members with no prefix mode after every rank the
    /// network has.
    public static func order(_ modes: [String], prefix: [PrefixMode]?) -> Int {
        let list = prefix ?? conventional
        return ChannelRank.index(modes, prefix: list) ?? list.count
    }

    /// The member list as it should read: by rank, then by nick.
    ///
    /// Nicks fold case for the comparison because IRC nick case is not meaningful — a
    /// raw `<` would sort every capitalized nick above every lowercase one, which reads
    /// as two separate alphabets rather than one list.
    public static func sorted(_ members: [Member], prefix: [PrefixMode]?) -> [Member] {
        members.sorted { lhs, rhs in
            let (left, right) = (order(lhs.modes, prefix: prefix), order(rhs.modes, prefix: prefix))
            if left != right { return left < right }
            return lhs.nick.lowercased() < rhs.nick.lowercased()
        }
    }

    /// The conventional glyphs, derived from the table above rather than written out again —
    /// a second hand-typed copy of a sigil set is exactly how lurker-ios#98 got in. The WHOIS
    /// split keeps the conventional set on purpose; it's a different question (see below).
    private static let glyphs = Set(conventional.compactMap(\.symbol.first))

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

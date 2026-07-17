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
}

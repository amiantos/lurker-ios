// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Generated avatar tiles (lurker#607, Mobile lurker#1203): which image of a set a nick gets.
///
/// A port of `shared/avatarTiles.ts`, byte-for-byte in what it hashes, so the web, the apps and
/// the server pick the same image for the same nick. The nick is trimmed and lowercased the way
/// the nick colour is (`NickColor`), then hashed with the same djb2 — but salted: the palette
/// has 19 entries and a set may have 140, which share no factor today but did on the web's 16
/// and 100, and the salt is what keeps colour and tile independent either way.
public enum AvatarTiles {
    private static let salt = "avatar-tile:"

    /// The stop characters the nick colour trims at by default (`look.nick.color_stop_chars`).
    public static let defaultStopChars: Set<Unicode.Scalar> = ["_", "|"]

    /// The index in a set of `count` tiles for `nick`, or nil when there is nothing to pick: no
    /// nick, or no tiles.
    public static func index(
        for nick: String?,
        count: Int,
        stopChars: Set<Unicode.Scalar> = defaultStopChars
    ) -> Int? {
        guard let nick, !nick.isEmpty, count > 0 else { return nil }
        let normalized = NickColor.lowercasedLikeTheWeb(NickColor.trimForColor(nick, stopChars: stopChars))
        guard !normalized.isEmpty else { return nil }
        return Int(NickColor.djb2(salt + normalized) % UInt32(count))
    }

    /// `<base>/<nnn>.<ext>`: tiles are numbered from 000 in file-name order.
    public static func url(base: String, index: Int, ext: String) -> String {
        var trimmed = Substring(base)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let number = String(index)
        let padded = String(repeating: "0", count: max(0, 3 - number.count)) + number
        return "\(trimmed)/\(padded).\(ext)"
    }

    /// The stop-character set a `look.nick.color_stop_chars` value names. Empty means "trim
    /// nothing", as the web's `trimForHash` with no stop chars does.
    public static func stopChars(_ setting: String) -> Set<Unicode.Scalar> {
        Set(setting.unicodeScalars)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// The color tables the web client uses, so native rendering matches it exactly.
public enum IRCPalette {
    /// mIRC colors 0–15. `nil` marks a theme slot the UI fills from its own palette
    /// (0 = foreground, 1 = background, 14 = muted, 15 = ~70% foreground). Indices 16+ are
    /// intentionally not rendered.
    public static let mirc: [String?] = [
        nil, nil, "#6799f3", "#a9dc76", "#ff6188", "#ed6c89", "#ab9df2", "#fc9867",
        "#ffd866", "#b3db82", "#78dce8", "#a0f1ff", "#7ba4ff", "#ff7494", nil, nil,
    ]

    /// Per-nick colors (19), indexed by the weechat djb2 hash. All fixed hex.
    public static let nick: [String] = [
        "#ff6188", "#fc9867", "#ffd866", "#a9dc76", "#78dce8", "#ab9df2", "#ed6c89",
        "#d4996e", "#f9d978", "#b3db82", "#91dae6", "#a99dec", "#ff7494", "#ffaf75",
        "#c4e29a", "#a0f1ff", "#b6aaff", "#7ba4ff", "#6799f3",
    ]
}

/// Deterministic per-nick coloring, reproducing the web client's algorithm so the same
/// nick gets the same color on every client.
public enum NickColor {

    /// The index into `IRCPalette.nick` for `nick`. Trims trailing stop chars, lowercases,
    /// then hashes with weechat's djb2 variant.
    public static func index(for nick: String, paletteCount: Int = IRCPalette.nick.count) -> Int {
        let key = trimForColor(nick).lowercased()
        return Int(djb2(key) % UInt32(max(paletteCount, 1)))
    }

    /// weechat `gui_color_get_custom`: `h = h ^ ((h << 5) + (h >> 2) + cp)` per code point,
    /// seeded at 5381, all unsigned-32-bit. NOT classic djb2.
    static func djb2(_ string: String) -> UInt32 {
        var hash: UInt32 = 5381
        for scalar in string.unicodeScalars {
            let term = (hash &<< 5) &+ (hash >> 2) &+ scalar.value
            hash = hash ^ term
        }
        return hash
    }

    /// Trim trailing "away/alt" stop chars: keep leading stop chars, but once a real char
    /// has been seen, stop at the next stop char (`amiantos__` / `amiantos|` → `amiantos`).
    static func trimForColor(_ nick: String, stopChars: Set<Character> = ["_", "|"]) -> String {
        var result = ""
        var seenNonStop = false
        for character in nick {
            if stopChars.contains(character) {
                if seenNonStop { break }
                result.append(character)
            } else {
                seenNonStop = true
                result.append(character)
            }
        }
        return result
    }
}

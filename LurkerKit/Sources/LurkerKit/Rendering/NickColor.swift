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

    /// Light-mode variants of `mirc`, same indices. Each chromatic slot is the light variant
    /// of the same hex it maps to in `mirc` (all of which are drawn from `nick`), so a color
    /// code and a nick that resolve to the same hue stay consistent. Theme slots stay `nil`.
    public static let mircLight: [String?] = [
        nil, nil, "#3163c0", "#5f9118", "#c40553", "#b52d55", "#7260b6", "#b95417",
        "#a78500", "#688f2d", "#00919e", "#409ba9", "#4268c5", "#c12d5b", nil, nil,
    ]

    /// Per-nick colors (19), indexed by the weechat djb2 hash. All fixed hex. These are the
    /// dark-mode variants — the web client's Monokai palette, matched exactly.
    public static let nick: [String] = [
        "#ff6188", "#fc9867", "#ffd866", "#a9dc76", "#78dce8", "#ab9df2", "#ed6c89",
        "#d4996e", "#f9d978", "#b3db82", "#91dae6", "#a99dec", "#ff7494", "#ffaf75",
        "#c4e29a", "#a0f1ff", "#b6aaff", "#7ba4ff", "#6799f3",
    ]

    /// Light-mode variants of `nick`, same order. The dark palette's pastels are tuned for a
    /// dark canvas and wash out on a light one, so each is transformed in OKLCH: hue kept
    /// exactly (so a nick's identity is unchanged), lightness compressed toward a legible band
    /// (`L → 0.575 + (L−mean)·0.55`) rather than pinned — pinning would collapse the three
    /// purples and two blues, which differ mostly in lightness, into near-duplicates. Chroma
    /// held. Every entry clears WCAG's 3:1 large-text bar on the light canvas, which is the
    /// right bar since nicks always render bold. Yellows unavoidably read as gold: a pure
    /// yellow can't be both yellow and dark enough for a light background.
    public static let nickLight: [String] = [
        "#c40553", "#b95417", "#a78500", "#5f9118", "#00919e", "#7260b6", "#b52d55",
        "#9a5f30", "#a68500", "#688f2d", "#3d8f9b", "#7061b1", "#c12d5b", "#b66621",
        "#759247", "#409ba9", "#7767bd", "#4268c5", "#3163c0",
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

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// The color tables the web client uses, so native rendering matches it exactly.
///
/// Source of truth is the web client's two built-in themes — `look.color.mirc_colors` and
/// `look.nick.colors`, as the Monokai Plus / Monokai Plus Light presets define them in
/// `shared/themePresets.ts`. Both tables here are byte-identical to those. When one moves,
/// this moves.
public enum IRCPalette {
    /// mIRC colors 0–15. Indices 16+ are intentionally not rendered.
    ///
    /// ⚠ **Every slot is a literal, and no slot may become a theme reference.** A colour code
    /// names a colour — `^C00` means white, not "whatever this theme calls text" — and a run can
    /// carry its own background, so a slot that defers to the theme is being resolved against a
    /// surface it doesn't know about. Both clients had this: slot 1 mapped to
    /// `.systemBackground` and drew white-on-white, then slots 0/14/15 tracked the foreground
    /// and broke every `^CFG,BG` pair that touched them — including `^C01,00`, where slot 0 is
    /// the *background* and a foreground reference painted the box.
    ///
    /// The cost is the sender's and is accepted: white is invisible on the light canvas, as
    /// black already was on the dark one.
    /// `[String]`, not `[String?]`. The optional existed only to mark a theme slot, and the type
    /// is now the enforcement: there is no way to spell "resolve this one against the theme".
    public static let mirc: [String] = [
        "#ffffff", "#000000", "#6799f3", "#a9dc76", "#ff6188", "#ed6c89", "#ab9df2", "#fc9867",
        "#ffd866", "#b3db82", "#78dce8", "#a0f1ff", "#7ba4ff", "#ff7494", "#7f7f7f", "#d2d2d2",
    ]

    /// Light-mode variants of `mirc`, same indices. Each chromatic slot is the light variant
    /// of the same hex it maps to in `mirc` (all of which are drawn from `nick`), so a color
    /// code and a nick that resolve to the same hue stay consistent.
    ///
    /// The six slots whose dark value is an official Monokai Pro accent take the official Pro
    /// Light accent (3, 4, 6, 7, 8, 10); the rest keep the OKLCH derivation described on
    /// `nickLight`. The four mono slots are the SAME in both tables — see the ⚠ above; those are
    /// the ones a sender pairs with a background, and re-tinting them per scheme is exactly what
    /// broke the pairs.
    public static let mircLight: [String] = [
        "#ffffff", "#000000", "#3163c0", "#269d69", "#e14775", "#b52d55", "#7058be", "#e16032",
        "#cc7a0a", "#688f2d", "#1c8ca8", "#409ba9", "#4268c5", "#c12d5b", "#7f7f7f", "#d2d2d2",
    ]

    /// Per-nick colors (19), indexed by the weechat djb2 hash. All fixed hex. These are the
    /// dark-mode variants — the web client's Monokai palette, matched exactly.
    public static let nick: [String] = [
        "#ff6188", "#fc9867", "#ffd866", "#a9dc76", "#78dce8", "#ab9df2", "#ed6c89",
        "#d4996e", "#f9d978", "#b3db82", "#91dae6", "#a99dec", "#ff7494", "#ffaf75",
        "#c4e29a", "#a0f1ff", "#b6aaff", "#7ba4ff", "#6799f3",
    ]

    /// Light-mode variants of `nick`, same order.
    ///
    /// The first six entries are the **official Monokai Pro Light** accents — the filter defines
    /// a red, orange, yellow, green, cyan and purple, and the dark palette opens with exactly
    /// those six hues, so the light theme uses the real thing rather than a derivation of it.
    ///
    /// Pro Light defines nothing for the thirteen extended hues that follow, so those keep the
    /// OKLCH transform of their dark value: hue kept exactly (so a nick's identity is unchanged),
    /// lightness compressed toward a legible band (`L → 0.575 + (L−mean)·0.55`) rather than
    /// pinned — pinning would collapse the three purples and two blues, which differ mostly in
    /// lightness, into near-duplicates. Chroma held.
    ///
    /// Every entry clears WCAG's 3:1 large-text bar on the light canvas, which is the right bar
    /// since nicks always render bold. Yellows unavoidably read as gold: a pure yellow can't be
    /// both yellow and dark enough for a light background.
    public static let nickLight: [String] = [
        "#e14775", "#e16032", "#cc7a0a", "#269d69", "#1c8ca8", "#7058be", "#b52d55",
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

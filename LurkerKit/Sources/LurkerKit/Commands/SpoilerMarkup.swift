// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Discord-style `||spoiler||` → IRC spoiler codes on the way out, ported from the web client's
/// `vue_client/src/utils/spoilerMarkup.ts` so both clients turn the same typed text into the same
/// bytes.
///
/// A spoiler on the wire is a run whose foreground and background colour are identical —
/// invisible text in any IRC client, which a client that knows the convention can upgrade into a
/// click-to-reveal box. Closing with a bare `\u{3}` resets the colour without disturbing any
/// bold/italic still in effect.
///
/// ⚠ GREY on grey (14,14), not black on black. Any matching pair hides the text, so the choice is
/// only about what the box looks like to a reader whose client draws one — and grey is the one
/// mono slot that reads as a box on both a dark and a light canvas (4.1:1 / 3.7:1, against 1.3:1
/// for black on dark and 1.1:1 for white on light). Keep in step with the web; a spoiler that
/// looks different in each client is the drift this port exists to avoid.
public enum SpoilerMarkup {
    static let open = "\u{3}14,14"
    static let close = "\u{3}"

    /// The close to use when the very next character is a digit.
    ///
    /// ⚠⚠ A bare `\u{3}` is a colour RESET only when nothing parseable follows it. `\u{3}` then
    /// `5` is colour 5, not a reset and a "5" — so `||spoiler||5 stars` put `…spoiler\u{3}5 stars`
    /// on the wire and every client, ours included, read the digit as the code and DELETED it:
    /// the channel saw " stars" in colour 5, still on the spoiler's background. `||code||1234`
    /// lost two whole characters. Silent, on the wire, unrecoverable.
    ///
    /// `99` is IRC's "default colour", and being two digits it consumes the parser's whole
    /// appetite — the following digit is then plain text. Both halves are specified so the
    /// spoiler's background is cleared too; a bare `\u{3}99` sets only the foreground and would
    /// leave the rest of the line sitting on the grey box.
    ///
    /// Not used unconditionally: it's six bytes heavier, and 99 is less universally understood
    /// than a bare reset. Only the collision needs it.
    ///
    /// ⚠ Not `\u{f}` (reset-all), which would work but also drops any bold or italic still in
    /// effect around the spoiler — the one thing the bare `\u{3}` close was chosen to preserve.
    static let closeBeforeDigit = "\u{3}99,99"

    /// The close that survives whatever comes next.
    ///
    /// ⚠ ASCII `0`–`9` only, matching `IRCFormatting.isDigit` (`0x30...0x39`) exactly — this
    /// predicate has to agree with the parser it's defending against, not with a general notion
    /// of numeral. `Character.isNumber` is true of `٣`, `²`, `②` and `Ⅷ`, none of which any IRC
    /// colour parser will touch, so using it would spend the heavier close (and 99's
    /// less-universal semantics) on text that never needed it — most often Arabic, Persian or
    /// Devanagari, which is a poor place to be needlessly clever.
    static func close(before next: Character?) -> String {
        guard let next, next.isASCII, next.isNumber else { return close }
        return closeBeforeDigit
    }

    /// How `apply` reads `text`, by position: where each `||` pair that makes a spoiler sits,
    /// which `||` stay literal, and where the `\||` escapes are. Character offsets.
    ///
    /// Positional rather than a rewrite so a second writer can make the SAME spoilers out of the
    /// same text: `ColorMarkup` builds them itself on a coloured line, where the user's colour has
    /// to stop at the box and resume after it, which a bare-close rewrite of the encoded line
    /// can't do. Both read this, so the two can't disagree about what is a spoiler.
    struct Layout {
        /// The opening and closing `||` of each spoiler, by the offset of its first `|`.
        var spoilers: [(open: Int, close: Int)] = []
        /// `||` that stay as text — unmatched, or an empty `||||`.
        var literals: [Int] = []
        /// `\||` escapes, by the offset of the backslash.
        var escapes: [Int] = []
    }

    /// `\||` is the only sequence treated specially, and there is deliberately no escape for the
    /// backslash itself: a lone `\` is always literal, so `path\to\file` needs no thought from
    /// the user. The cost is that a literal `\||` cannot be written — judged the better trade,
    /// since `||` is far commoner in real text than `\||`.
    ///
    /// Pairing is non-greedy — the nearest closing `||` wins, so `||a||b||c||` is a spoiler, a
    /// literal `b`, then another spoiler — and an empty pair (`||||`) is left literal. Both match
    /// how Discord treats them, which is where users' expectations come from.
    static func layout(_ chars: [Character]) -> Layout {
        var layout = Layout()
        var delimiters: [Int] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 2 < chars.count, chars[i + 1] == "|", chars[i + 2] == "|" {
                layout.escapes.append(i)
                i += 3
            } else if chars[i] == "|", i + 1 < chars.count, chars[i + 1] == "|" {
                delimiters.append(i)
                i += 2
            } else {
                i += 1
            }
        }
        var d = 0
        while d < delimiters.count {
            // Something between the two — an escape counts — or the opener is just text.
            if d + 1 < delimiters.count, delimiters[d + 1] > delimiters[d] + 2 {
                layout.spoilers.append((delimiters[d], delimiters[d + 1]))
                d += 2
            } else {
                layout.literals.append(delimiters[d])
                d += 1
            }
        }
        return layout
    }

    /// Rewrite every `||spoiler||` pair into IRC spoiler codes, and each `\||` into a literal `||`.
    ///
    /// ⚠ Apply this to a user-authored CHAT body only, and opt in per command — see the note on
    /// `CommandParser`. It must never become something a shared send helper does to everything.
    public static func apply(to text: String) -> String {
        guard text.contains("||") else { return text }
        let chars = Array(text)
        let layout = layout(chars)
        let opens = Dictionary(uniqueKeysWithValues: layout.spoilers.map { ($0.open, $0.close) })
        let escapes = Set(layout.escapes)
        /// The character at `i` as it will read — an escape reads as `|`. Nil for a delimiter or
        /// the end, neither of which can be a digit.
        func reads(at i: Int) -> Character? {
            guard i < chars.count else { return nil }
            if escapes.contains(i) { return "|" }
            if chars[i] == "|", i + 1 < chars.count, chars[i + 1] == "|" { return nil }
            return chars[i]
        }
        var out = ""
        var i = 0
        var closeAt: Int?
        while i < chars.count {
            if let close = opens[i] {
                out += open
                closeAt = close
                i += 2
            } else if i == closeAt {
                // What follows the spoiler decides how it has to be closed — see `close(before:)`.
                out += close(before: reads(at: i + 2))
                closeAt = nil
                i += 2
            } else if escapes.contains(i) {
                out += "||"
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}

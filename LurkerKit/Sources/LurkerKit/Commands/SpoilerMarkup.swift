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
    static func close(before next: Character?) -> String {
        guard let next, next.isNumber else { return close }
        return closeBeforeDigit
    }

    private enum Token {
        case text(String)
        case delimiter
    }

    /// Split into literal-text and `||`-delimiter tokens, resolving `\||` escapes into a literal
    /// `||` inside the text tokens as we go.
    ///
    /// `\||` is the only sequence treated specially, and there is deliberately no escape for the
    /// backslash itself: a lone `\` is always literal, so `path\to\file` needs no thought from
    /// the user. The cost is that a literal `\||` cannot be written — judged the better trade,
    /// since `||` is far commoner in real text than `\||`.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 2 < chars.count, chars[i + 1] == "|", chars[i + 2] == "|" {
                buffer += "||"
                i += 3
                continue
            }
            if chars[i] == "|", i + 1 < chars.count, chars[i + 1] == "|" {
                if !buffer.isEmpty {
                    tokens.append(.text(buffer))
                    buffer = ""
                }
                tokens.append(.delimiter)
                i += 2
                continue
            }
            buffer.append(chars[i])
            i += 1
        }
        if !buffer.isEmpty { tokens.append(.text(buffer)) }
        return tokens
    }

    /// Rewrite every `||spoiler||` pair into IRC spoiler codes.
    ///
    /// Pairing is non-greedy — the nearest closing `||` wins, so `||a||b||c||` is a spoiler, a
    /// literal `b`, then another spoiler — and an empty pair (`||||`) is left literal. Both match
    /// how Discord treats them, which is where users' expectations come from.
    ///
    /// ⚠ Apply this to a user-authored CHAT body only, and opt in per command — see the note on
    /// `CommandParser`. It must never become something a shared send helper does to everything.
    public static func apply(to text: String) -> String {
        guard text.contains("||") else { return text }
        let tokens = tokenize(text)
        var out = ""
        var i = 0
        while i < tokens.count {
            guard case .delimiter = tokens[i] else {
                if case .text(let value) = tokens[i] { out += value }
                i += 1
                continue
            }
            // An opening `||`: gather everything up to the next delimiter.
            var content = ""
            var closeIndex = -1
            for j in (i + 1)..<tokens.count {
                if case .delimiter = tokens[j] {
                    closeIndex = j
                    break
                }
                if case .text(let value) = tokens[j] { content += value }
            }
            if closeIndex != -1, !content.isEmpty {
                // What follows the spoiler decides how it has to be closed — see `close(before:)`.
                // The next character is the first of the next text token, if there is one; a
                // delimiter or the end of the message can't be a digit.
                var next: Character?
                if closeIndex + 1 < tokens.count, case .text(let following) = tokens[closeIndex + 1] {
                    next = following.first
                }
                out += open + content + close(before: next)
                i = closeIndex + 1
            } else {
                // Unmatched, or an empty `||||` — the opening `||` is just literal text.
                out += "||"
                i += 1
            }
        }
        return out
    }
}

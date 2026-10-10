// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// One stretch of composer text in one colour pair — what the colour editor works in. `fg` and
/// `bg` are mIRC slots 0–15, nil for "no colour" (the theme's text, no fill).
public struct ColorSpan: Equatable, Sendable {
    public var text: String
    public var fg: Int?
    public var bg: Int?

    public init(_ text: String, fg: Int? = nil, bg: Int? = nil) {
        self.text = text
        self.fg = fg
        self.bg = bg
    }
}

/// The composer's coloured text ↔ the `\x03` line that goes on the wire.
///
/// The composer never shows a control code: colour lives on the text as an attribute and is
/// written out only here, at the moment the line leaves the field (a send, a synced draft). That
/// keeps the codes out of reach of the caret — a backspace can't eat one digit of `\x0304` and
/// silently turn red into white.
///
/// Only the sixteen palette slots, and only colour. A draft holding anything else (bold, `\x04`
/// truecolour, slot 42) is not something this model can represent, so `decode` declines it and
/// the composer keeps the line as raw text, exactly as it did before colours existed — a draft
/// written on the web loses nothing by passing through iOS.
public enum ColorMarkup {

    /// The line for `spans`, with each change of colour written as one `\x03` code.
    ///
    /// ⚠⚠ Every slot is written as TWO digits, and a foreground-only code grows a `,99` when the
    /// text after it opens with a comma and a digit. Both are the digit trap `SpoilerMarkup`
    /// documents: `\x03` `4` then `2 cats` is colour 42, and `\x0304` then `,5 cats` is red on
    /// blue — the text's own characters read as the code, and deleted from the line.
    ///
    /// A command's verb stays bare. Colour the whole of `/me waves` and the line has to start
    /// with the slash — `\x0304/me waves` is a message that says "/me waves" — so the codes start
    /// after the verb and the whitespace that ends it (a code between the two would be read as
    /// part of the verb).
    public static func encode(_ spans: [ColorSpan]) -> String {
        let spans = keepingVerbBare(spans)
        var out = ""
        var current: (fg: Int?, bg: Int?) = (nil, nil)
        for span in spans where !span.text.isEmpty {
            let next = (fg: span.fg, bg: span.bg)
            if next != current {
                out += code(from: current, to: next, before: span.text)
                current = next
            }
            out += span.text
        }
        return out
    }

    /// The spans `line` reads as, or nil when it holds formatting beyond palette colours — the
    /// caller keeps such a line as raw text rather than drop what it can't show.
    ///
    /// `\x0F` is accepted: with nothing but colour in play it is a colour reset. Slot 99 (IRC's
    /// "default") reads as no colour, which is how `encode` and `SpoilerMarkup` both close.
    public static func decode(_ line: String) -> [ColorSpan]? {
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x02, 0x04, 0x11, 0x16, 0x1D, 0x1E, 0x1F: return nil
            default: continue
            }
        }
        var spans: [ColorSpan] = []
        for run in IRCFormatting.parse(line) {
            guard let fg = slot(run.fg), let bg = slot(run.bg) else { return nil }
            if let last = spans.last, last.fg == fg, last.bg == bg {
                spans[spans.count - 1].text += run.text
            } else {
                spans.append(ColorSpan(run.text, fg: fg, bg: bg))
            }
        }
        return spans
    }

    /// Whether `spans` carry any colour at all — a plain draft is written out untouched.
    public static func isColored(_ spans: [ColorSpan]) -> Bool {
        spans.contains { !$0.text.isEmpty && ($0.fg != nil || $0.bg != nil) }
    }

    // MARK: - Private

    /// A slot `decode` can hold: `.some(nil)` for no colour, `.some(n)` for a palette slot, and
    /// nil for a colour it can't represent.
    private static func slot(_ color: IRCColor?) -> Int?? {
        switch color {
        case nil: return .some(nil)
        case .slot(let index) where (0...15).contains(index): return .some(index)
        case .slot(99): return .some(nil)
        default: return nil
        }
    }

    private static func code(from current: (fg: Int?, bg: Int?), to next: (fg: Int?, bg: Int?), before text: String) -> String {
        switch (next.fg, next.bg) {
        case (nil, nil):
            // A bare `\x03` resets both — unless a digit follows, which it would swallow.
            return SpoilerMarkup.close(before: text.first)
        case (let fg?, nil):
            // A bare foreground keeps whatever background is in effect, so dropping one has to
            // say so; and a leading `,digit` in the text would otherwise be read as one.
            let clearsBackground = current.bg != nil || opensWithCommaDigit(text)
            return "\u{3}" + two(fg) + (clearsBackground ? ",99" : "")
        case (let fg, let bg?):
            return "\u{3}" + two(fg ?? 99) + "," + two(bg)
        }
    }

    private static func two(_ slot: Int) -> String {
        slot < 10 ? "0\(slot)" : "\(slot)"
    }

    private static func opensWithCommaDigit(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.prefix(2))
        return scalars.count == 2 && scalars[0] == "," && (0x30...0x39).contains(scalars[1].value)
    }

    /// `spans` with the colour taken off a leading `/verb ` — see `encode`. `//` is the escape for
    /// a line that starts with a slash, so it's text and keeps its colour.
    private static func keepingVerbBare(_ spans: [ColorSpan]) -> [ColorSpan] {
        let text = spans.map(\.text).joined()
        guard text.hasPrefix("/"), !text.hasPrefix("//") else { return spans }
        let verb = text.prefix { !$0.isWhitespace }
        let gap = text.dropFirst(verb.count).prefix { $0.isWhitespace }
        var bare = verb.count + gap.count
        var out: [ColorSpan] = []
        for span in spans {
            guard bare > 0 else {
                out.append(span)
                continue
            }
            let head = span.text.prefix(bare)
            bare -= head.count
            out.append(ColorSpan(String(head)))
            let tail = span.text.dropFirst(head.count)
            if !tail.isEmpty { out.append(ColorSpan(String(tail), fg: span.fg, bg: span.bg)) }
        }
        return out
    }
}

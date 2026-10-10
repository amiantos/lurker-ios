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

/// The composer's coloured text ↔ the `\x03` line it holds, syncs and sends.
///
/// The composer never shows a control code: colour lives on the text as an attribute and is
/// written out only here. That keeps the codes out of reach of the caret — a backspace can't eat
/// one digit of `\x0304` and silently turn red into white.
///
/// **One line format, for the draft and the send alike.** It's what was typed — `||` stay `||` —
/// with the colour written in. Spoilers are made later, on the chat body, by `chatBody`, as they
/// always were. So a refused send, a synced draft and a restored draft are all the same string,
/// and `decode` gives back exactly what `encode` was handed.
///
/// Only the sixteen palette slots, and only colour. A line holding anything else (bold, `\x04`
/// truecolour, slot 42) is not something this model can represent, so `decode` declines it and
/// the composer keeps it as raw text, exactly as it did before colours existed — a draft written
/// on the web loses nothing by passing through iOS.
public enum ColorMarkup {

    /// The line for `spans`.
    ///
    /// ⚠⚠ Every slot is written as TWO digits, and a foreground-only code grows a `,99` when the
    /// text after it opens with a comma and a digit. Both are the digit trap `SpoilerMarkup`
    /// documents: `\x03` `4` then `2 cats` is colour 42, and `\x0304` then `,5 cats` is red on
    /// blue — the text's own characters read as the code, and deleted from the line.
    ///
    /// ⚠⚠ Colour goes on a CHAT BODY only — the line, a `//` line past its escape, and the text of
    /// `/me`, `/shrug`, `/msg`, `/notice`, `/topic`, `/part`, `/kick` and `/away` (`bareHead`).
    /// A verb, a target, a channel, a flag, a password to `/ns`: a code in any of those is a
    /// different word, so the head stays bare and every other command goes out with no colour.
    ///
    /// ⚠ A coloured line ends in a reset before each line break, and its colour is written again
    /// after it. A server without multiline sends each line as its own message, which a code
    /// doesn't carry into; and a reader of the joined text (`decode`, the list) carries the state
    /// across, so a plain line after a red one has to say so.
    public static func encode(_ spans: [ColorSpan]) -> String {
        let text = spans.map(\.text).joined()
        guard let bare = bareHead(of: text) else { return text }
        var cells = cells(of: spans)
        for index in 0..<min(bare, cells.count) { cells[index].fg = nil; cells[index].bg = nil }
        return write(cells)
    }

    /// The spans `line` reads as, or nil when the composer can't hold it as colour — the caller
    /// keeps such a line as raw text rather than drop or change what it can't show.
    ///
    /// Declined, so that `encode` always writes back what was decoded:
    /// - any formatting but palette colour, including a slot outside 0–15 that no text follows;
    /// - a code inside the bare head (`encode`): `\x0304/me waves` is red TEXT, and `/j\x0304oin`
    ///   is an unknown command — shown without its code, either would send as a different line;
    /// - colour on a command that has no chat body, which `encode` would drop.
    ///
    /// `\x0F` is accepted: with nothing but colour in play it is a colour reset. Slot 99 (IRC's
    /// "default") reads as no colour.
    public static func decode(_ line: String) -> [ColorSpan]? {
        guard let spans = colorSpans(line) else { return nil }
        let text = spans.map(\.text).joined()
        guard text != line else { return spans }
        guard let bare = bareHead(of: text) else { return isColored(spans) ? nil : spans }
        // The line has to open with the head exactly — no code before it or inside it.
        guard line.hasPrefix(String(text.prefix(bare))) else { return nil }
        return spans
    }

    /// Whether `spans` carry any colour at all.
    public static func isColored(_ spans: [ColorSpan]) -> Bool {
        spans.contains { !$0.text.isEmpty && ($0.fg != nil || $0.bg != nil) }
    }

    /// A chat body with its `||spoilers||` made — `CommandParser.chatBody`.
    ///
    /// Plain text goes to `SpoilerMarkup.apply`, byte for byte as before. A coloured body is
    /// rebuilt span by span instead: that rewrite closes a spoiler with a bare reset, which would
    /// drop the colour after the box, and a colour inside the box would show the hidden text.
    /// Here the box is grey on grey whatever it was, and the colour around it resumes after it.
    /// Where the pairs are is `SpoilerMarkup.layout`'s answer, so both agree on every line — and
    /// it's read from the characters alone, so a colour change between two `|` can't hide a pair.
    static func chatBody(_ text: String) -> String {
        guard text.contains("|"), text.unicodeScalars.contains(where: { $0.value == 0x03 }),
              let spans = colorSpans(text), isColored(spans)
        else { return SpoilerMarkup.apply(to: text) }
        let body = cells(of: spans)
        let layout = SpoilerMarkup.layout(body.map(\.char))
        guard !layout.spoilers.isEmpty || !layout.escapes.isEmpty else { return text }
        var dropped = Set<Int>()
        var hidden = Set<Int>()
        for pair in layout.spoilers {
            dropped.formUnion([pair.open, pair.open + 1, pair.close, pair.close + 1])
            hidden.formUnion((pair.open + 2)..<pair.close)
        }
        // `\||` reads as a literal `||`: the backslash goes.
        dropped.formUnion(layout.escapes)
        var out: [Cell] = []
        for (index, cell) in body.enumerated() where !dropped.contains(index) {
            out.append(hidden.contains(index)
                ? Cell(char: cell.char, fg: SpoilerMarkup.slot, bg: SpoilerMarkup.slot)
                : cell)
        }
        return write(out)
    }

    // MARK: - Private

    /// One character and its colour — the working form, so a head or a spoiler can be cut at
    /// any character rather than only at span edges.
    private struct Cell {
        var char: Character
        var fg: Int?
        var bg: Int?
    }

    private static func cells(of spans: [ColorSpan]) -> [Cell] {
        spans.flatMap { span in span.text.map { Cell(char: $0, fg: span.fg, bg: span.bg) } }
    }

    /// `line` as palette-colour spans, or nil when it holds anything else. No command rules.
    ///
    /// Every `\x03` code is checked where it stands, not through the runs it produces: a code no
    /// text follows (`…\x0342`) makes no run, and checking runs alone would accept the line and
    /// silently drop the colour it leaves in effect.
    private static func colorSpans(_ line: String) -> [ColorSpan]? {
        let scalars = Array(line.unicodeScalars)
        var i = 0
        while i < scalars.count {
            switch scalars[i].value {
            case 0x02, 0x04, 0x11, 0x16, 0x1D, 0x1E, 0x1F:
                return nil
            case 0x03:
                i += 1
                var slots: [Int] = []
                var digits = ""
                while digits.count < 2, i < scalars.count, isDigit(scalars[i]) {
                    digits.unicodeScalars.append(scalars[i]); i += 1
                }
                if let fg = Int(digits) {
                    slots.append(fg)
                    if i + 1 < scalars.count, scalars[i] == ",", isDigit(scalars[i + 1]) {
                        i += 1
                        var bg = ""
                        while bg.count < 2, i < scalars.count, isDigit(scalars[i]) {
                            bg.unicodeScalars.append(scalars[i]); i += 1
                        }
                        slots.append(Int(bg) ?? 99)
                    }
                }
                guard slots.allSatisfy({ (0...15).contains($0) || $0 == 99 }) else { return nil }
            default:
                i += 1
            }
        }
        var spans: [ColorSpan] = []
        for run in IRCFormatting.parse(line) {
            let fg = slot(run.fg), bg = slot(run.bg)
            if let last = spans.last, last.fg == fg, last.bg == bg {
                spans[spans.count - 1].text += run.text
            } else {
                spans.append(ColorSpan(run.text, fg: fg, bg: bg))
            }
        }
        return spans
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { (0x30...0x39).contains(scalar.value) }

    /// A slot `colorSpans` already vetted: 0–15 as itself, 99 as no colour.
    private static func slot(_ color: IRCColor?) -> Int? {
        if case .slot(let index)? = color, (0...15).contains(index) { return index }
        return nil
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
        return scalars.count == 2 && scalars[0] == "," && isDigit(scalars[1])
    }

    /// How many leading characters stay bare, or nil when the line is a command with no chat body,
    /// which takes no colour at all. See `encode`.
    ///
    /// Each command names how many of its leading words are not its text. Channel-shaped words
    /// count as bare wherever the command takes an optional channel — the parser asks open
    /// buffers to decide (`leadsWithChannel`), and a reason's first word left uncoloured costs
    /// nothing, where a coloured channel name is a different channel.
    private static func bareHead(of text: String) -> Int? {
        guard text.hasPrefix("/") else { return 0 }
        // `//` is the escape: a message with one slash taken off. Both stay bare — a code between
        // them would make the line a command named after the code.
        if text.hasPrefix("//") { return 2 }
        let verb = text.dropFirst().prefix { !$0.isWhitespace }
        let words = text.dropFirst(1 + verb.count).split(whereSeparator: \.isWhitespace)
        let channelFirst = words.first.map { ChannelName.isChannelTarget(String($0)) } ?? false
        let bare: Int
        switch verb.lowercased() {
        case "me", "shrug": bare = 0
        case "msg", "query", "notice": bare = 1
        case "topic", "part", "leave", "p": bare = channelFirst ? 1 : 0
        case "kick": bare = channelFirst ? 2 : 1
        case "away": bare = words.prefix { $0.hasPrefix("-") }.count
        default: return nil
        }
        // The verb, then each bare word with the whitespace after it: a code welded onto the end
        // of a word is part of the word (`/msg bob\x0304 hi` messages "bob\x0304").
        var rest = text.dropFirst(1 + verb.count)
        var length = 1 + verb.count
        for word in 0...bare {
            if word > 0 {
                let bareWord = rest.prefix { !$0.isWhitespace }
                length += bareWord.count
                rest = rest.dropFirst(bareWord.count)
            }
            let gap = rest.prefix { $0.isWhitespace }
            length += gap.count
            rest = rest.dropFirst(gap.count)
        }
        return length
    }

    /// Line breaks as the server splits on them (`splitSay`: `\r\n`, `\r`, `\n`). Swift reads
    /// `\r\n` as ONE character, which a test for `"\n"` alone would miss.
    private static func isLineBreak(_ char: Character) -> Bool {
        char == "\n" || char == "\r" || char == "\r\n"
    }

    private static func write(_ cells: [Cell]) -> String {
        var out = ""
        var current: (fg: Int?, bg: Int?) = (nil, nil)
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            if isLineBreak(cell.char) {
                // A reset the joined text can read, then plain until the next line colours itself.
                if current != (nil, nil) { out += SpoilerMarkup.close }
                out.append(cell.char)
                current = (nil, nil)
                index += 1
                continue
            }
            let state = (fg: cell.fg, bg: cell.bg)
            if state != current {
                // What follows the code — what the digit and comma traps look at.
                var run = ""
                var end = index
                while end < cells.count, run.count < 2,
                      cells[end].fg == cell.fg, cells[end].bg == cell.bg, !isLineBreak(cells[end].char) {
                    run.append(cells[end].char)
                    end += 1
                }
                out += code(from: current, to: state, before: run)
                current = state
            }
            out.append(cell.char)
            index += 1
        }
        return out
    }
}

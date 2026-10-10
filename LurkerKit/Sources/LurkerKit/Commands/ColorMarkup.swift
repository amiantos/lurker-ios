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
    /// ⚠⚠ Colour goes on a CHAT BODY only — the line, a `//` line past its escape, and the text of
    /// `/me`, `/shrug`, `/msg` and `/notice` — the same places `CommandParser.chatBody` rewrites
    /// spoilers. A verb, a `/msg` target, a channel to `/join`, a password to `/ns`: a code in any
    /// of those is a different word, so every other command goes out with no colour at all.
    ///
    /// ⚠ Spoilers are built here, not left to the `||` rewrite that runs on the sent line: that
    /// rewrite closes with a bare reset, which would drop the user's colour after the box, and a
    /// colour inside the box would show the hidden text. The `||` that stay text are written as
    /// `\||`, so the rewrite that still runs finds nothing left to pair.
    ///
    /// ⚠ The colour is written again after each newline: a server without multiline sends each
    /// line as its own message, and a code doesn't carry from one message to the next.
    public static func encode(_ spans: [ColorSpan]) -> String {
        let text = spans.map(\.text).joined()
        guard let bare = bareLength(of: text) else { return text }
        var cells: [Cell] = spans.flatMap { span in span.text.map { Cell(char: $0, fg: span.fg, bg: span.bg) } }
        for index in 0..<min(bare, cells.count) { cells[index].fg = nil; cells[index].bg = nil }
        cells = Array(cells.prefix(bare)) + spoilered(Array(cells.dropFirst(bare)))
        return write(cells)
    }

    /// The line for `spans` as a DRAFT — what the composer holds, for syncing and restoring, not
    /// what it sends. Colour only: `||` stay as typed, since a draft converted to spoiler codes
    /// would come back into the field as a grey box with the delimiters gone, and every command
    /// keeps its colour, since nothing runs it yet.
    ///
    /// The verb stays bare even so — `\x0304/me waves` isn't a command, and `decode` declines it.
    public static func encodeDraft(_ spans: [ColorSpan]) -> String {
        let text = spans.map(\.text).joined()
        var cells: [Cell] = spans.flatMap { span in span.text.map { Cell(char: $0, fg: span.fg, bg: span.bg) } }
        let bare = text.hasPrefix("//") ? 2 : text.hasPrefix("/") ? verbLength(of: text) : 0
        for index in 0..<min(bare, cells.count) { cells[index].fg = nil; cells[index].bg = nil }
        return write(cells)
    }

    /// The spans `line` reads as, or nil when it holds formatting beyond palette colours — the
    /// caller keeps such a line as raw text rather than drop what it can't show.
    ///
    /// `\x0F` is accepted: with nothing but colour in play it is a colour reset. Slot 99 (IRC's
    /// "default") reads as no colour, which is how `encode` and `SpoilerMarkup` both close.
    ///
    /// ⚠ A code in front of a leading slash is declined too. `\x0304/me waves` is red TEXT —
    /// it doesn't start with the slash — but as red "/me waves" in the field it would send as the
    /// command. No colour on the field can say "this slash is text", so the line stays raw.
    public static func decode(_ line: String) -> [ColorSpan]? {
        if !line.hasPrefix("/"), IRCFormatting.strip(line).hasPrefix("/") { return nil }
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

    /// One character and its colour — the encoder's working form, so spoilers and the bare head
    /// can be cut at any character, not just at span edges.
    private struct Cell {
        var char: Character
        var fg: Int?
        var bg: Int?
    }

    /// How many leading characters must stay bare, or nil when the line is a command whose text
    /// isn't a chat body and takes no colour at all. See `encode`.
    private static let bodyCommands = ["me": 0, "shrug": 0, "msg": 1, "query": 1, "notice": 1]

    private static func bareLength(of text: String) -> Int? {
        guard text.hasPrefix("/") else { return 0 }
        // `//` is the escape: a message with one slash taken off. Both stay bare — a code between
        // them would make the line a command named after the code.
        if text.hasPrefix("//") { return 2 }
        let verb = text.dropFirst().prefix { !$0.isWhitespace }
        guard let words = bodyCommands[verb.lowercased()] else { return nil }
        return verbLength(of: text, bareWords: words)
    }

    /// The `/verb`, the whitespace after it, and `bareWords` more words each with theirs.
    private static func verbLength(of text: String, bareWords words: Int = 0) -> Int {
        let verb = text.dropFirst().prefix { !$0.isWhitespace }
        // The verb, then each bare word with the whitespace after it: a code welded onto the end
        // of a word is part of the word (`/msg bob\x0304 hi` messages "bob\x0304").
        var rest = text.dropFirst(1 + verb.count)
        var length = 1 + verb.count
        for word in 0...words {
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

    /// `body` with its spoilers made: each pair's `||` dropped and its text grey on grey
    /// (`SpoilerMarkup.open`), and each `||` that stays text written as `\||`. Where the pairs are
    /// is `SpoilerMarkup.layout`'s answer, so this and the rewrite agree on every line.
    private static func spoilered(_ body: [Cell]) -> [Cell] {
        let layout = SpoilerMarkup.layout(body.map(\.char))
        guard !layout.spoilers.isEmpty || !layout.literals.isEmpty else { return body }
        var out: [Cell] = []
        var dropped = Set<Int>()
        var hidden = Set<Int>()
        for pair in layout.spoilers {
            dropped.formUnion([pair.open, pair.open + 1, pair.close, pair.close + 1])
            hidden.formUnion((pair.open + 2)..<pair.close)
        }
        let literals = Set(layout.literals)
        for (index, cell) in body.enumerated() where !dropped.contains(index) {
            if literals.contains(index) { out.append(Cell(char: "\\", fg: cell.fg, bg: cell.bg)) }
            out.append(hidden.contains(index) ? Cell(char: cell.char, fg: spoilerSlot, bg: spoilerSlot) : cell)
        }
        return out
    }

    /// `SpoilerMarkup.open`'s colour, grey on grey.
    private static let spoilerSlot = 14

    private static func write(_ cells: [Cell]) -> String {
        var out = ""
        var current: (fg: Int?, bg: Int?) = (nil, nil)
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            if cell.char == "\n" {
                // A new line is a new message on a server without multiline: plain until it's
                // coloured again, which the next character does.
                out.append(cell.char)
                current = (nil, nil)
                index += 1
                continue
            }
            let state = (fg: cell.fg, bg: cell.bg)
            if state != current {
                // What follows the code, up to the next change — what the digit and comma traps
                // look at.
                var run = ""
                var end = index
                while end < cells.count, cells[end].fg == cell.fg, cells[end].bg == cell.bg, run.count < 2 {
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

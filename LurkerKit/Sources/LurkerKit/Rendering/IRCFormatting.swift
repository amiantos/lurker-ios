// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A colour a formatting code named: a mIRC palette slot from `\x03`, or a 24-bit value from
/// `\x04` truecolour. Both are literal — neither is mapped through the theme.
public enum IRCColor: Hashable, Sendable {
    /// A raw mIRC index (0–99). The UI paints 0–15 and leaves the rest uncoloured.
    case slot(Int)
    /// `0xRRGGBB`.
    case rgb(UInt32)
}

/// One run of message text sharing the same mIRC formatting.
public struct FormattingRun: Equatable, Sendable {
    public let text: String
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let strike: Bool
    /// `\x16`. Kept as a flag rather than applied here, because the renderer swaps `fg` and `bg`
    /// and a side the run leaves unset swaps with the theme's own colour, which only it knows.
    public let reverse: Bool
    public let fg: IRCColor?
    public let bg: IRCColor?

    /// Whether the run's text is invisible: foreground and background the same colour, which is
    /// the IRC spoiler convention (and how ASCII art fills a block). The renderer draws it as a
    /// tap-to-reveal box and link previews skip its URLs, so both ask here — the web's
    /// `hidesText`. Reverse changes nothing about an equal pair.
    ///
    /// ⚠ The colour has to be one the renderer can paint. Slots above 15 draw nothing, so such a
    /// run is not hidden and its links are ordinary links — and since `SpoilerMarkup` closes a
    /// spoiler with `\u{3}99,99` when a digit follows, the tail of those messages IS a 99,99 run.
    /// Without the bound, the rest of the line after a spoiler would become one: a box that
    /// reveals nothing, and a URL anywhere in it silently losing its preview.
    public var hidesText: Bool {
        guard let fg, fg == bg else { return false }
        if case .slot(let index) = fg { return index <= 15 }
        return true
    }

    /// What the run is drawn in: its text colour and its fill, given `fg`/`bg` already resolved
    /// by the caller (nil for a slot it can't paint) and the colours plain text gets — generic
    /// so the rule is decided, and tested, here rather than in the renderer.
    ///
    /// Reverse (`\x16`) swaps the pair. A side the run leaves unset, or names with a slot that
    /// can't be painted, is the theme's own — so reversed plain text reads as the theme inverted
    /// rather than as nothing. `text` is whatever the run would otherwise be drawn in, which is
    /// how a reversed `/me` comes out as a block of the nick's colour. An equal pair is a spoiler,
    /// and reverse changes nothing about it.
    public func paint<Color>(
        fg: Color?, bg: Color?, text: Color, canvas: Color
    ) -> (ink: Color, fill: Color?) {
        guard reverse, !hidesText else { return (fg ?? text, bg) }
        return (bg ?? canvas, fg ?? text)
    }
}

/// Byte-level mIRC control-code parser, mirroring the web client's `parseIrcFormatting`.
/// The server stores raw IRC text with the control bytes intact; this turns it into runs.
public enum IRCFormatting {

    /// `text` with its mIRC control codes removed — what the line *reads* as, rather than what
    /// came over the wire.
    ///
    /// For showing a message somewhere that can't render its formatting: `\u{03}04ALERT\u{03}` is
    /// red "ALERT" in the list, but pasted into a plain label it reads `04ALERT`, because the 0x03
    /// is invisible and the color digits are not.
    public static func strip(_ text: String) -> String {
        parse(text).map(\.text).joined()
    }

    public static func parse(_ text: String) -> [FormattingRun] {
        var runs: [FormattingRun] = []
        var current = ""
        var bold = false, italic = false, underline = false, strike = false, reverse = false
        var fg: IRCColor?, bg: IRCColor?

        func flush() {
            guard !current.isEmpty else { return }
            runs.append(FormattingRun(
                text: current, bold: bold, italic: italic, underline: underline, strike: strike,
                reverse: reverse, fg: fg, bg: bg
            ))
            current = ""
        }

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let value = scalars[i].value
            switch value {
            case 0x02: flush(); bold.toggle(); i += 1
            case 0x1D: flush(); italic.toggle(); i += 1
            case 0x1F: flush(); underline.toggle(); i += 1
            case 0x1E: flush(); strike.toggle(); i += 1
            case 0x16: flush(); reverse.toggle(); i += 1
            case 0x11: flush(); i += 1 // monospace: consumed, the list is already monospaced
            case 0x0F: // reset
                flush()
                bold = false; italic = false; underline = false; strike = false; reverse = false
                fg = nil; bg = nil
                i += 1
            case 0x03: // color: \x03[FG[,BG]]
                flush()
                i += 1
                let (foreground, consumed) = readDigits(scalars, from: i)
                if foreground == nil {
                    // Bare \x03 resets both foreground and background.
                    fg = nil
                    bg = nil
                } else {
                    fg = foreground.map(IRCColor.slot)
                    i = consumed
                    // Optional ,BG. A bare FG (no ,BG) leaves the existing bg untouched.
                    if i + 1 < scalars.count, scalars[i].value == 0x2C, isDigit(scalars[i + 1]) {
                        i += 1 // consume comma
                        let (background, afterBg) = readDigits(scalars, from: i)
                        bg = background.map(IRCColor.slot)
                        i = afterBg
                    }
                    continue
                }
            case 0x04: // truecolour: \x04[RRGGBB[,RRGGBB]]
                flush()
                i += 1
                // Exactly six hex for each colour, as the web and the server's `FORMAT_RE` take
                // it. Anything shorter is no colour at all: a bare \x04 that resets both, like
                // a bare \x03, with whatever followed it left as text.
                if let foreground = readHex(scalars, from: i) {
                    fg = .rgb(foreground)
                    i += 6
                    // A foreground alone keeps the background in effect, as with \x03 — and a
                    // comma without a full colour after it is text.
                    if i < scalars.count, scalars[i].value == 0x2C,
                       let background = readHex(scalars, from: i + 1) {
                        bg = .rgb(background)
                        i += 7
                    }
                } else {
                    fg = nil
                    bg = nil
                }
            default:
                current.unicodeScalars.append(scalars[i])
                i += 1
            }
        }
        flush()
        return runs
    }

    /// Where the `visibleOffset`-th *visible* character of `text` begins inside `text` itself —
    /// the inverse of `strip`, for when you matched against the stripped form and now have to
    /// slice the original.
    ///
    /// The web's `rawIndexForVisibleOffset` (`shared/textMatch.ts`), ported for its one caller:
    /// relay re-attribution (#277) matches a bot's envelope against stripped text and then has to
    /// hand back the relayed message with its OWN colours and bold intact.
    ///
    /// Offsets in and out are UTF-16 units — `NSRange`'s currency, and JavaScript's, so a capture
    /// range from `NSRegularExpression` can be handed straight in and the answer handed straight
    /// to `NSString.substring(from:)`. An offset past the end answers the end.
    ///
    /// ⚠ This is a SECOND scanner over the control codes `parse` consumes. Should the two ever
    /// disagree about what counts as formatting, a slice lands mid-code and the recovered text
    /// opens with stray colour digits. `RelayEnvelopeTests.testRawIndexAgreesWithStrip` pins them
    /// to each other over a corpus rather than leaving it to inspection.
    public static func rawIndex(in text: String, visibleOffset: Int) -> Int {
        guard visibleOffset > 0 else { return 0 }
        let units = Array(text.utf16)
        var visible = 0
        var i = 0
        while i < units.count {
            if visible >= visibleOffset { return i }
            if let length = controlLength(units, at: i) {
                i += length
            } else {
                visible += 1
                i += 1
            }
        }
        return units.count
    }

    /// The length, in UTF-16 units, of the mIRC control sequence starting at `i` — or nil when
    /// `units[i]` doesn't start one.
    ///
    /// Every code is ASCII, so walking UTF-16 units lands on exactly the same positions `parse`'s
    /// scalar walk does; only the *content* between codes is counted differently, and that's the
    /// caller's business rather than this function's.
    private static func controlLength(_ units: [UInt16], at i: Int) -> Int? {
        switch units[i] {
        // The toggles, the reset, and monospace, which `parse` consumes without rendering.
        case 0x02, 0x0F, 0x11, 0x16, 0x1D, 0x1E, 0x1F: return 1
        case 0x03:
            // \x03[FG[,BG]]. A bare \x03 is a reset and consumes nothing more; the background half
            // needs a digit after the comma, or the comma is text (`\x0304,not-a-bg`).
            var j = skip(units, from: i + 1, limit: 2, member: isDigit)
            guard j > i + 1 else { return 1 }
            if j + 1 < units.count, units[j] == 0x2C, isDigit(units[j + 1]) {
                j = skip(units, from: j + 1, limit: 2, member: isDigit)
            }
            return j - i
        case 0x04:
            // \x04[RRGGBB[,RRGGBB]] — exactly six hex per colour, or the code is a bare \x04 and
            // consumes nothing more. Likewise the comma is text unless a full colour follows it.
            guard isHex6(units, at: i + 1) else { return 1 }
            var j = i + 7
            if j < units.count, units[j] == 0x2C, isHex6(units, at: j + 1) { j += 7 }
            return j - i
        default: return nil
        }
    }

    /// Advance past up to `limit` units satisfying `member`, returning the index just past them.
    private static func skip(
        _ units: [UInt16], from start: Int, limit: Int, member: (UInt16) -> Bool
    ) -> Int {
        var i = start
        var count = 0
        while i < units.count, count < limit, member(units[i]) {
            i += 1
            count += 1
        }
        return i
    }

    /// Read up to two ASCII digits from `start`; returns the value (nil if none) and the
    /// index just past them.
    private static func readDigits(_ scalars: [Unicode.Scalar], from start: Int) -> (Int?, Int) {
        var digits = ""
        var i = start
        while i < scalars.count, digits.count < 2, isDigit(scalars[i]) {
            digits.unicodeScalars.append(scalars[i])
            i += 1
        }
        return (digits.isEmpty ? nil : Int(digits), i)
    }

    /// The `0xRRGGBB` spelled by exactly six ASCII hex digits at `start`, or nil when fewer are
    /// there.
    private static func readHex(_ scalars: [Unicode.Scalar], from start: Int) -> UInt32? {
        guard start + 6 <= scalars.count else { return nil }
        var value: UInt32 = 0
        for scalar in scalars[start..<start + 6] {
            guard isHex(scalar), let digit = Character(scalar).hexDigitValue else { return nil }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }

    private static func isHex(_ s: Unicode.Scalar) -> Bool {
        isDigit(s) || (s.value >= 0x41 && s.value <= 0x46) || (s.value >= 0x61 && s.value <= 0x66)
    }

    // The UTF-16 halves of the same two tests, for `controlLength`'s walk.
    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

    private static func isHex(_ u: UInt16) -> Bool {
        isDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
    }

    private static func isHex6(_ units: [UInt16], at start: Int) -> Bool {
        skip(units, from: start, limit: 6, member: isHex) == start + 6
    }
}

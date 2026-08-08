// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// One run of message text sharing the same mIRC formatting. `fg`/`bg` are raw mIRC color
/// indices (0–98); the UI maps them to actual colors (indices 16+ render uncolored).
public struct FormattingRun: Equatable, Sendable {
    public let text: String
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let strike: Bool
    public let fg: Int?
    public let bg: Int?
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
        var bold = false, italic = false, underline = false, strike = false
        var fg: Int?, bg: Int?

        func flush() {
            guard !current.isEmpty else { return }
            runs.append(FormattingRun(
                text: current, bold: bold, italic: italic, underline: underline, strike: strike, fg: fg, bg: bg
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
            case 0x11, 0x16: flush(); i += 1 // monospace / reverse: consumed, not rendered
            case 0x0F: // reset
                flush()
                bold = false; italic = false; underline = false; strike = false
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
                    fg = foreground
                    i = consumed
                    // Optional ,BG. A bare FG (no ,BG) leaves the existing bg untouched.
                    if i + 1 < scalars.count, scalars[i].value == 0x2C, isDigit(scalars[i + 1]) {
                        i += 1 // consume comma
                        let (background, afterBg) = readDigits(scalars, from: i)
                        bg = background
                        i = afterBg
                    }
                    continue
                }
            case 0x04: // truecolor \x04hex6[,hex6]: consumed and dropped (not rendered)
                flush()
                i = skipHex(scalars, from: i + 1)
                if i < scalars.count, scalars[i].value == 0x2C { i = skipHex(scalars, from: i + 1) }
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
        // The toggles, the reset, and the two `parse` consumes without rendering.
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
            // \x04RRGGBB[,RRGGBB] — truecolor, consumed and dropped. The comma goes whether or not
            // hex follows it, exactly as `parse` does.
            var j = skip(units, from: i + 1, limit: 6, member: isHex)
            if j < units.count, units[j] == 0x2C { j = skip(units, from: j + 1, limit: 6, member: isHex) }
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

    /// Skip up to six ASCII hex digits from `start`; returns the index just past them.
    private static func skipHex(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start
        var count = 0
        while i < scalars.count, count < 6, isHex(scalars[i]) {
            i += 1
            count += 1
        }
        return i
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
}

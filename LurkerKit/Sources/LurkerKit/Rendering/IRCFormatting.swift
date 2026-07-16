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
}

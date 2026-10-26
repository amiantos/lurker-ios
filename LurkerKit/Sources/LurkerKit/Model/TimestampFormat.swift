// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The web's timestamp formats (`vue_client/src/utils/timestamp.ts`, `formatTimestamp`), ported
/// token for token so a format set in a browser renders the same string here (lurker#1179).
///
/// Not mapped onto a `DateFormatter` pattern: the two token languages disagree (`DD` is the day
/// of the year there, `a` is always `AM`), and a translation would drift the first time either
/// side grew a token.
///
/// The tokens: `YYYY` year, `MM` month, `DD` day, `HH` / `H` 24-hour padded / unpadded, `hh` / `h`
/// 12-hour, `mm` minutes, `ss` seconds, `a` am/pm, `A` AM/PM. Everything else passes through,
/// with no escape syntax — a letter that is a token is substituted wherever it stands, as on the
/// web ("at h:mm" reads "pmt 1:05").
public enum TimestampFormat {
    /// Longest first within each prefix, so `HH` wins over `H` and `hh` over `h` — the order of
    /// the web's alternation, which takes the first alternative that matches at each position.
    private static let tokens = ["YYYY", "MM", "DD", "HH", "H", "hh", "h", "mm", "ss", "a", "A"]

    /// Gregorian in the device's time zone, whatever calendar the device is set to. The web's
    /// `Date` is always Gregorian, and a phone set to the Buddhist or Japanese calendar would
    /// otherwise print a different year for the same line.
    ///
    /// One instance, built once, on the autoupdating zone: it follows the device across a time
    /// zone change while the app stays alive, as the `DateFormatter` it replaced did.
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    /// `date` in `format`, or "" for an empty format.
    public static func string(_ date: Date, format: String, calendar: Calendar = calendar) -> String {
        guard !format.isEmpty else { return "" }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let h24 = parts.hour ?? 0
        // 0 and 12 both read 12; 13–23 wrap to 1–11.
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        func padded(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        func value(of token: String) -> String {
            switch token {
            case "YYYY": "\(parts.year ?? 0)"
            case "MM": padded(parts.month)
            case "DD": padded(parts.day)
            case "HH": padded(h24)
            case "H": "\(h24)"
            case "hh": padded(h12)
            case "h": "\(h12)"
            case "mm": padded(parts.minute)
            case "ss": padded(parts.second)
            case "a": h24 < 12 ? "am" : "pm"
            default: h24 < 12 ? "AM" : "PM"
            }
        }
        // By scalar, as the web's regex walks code units: a token letter followed by a combining
        // mark is still that letter.
        var out = ""
        var rest = format.unicodeScalars[...]
        while let first = rest.first {
            if let token = tokens.first(where: { rest.starts(with: $0.unicodeScalars) }) {
                out += value(of: token)
                rest = rest.dropFirst(token.unicodeScalars.count)
            } else {
                out.unicodeScalars.append(first)
                rest = rest.dropFirst()
            }
        }
        return out
    }

    public static let compactTimeKey = "look.buffer.time_format_compact"
    public static let compactDateKey = "look.buffer.date_format_compact"

    /// A compact-layout line's time: `look.buffer.time_format_compact`, with
    /// `look.buffer.date_format_compact` before it on a line from a day other than today
    /// (lurker#1237), as the web's `MessageList` builds it. Nil when the time format is empty,
    /// which hides the time — and the date with it.
    ///
    /// `withDate: false` for a screen that already says the day, such as the highlights feed under
    /// its day headers.
    public static func compact(
        _ date: Date, settings: Settings, withDate: Bool = true, now: Date = Date(), calendar: Calendar = calendar
    ) -> String? {
        let time = string(date, format: settings.string(compactTimeKey, default: "HH:mm"), calendar: calendar)
        guard !time.isEmpty else { return nil }
        let dateFormat = withDate ? settings.string(compactDateKey, default: "YYYY-MM-DD") : ""
        guard !dateFormat.isEmpty, !calendar.isDate(date, inSameDayAs: now) else { return time }
        return "\(string(date, format: dateFormat, calendar: calendar)) \(time)"
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What the composer's away strip says (#135): "Away" in bold, then " since 2:32 PM · lunch".
///
/// Built only from an away that is `active`. `since` and `message` outlive `/back` on purpose,
/// so the dividers can draw the finished pair (see `AwayState`) — an indicator that read them
/// directly would stay up after you came back.
public struct AwayStrip: Equatable, Sendable {
    /// "Away", or "Auto-away" when the server set it from idle — the case where you'd least
    /// know why you're marked away.
    public let lead: String
    /// When, and the reason if there is one: " since 2:32 PM · lunch".
    public let detail: String

    public init(lead: String, detail: String) {
        self.lead = lead
        self.detail = detail
    }

    /// The strip for `away`, or nil when there's nothing to show.
    ///
    /// ⚠ No reason is still away. The web's `awayLabel` returns nothing in that case, which
    /// would hide the strip for the most common spelling of `/away`.
    public static func make(
        _ away: AwayState?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> AwayStrip? {
        guard let away, away.active else { return nil }
        var detail = " since " + since(away.since, now: now, calendar: calendar, locale: locale)
        // Plain text in a plain label: a reason coloured from another client would otherwise
        // show its control bytes as "04lunch", to the eye and to VoiceOver.
        let reason = IRCFormatting.strip(away.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { detail += " · " + reason }
        return AwayStrip(lead: away.autoSet ? "Auto-away" : "Away", detail: detail)
    }

    /// The time alone for today, the date too for any other day, and the year too for any
    /// other year: "since 2:32 PM" from a week ago would read as this afternoon.
    static func since(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let template: String
        if calendar.isDate(date, inSameDayAs: now) {
            template = "jmm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            template = "MMMdjmm"
        } else {
            template = "yMMMdjmm"
        }
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

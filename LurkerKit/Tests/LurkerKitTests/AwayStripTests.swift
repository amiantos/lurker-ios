// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The composer's away strip (#135).
final class AwayStripTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// The expected time, formatted the way the strip should have — so these pin which form it
    /// picks (time, date, year) without pinning one ICU version's spacing and joiners.
    private func formatted(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func strip(_ away: AwayState?, now: Date? = nil) -> AwayStrip? {
        AwayStrip.make(away, now: now ?? date(2026, 10, 1, 18, 0), calendar: calendar, locale: locale)
    }

    func testNothingWhenNeverAway() {
        XCTAssertNil(strip(nil))
    }

    func testNothingOnceBackEvenThoughSinceAndReasonSurvive() {
        // ⚠ `since`/`message` outlive `/back` so the dividers can draw the pair. Reading them
        // instead of `active` would leave the strip up after you came back.
        let back = AwayState(
            active: false, message: "lunch", since: date(2026, 10, 1, 12, 0), backAt: date(2026, 10, 1, 13, 0)
        )
        XCTAssertNil(strip(back))
    }

    func testAwayWithAReason() {
        let since = date(2026, 10, 1, 14, 32)
        let away = AwayState(active: true, message: "lunch", since: since)
        XCTAssertEqual(strip(away), AwayStrip(lead: "Away", detail: " since \(formatted(since, "jmm")) · lunch"))
        XCTAssertFalse(formatted(since, "jmm").contains("Oct"))
    }

    func testAwayWithNoReasonIsStillAway() {
        // Unlike the web's `awayLabel`, which shows nothing for the most common `/away`.
        let since = date(2026, 10, 1, 14, 32)
        let away = AwayState(active: true, message: "  ", since: since)
        XCTAssertEqual(strip(away), AwayStrip(lead: "Away", detail: " since \(formatted(since, "jmm"))"))
        XCTAssertEqual(strip(AwayState(active: true, since: since))?.detail, " since \(formatted(since, "jmm"))")
    }

    func testAColouredReasonReadsAsItsText() {
        let away = AwayState(active: true, message: "\u{03}04lunch\u{03} \u{02}soon\u{02}", since: date(2026, 10, 1, 14, 32))
        XCTAssertEqual(strip(away)?.detail.hasSuffix(" · lunch soon"), true)
    }

    func testTheServerIdlingYouOutSaysSo() {
        let away = AwayState(active: true, message: "afk", since: date(2026, 10, 1, 14, 32), autoSet: true)
        XCTAssertEqual(strip(away)?.lead, "Auto-away")
    }

    func testAnotherDayCarriesTheDate() {
        // "since 2:32 PM" from last week would read as this afternoon.
        let since = date(2026, 9, 28, 14, 32)
        XCTAssertEqual(strip(AwayState(active: true, since: since))?.detail, " since \(formatted(since, "MMMdjmm"))")
        XCTAssertTrue(formatted(since, "MMMdjmm").contains("Sep 28"))
    }

    func testAnotherYearCarriesTheYear() {
        let since = date(2025, 12, 31, 23, 5)
        let detail = strip(AwayState(active: true, since: since), now: date(2026, 1, 1, 9, 0))?.detail
        XCTAssertEqual(detail, " since \(formatted(since, "yMMMdjmm"))")
        XCTAssertTrue(formatted(since, "yMMMdjmm").contains("2025"))
    }
}

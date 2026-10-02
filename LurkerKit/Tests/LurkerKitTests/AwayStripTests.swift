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
        let away = AwayState(active: true, message: "lunch", since: date(2026, 10, 1, 14, 32))
        XCTAssertEqual(strip(away), AwayStrip(lead: "Away", detail: " since 2:32\u{202F}PM · lunch"))
    }

    func testAwayWithNoReasonIsStillAway() {
        // Unlike the web's `awayLabel`, which shows nothing for the most common `/away`.
        let away = AwayState(active: true, message: "  ", since: date(2026, 10, 1, 14, 32))
        XCTAssertEqual(strip(away), AwayStrip(lead: "Away", detail: " since 2:32\u{202F}PM"))
        let bare = AwayState(active: true, since: date(2026, 10, 1, 14, 32))
        XCTAssertEqual(strip(bare)?.detail, " since 2:32\u{202F}PM")
    }

    func testTheServerIdlingYouOutSaysSo() {
        let away = AwayState(active: true, message: "afk", since: date(2026, 10, 1, 14, 32), autoSet: true)
        XCTAssertEqual(strip(away)?.lead, "Auto-away")
    }

    func testAnotherDayCarriesTheDate() {
        // "since 2:32 PM" from last week would read as this afternoon.
        let away = AwayState(active: true, since: date(2026, 9, 28, 14, 32))
        XCTAssertEqual(strip(away)?.detail, " since Sep 28 at 2:32\u{202F}PM")
    }

    func testAnotherYearCarriesTheYear() {
        let away = AwayState(active: true, since: date(2025, 12, 31, 23, 5))
        XCTAssertEqual(strip(away, now: date(2026, 1, 1, 9, 0))?.detail, " since Dec 31, 2025 at 11:05\u{202F}PM")
    }
}

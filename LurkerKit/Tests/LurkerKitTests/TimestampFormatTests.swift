// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The web's timestamp tokens (`vue_client/src/utils/timestamp.test.ts`, ported), and the compact
/// layout's time with its date on older lines (lurker#1179, lurker#1237).
final class TimestampFormatTests: XCTestCase {
    /// Fixed to UTC so the hours below don't move with the machine running the tests.
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text + "Z")!
    }

    private func format(_ text: String, _ fmt: String) -> String {
        TimestampFormat.string(at(text), format: fmt, calendar: utc)
    }

    // MARK: - 24-hour tokens

    func testPaddedTwentyFourHourClock() {
        XCTAssertEqual(format("2026-05-21T09:07:03", "HH:mm:ss"), "09:07:03")
    }

    func testUnpaddedTwentyFourHourToken() {
        XCTAssertEqual(format("2026-05-21T09:07:03", "H:mm"), "9:07")
        XCTAssertEqual(format("2026-05-21T13:07:03", "H:mm"), "13:07")
    }

    func testDateTokens() {
        XCTAssertEqual(format("2026-05-21T09:07:03", "YYYY-MM-DD"), "2026-05-21")
    }

    // MARK: - 12-hour tokens

    func testAfternoonIsTwelveHourWithPm() {
        XCTAssertEqual(format("2026-05-21T13:05:00", "hh:mm a"), "01:05 pm")
        XCTAssertEqual(format("2026-05-21T13:05:00", "h:mm A"), "1:05 PM")
    }

    func testMorningIsTwelveHourWithAm() {
        XCTAssertEqual(format("2026-05-21T09:05:00", "h:mm a"), "9:05 am")
    }

    func testMidnightIsTwelveAmNotZero() {
        XCTAssertEqual(format("2026-05-21T00:30:00", "hh:mm a"), "12:30 am")
        XCTAssertEqual(format("2026-05-21T00:30:00", "h:mm A"), "12:30 AM")
    }

    func testNoonIsTwelvePmNotZero() {
        XCTAssertEqual(format("2026-05-21T12:00:00", "hh:mm a"), "12:00 pm")
    }

    func testLateEveningWrapsToSingleDigits() {
        XCTAssertEqual(format("2026-05-21T23:45:00", "h:mm A"), "11:45 PM")
    }

    // MARK: - Guards

    func testEmptyFormatIsEmpty() {
        XCTAssertEqual(format("2026-05-21T09:07:03", ""), "")
    }

    func testNonTokenCharactersPassThrough() {
        XCTAssertEqual(format("2026-05-21T13:05:00", "[h:mm]"), "[1:05]")
    }

    func testTokenLettersAreSubstitutedInsideWords() {
        // No literal escaping, as on the web: the "a" of "at" is am/pm.
        XCTAssertEqual(format("2026-05-21T13:05:00", "at h:mm"), "pmt 1:05")
    }

    func testTheYearIsGregorianWhateverTheDeviceCalendar() {
        // `TimestampFormat.calendar` is Gregorian however the device is set; a Buddhist calendar
        // would print 2569 for the same instant.
        XCTAssertEqual(TimestampFormat.calendar.identifier, .gregorian)
    }

    // MARK: - The compact layout's time

    private func settings(_ values: [String: SettingValue] = [:]) -> Settings {
        Settings(registry: [:], values: values)
    }

    private func compact(
        _ text: String, now: String = "2026-05-21T18:00:00", withDate: Bool = true,
        _ values: [String: SettingValue] = [:]
    ) -> String? {
        TimestampFormat.compact(
            at(text), settings: settings(values), withDate: withDate, now: at(now), calendar: utc)
    }

    func testTodayIsTheTimeAlone() {
        XCTAssertEqual(compact("2026-05-21T09:07:03"), "09:07")
    }

    func testAnotherDayPutsTheDateFirst() {
        XCTAssertEqual(compact("2026-05-20T23:59:00"), "2026-05-20 23:59")
    }

    func testTheTimeFollowsItsSetting() {
        XCTAssertEqual(compact("2026-05-21T13:05:00", [TimestampFormat.compactTimeKey: .string("h:mm a")]), "1:05 pm")
    }

    func testTheDateFollowsItsSetting() {
        XCTAssertEqual(
            compact("2026-05-20T13:05:00", [TimestampFormat.compactDateKey: .string("MM/DD")]), "05/20 13:05")
    }

    func testAnEmptyDateFormatNeverShowsOne() {
        XCTAssertEqual(compact("2026-05-20T13:05:00", [TimestampFormat.compactDateKey: .string("")]), "13:05")
    }

    func testAnEmptyTimeFormatHidesTheTimeAndTheDate() {
        XCTAssertNil(compact("2026-05-20T13:05:00", [TimestampFormat.compactTimeKey: .string("")]))
    }

    func testWithoutTheDateAnotherDayIsTheTimeAlone() {
        XCTAssertEqual(compact("2026-05-20T13:05:00", withDate: false), "13:05")
    }
}

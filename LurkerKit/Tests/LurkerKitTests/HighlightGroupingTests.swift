// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Locks the channel+day run grouping the recent-highlights list renders: a new run on a
/// buffer or day change, case-folded targets, interleaved channels repeating in order, and
/// the Today/Yesterday/date/undated classification.
final class HighlightGroupingTests: XCTestCase {
    private let calendar = Calendar.current
    // Noon today, so day-boundary math never lands on midnight and flakes.
    private lazy var now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

    private func item(_ id: Int, networkId: Int?, _ target: String, date: Date?) -> HighlightItem {
        HighlightItem(
            message: Message(id: id, type: .message, nick: "a", text: "hi", date: date),
            networkId: networkId, target: target, networkName: nil
        )
    }

    func testConsecutiveSameChannelSameDayIsOneGroup() {
        let items = [
            item(3, networkId: 1, "#a", date: now),
            item(2, networkId: 1, "#a", date: now.addingTimeInterval(-60)),
        ]
        let groups = HighlightGrouping.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertEqual(groups[0].day, .today)
        XCTAssertEqual(groups[0].offset, 0)
    }

    func testDifferentChannelSameDaySplits() {
        let items = [item(3, networkId: 1, "#a", date: now), item(2, networkId: 1, "#b", date: now)]
        let groups = HighlightGrouping.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.target), ["#a", "#b"])
        XCTAssertEqual(groups.map(\.offset), [0, 1])
    }

    func testInterleavedChannelsRepeatInOrder() {
        // Order is preserved and a channel repeats when it comes back — iMessage's behavior.
        let items = [
            item(3, networkId: 1, "#a", date: now),
            item(2, networkId: 1, "#b", date: now),
            item(1, networkId: 1, "#a", date: now),
        ]
        let groups = HighlightGrouping.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.target), ["#a", "#b", "#a"])
        XCTAssertEqual(groups.map { $0.items.count }, [1, 1, 1])
        XCTAssertEqual(groups.map(\.offset), [0, 1, 2])
    }

    func testSameChannelDifferentDaySplits() {
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let items = [item(3, networkId: 1, "#a", date: now), item(2, networkId: 1, "#a", date: yesterday)]
        let groups = HighlightGrouping.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].day, .today)
        XCTAssertEqual(groups[1].day, .yesterday)
    }

    func testTargetCaseFoldedIntoOneRun() {
        let items = [item(2, networkId: 1, "#Chan", date: now), item(1, networkId: 1, "#chan", date: now)]
        let groups = HighlightGrouping.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].target, "#Chan", "the display target keeps the first row's casing")
    }

    func testSameTargetDifferentNetworkSplits() {
        let items = [item(2, networkId: 1, "#a", date: now), item(1, networkId: 2, "#a", date: now)]
        let groups = HighlightGrouping.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.networkId), [1, 2])
    }

    func testUndatedRowsGroupAsUndated() {
        let items = [item(2, networkId: 1, "#a", date: nil), item(1, networkId: 1, "#a", date: nil)]
        let groups = HighlightGrouping.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].day, .undated)
    }

    func testOlderDayIsOnStartOfDay() {
        let fiveDaysAgo = now.addingTimeInterval(-5 * 24 * 3600)
        let groups = HighlightGrouping.group([item(1, networkId: 1, "#a", date: fiveDaysAgo)], now: now, calendar: calendar)
        XCTAssertEqual(groups[0].day, .on(calendar.startOfDay(for: fiveDaysAgo)))
    }

    func testEmptyInputIsNoGroups() {
        XCTAssertTrue(HighlightGrouping.group([], now: now, calendar: calendar).isEmpty)
    }

    func testYesterdayHoldsOnADayThatStartsAfterMidnight() {
        // lurker-ios#200: Havana springs forward at midnight, so 2026-03-08 begins at 01:00.
        // Today's start minus a day was 01:00 on the 7th, which began at 00:00, so yesterday's
        // rows got a dated header. Santiago and Cairo do the same. Havana's fall-back on
        // 2026-11-01 (01:00 back to 00:00) missed the other way, seen from the 2nd.
        var havana = Calendar(identifier: .gregorian)
        havana.timeZone = TimeZone(identifier: "America/Havana")!
        func noon(_ month: Int, _ day: Int) -> Date {
            havana.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        }
        XCTAssertEqual(HighlightDay(date: noon(3, 7), now: noon(3, 8), calendar: havana), .yesterday)
        XCTAssertEqual(HighlightDay(date: noon(11, 1), now: noon(11, 2), calendar: havana), .yesterday)
        XCTAssertEqual(
            HighlightDay(date: noon(3, 6), now: noon(3, 8), calendar: havana),
            .on(havana.startOfDay(for: noon(3, 6)))
        )
    }

    func testDayIsClassifiedAgainstPassedNowNotTheDeviceDate() {
        // A fixed `now` that is emphatically not the day this test runs. Today/yesterday must
        // be measured against it, not the real clock — the earlier `isDateInToday` version
        // would have classified all three as `.on(...)`.
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            item(3, networkId: 1, "#a", date: fixedNow),
            item(2, networkId: 1, "#a", date: fixedNow.addingTimeInterval(-24 * 3600)),
            item(1, networkId: 1, "#a", date: fixedNow.addingTimeInterval(-5 * 24 * 3600)),
        ]
        let groups = HighlightGrouping.group(items, now: fixedNow, calendar: calendar)
        XCTAssertEqual(groups.map(\.day), [
            .today,
            .yesterday,
            .on(calendar.startOfDay(for: fixedNow.addingTimeInterval(-5 * 24 * 3600))),
        ])
    }
}

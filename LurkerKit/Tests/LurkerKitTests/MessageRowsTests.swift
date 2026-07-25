// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// The layout-independent half of the message list: which rows come out, in what order, and
/// where the dividers cut.
///
/// Worth pinning because the cuts interact. Every divider is a hard break for *both* the
/// consolidation pass and the bubble-run pass, and a bug there is quiet — a run that silently
/// swallows the first unread message, or a summary sitting under the wrong date, looks like a
/// plausible list rather than a broken one.
final class MessageRowsTests: XCTestCase {

    /// A fixed calendar so a day boundary means the same thing wherever this runs. Without it
    /// the day-change tests pass or fail depending on the machine's timezone.
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-07-20 12:00:00 UTC — midday, so ±hours stay inside the day.
    private let noon = Date(timeIntervalSince1970: 1_784_548_800)

    private func msg(
        _ id: Int,
        _ type: EventType = .message,
        _ nick: String = "alice",
        text: String? = "hi",
        newNick: String? = nil,
        at date: Date? = nil
    ) -> Message {
        Message(id: id, type: type, nick: nick, text: text, date: date, newNick: newNick)
    }

    private func build(
        _ messages: [Message],
        dividerAfterId: Int? = nil,
        hasMoreOlder: Bool = true,
        typists: [String] = [],
        settings: Settings = Settings()
    ) -> [MessageRow] {
        MessageRows.build(
            messages: messages, dividerAfterId: dividerAfterId, hasMoreOlder: hasMoreOlder,
            typists: typists, settings: settings, calendar: utc
        )
    }

    /// Fetch a row by index, reporting rather than trapping when it isn't there.
    ///
    /// Subscripting directly would make an off-by-one regression crash the test *process* —
    /// which aborts the run and takes every other suite's results with it, so the one failure
    /// you see is whichever test happened to sort first. This reports the real one.
    private func row(
        _ rows: [MessageRow], _ index: Int, file: StaticString = #filePath, line: UInt = #line
    ) -> MessageRow? {
        guard rows.indices.contains(index) else {
            XCTFail("no row at \(index) — got \(rows.count) rows: \(rows)", file: file, line: line)
            return nil
        }
        return rows[index]
    }

    private func isDate(_ row: MessageRow?) -> Bool {
        if case .dateDivider = row { return true }
        return false
    }

    private func isSummary(_ row: MessageRow) -> Bool {
        if case .consolidated = row { return true }
        return false
    }

    // MARK: - Date dividers

    func testADateDividerOpensTheBuffer() {
        // Including the very first message: the reader should never have to guess what day
        // the top of the buffer is.
        let rows = build([msg(1, at: noon)])
        XCTAssertTrue(isDate(row(rows, 0)), "the first row is the day of the first message")
        XCTAssertEqual(rows.count, 2)
    }

    func testADividerLandsOnEachDayChange() {
        let rows = build([
            msg(1, at: noon),
            msg(2, at: noon.addingTimeInterval(3600)), // same day
            msg(3, at: noon.addingTimeInterval(86_400)), // next day
        ])
        XCTAssertEqual(rows.filter(isDate).count, 2)
        // date, msg, msg, date, msg
        XCTAssertTrue(isDate(row(rows, 0)))
        XCTAssertTrue(isDate(row(rows, 3)))
    }

    func testTheDividerCarriesLocalMidnight() {
        guard case .dateDivider(let day) = row(build([msg(1, at: noon)]), 0) else {
            return XCTFail("expected a date divider")
        }
        XCTAssertEqual(day, utc.startOfDay(for: noon))
    }

    func testAnUndatedMessageDoesNotEmitADivider() {
        // A synthesized/ephemeral line has no time. It can't name a day, and it must not
        // reset the day either — otherwise the next real message re-emits a divider for a
        // day that's already open.
        let rows = build([
            msg(1, at: noon),
            msg(2, at: nil),
            msg(3, at: noon.addingTimeInterval(3600)),
        ])
        XCTAssertEqual(rows.filter(isDate).count, 1)
    }

    // MARK: - Start of history

    func testStartOfHistorySitsAboveEverything() {
        let rows = build([msg(1, at: noon)], hasMoreOlder: false)
        guard case .startOfHistory = rows.first else {
            return XCTFail("the marker goes above even the first date divider")
        }
        XCTAssertTrue(isDate(row(rows, 1)))
    }

    func testStartOfHistoryIsSuppressedWhileMoreRemains() {
        let rows = build([msg(1, at: noon)], hasMoreOlder: true)
        XCTAssertFalse(rows.contains { if case .startOfHistory = $0 { true } else { false } })
    }

    func testStartOfHistoryIsSuppressedOnAnEmptyBuffer() {
        // "You've reached the beginning" over a blank list says less than the empty-state
        // placeholder does, and reads as a bug.
        XCTAssertTrue(build([], hasMoreOlder: false).isEmpty)
    }

    // MARK: - Unread divider

    func testTheUnreadDividerLandsBeforeTheFirstUnreadMessage() {
        let rows = build([msg(1, at: noon), msg(2, at: noon), msg(3, at: noon)], dividerAfterId: 2)
        // date, msg1, msg2, unread, msg3
        guard case .unreadDivider = row(rows, 3) else { return XCTFail("expected the divider at index 3") }
    }

    func testNoUnreadDividerWithoutARealReadPoint() {
        // A brand-new buffer has nothing previously read; a marker there would claim
        // everything is new, which is true but useless.
        let rows = build([msg(1, at: noon), msg(2, at: noon)], dividerAfterId: 0)
        XCTAssertFalse(rows.contains { if case .unreadDivider = $0 { true } else { false } })
    }

    func testNoUnreadDividerWhenEverythingIsRead() {
        let rows = build([msg(1, at: noon), msg(2, at: noon)], dividerAfterId: 99)
        XCTAssertFalse(rows.contains { if case .unreadDivider = $0 { true } else { false } })
    }

    func testTheUnreadDividerIsPlacedOnlyOnce() {
        let rows = build([msg(1, at: noon), msg(2, at: noon), msg(3, at: noon)], dividerAfterId: 1)
        XCTAssertEqual(rows.filter { if case .unreadDivider = $0 { true } else { false } }.count, 1)
    }

    func testTheDateSitsAboveTheUnreadMarkerWhenTheyCollide() {
        // Reading the previous evening and coming back the next morning puts both breaks on
        // the same message. The day is context for what follows; the unread marker is the
        // thing the reader is looking for, so it goes closest to the first new message.
        let rows = build([msg(1, at: noon), msg(2, at: noon.addingTimeInterval(86_400))], dividerAfterId: 1)
        // date, msg1, date, unread, msg2
        XCTAssertTrue(isDate(row(rows, 2)))
        guard case .unreadDivider = row(rows, 3) else { return XCTFail("unread must sit below the date") }
    }

    // MARK: - Dividers are hard breaks for consolidation

    func testConsolidationDoesNotSpanTheUnreadDivider() {
        // Three joins straddling the read boundary. Collapsed as one run, the arrival the
        // reader hasn't seen would be hidden inside a summary above the marker.
        let joins = (1...3).map { msg($0, .join, "user\($0)", text: nil, at: noon) }
        let rows = build(joins, dividerAfterId: 2)
        guard let dividerIndex = rows.firstIndex(where: { if case .unreadDivider = $0 { true } else { false } })
        else { return XCTFail("expected an unread divider") }
        XCTAssertTrue(rows[..<dividerIndex].contains(where: isSummary), "the read pair collapses")
        // The single unread join stands alone rather than joining the summary above.
        guard case .line = row(rows, dividerIndex + 1) else { return XCTFail("expected a standalone join") }
        XCTAssertEqual(rows.count, dividerIndex + 2)
    }

    func testConsolidationDoesNotSpanADayChange() {
        // A summary carries one timestamp. One spanning midnight would sit under a date
        // that's wrong for half the events inside it.
        let rows = build([
            msg(1, .join, "a", text: nil, at: noon),
            msg(2, .join, "b", text: nil, at: noon),
            msg(3, .join, "c", text: nil, at: noon.addingTimeInterval(86_400)),
            msg(4, .join, "d", text: nil, at: noon.addingTimeInterval(86_400)),
        ])
        XCTAssertEqual(rows.filter(isSummary).count, 2, "one summary per day, not one across both")
    }

    // MARK: - Dividers are hard breaks for bubble runs

    func testABubbleRunDoesNotSpanTheUnreadDivider() {
        // Same author, close in time — a run, but for the divider between them. Tightened
        // corners across it would knit together the messages it exists to separate.
        let rows = build([msg(1, at: noon), msg(2, at: noon)], dividerAfterId: 1)
        guard case .bubble(_, let first) = row(rows, 1), case .bubble(_, let second) = row(rows, 3) else {
            return XCTFail("expected bubbles either side of the divider")
        }
        XCTAssertTrue(first.isLast, "the run closes above the divider")
        XCTAssertTrue(second.isFirst, "and reopens below it")
    }

    func testABubbleRunGroupsWhenNothingBreaksIt() {
        let rows = build([msg(1, at: noon), msg(2, at: noon)])
        guard case .bubble(_, let first) = row(rows, 1), case .bubble(_, let second) = row(rows, 2) else {
            return XCTFail("expected two bubbles")
        }
        XCTAssertTrue(first.isFirst)
        XCTAssertFalse(first.isLast)
        XCTAssertFalse(second.isFirst)
        XCTAssertTrue(second.isLast)
    }

    // MARK: - Settings

    func testConsolidationOffPassesEveryEventThrough() {
        let settings = Settings(
            registry: [:], values: ["chat.consolidate_joins": .bool(false)]
        )
        let joins = (1...3).map { msg($0, .join, "user\($0)", text: nil, at: noon) }
        let rows = build(joins, settings: settings)
        XCTAssertFalse(rows.contains(where: isSummary))
        XCTAssertEqual(rows.filter { if case .line = $0 { true } else { false } }.count, 3)
    }

    func testMaxNamesIsHonored() {
        let settings = Settings(registry: [:], values: ["chat.consolidate_max_names": .int(2)])
        let joins = (1...5).map { msg($0, .join, "user\($0)", text: nil, at: noon) }
        let rows = build(joins, settings: settings)
        guard case .consolidated(let summary) = row(rows, 1) else { return XCTFail("expected a summary") }
        XCTAssertEqual(summary.groups.first?.visible.count, 2)
        XCTAssertEqual(summary.groups.first?.hidden, 3)
    }

    // MARK: - Typing

    func testTypingGoesLastAndOutsideTheRunPass() {
        let rows = build([msg(1, at: noon)], typists: ["bob"])
        guard case .typing(let nicks) = rows.last else { return XCTFail("expected a typing row") }
        XCTAssertEqual(nicks, ["bob"])
        // The bubble above it still closes its run — the typing row is not a bubble neighbour.
        guard case .bubble(_, let position) = row(rows, 1) else { return XCTFail("expected a bubble") }
        XCTAssertTrue(position.isLast)
    }

    // MARK: - Row queries

    func testMarkersNeverAnchorTheViewport() {
        let rows = build([msg(1, at: noon)], hasMoreOlder: false, typists: ["bob"])
        // start-of-history, date, bubble, typing
        XCTAssertEqual(rows.count, 4)
        XCTAssertNil(row(rows, 0)?.anchorId)
        XCTAssertNil(row(rows, 1)?.anchorId)
        XCTAssertEqual(row(rows, 2)?.anchorId, 1)
        XCTAssertNil(row(rows, 3)?.anchorId)
    }

    func testASummaryRepresentsEveryMessageInItsSpan() {
        let joins = (1...3).map { msg($0, .join, "user\($0)", text: nil, at: noon) }
        let rows = build(joins)
        guard let summary = row(rows, 1), case .consolidated = summary else {
            return XCTFail("expected a summary")
        }
        // The middle id has no row of its own; the summary stands in for it, which is what
        // lets the scroll anchor re-find a line after a history page merges it into a run.
        XCTAssertTrue(summary.represents(2))
        XCTAssertFalse(summary.represents(4))
    }

    func testOnlyNarrationCountsAsStatus() {
        let rows = build([
            msg(1, .join, "a", text: nil, at: noon),
            msg(2, .message, "b", at: noon),
            msg(3, .action, "c", at: noon),
        ])
        // date, join, message, action
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(row(rows, 1)?.isStatus, true)
        XCTAssertEqual(row(rows, 2)?.isStatus, false)
        XCTAssertEqual(row(rows, 3)?.isStatus, false, "an action is conversation, so it breaks a status block")
        XCTAssertEqual(row(rows, 0)?.isStatus, false, "a divider is a hard break, not part of a block")
    }
}

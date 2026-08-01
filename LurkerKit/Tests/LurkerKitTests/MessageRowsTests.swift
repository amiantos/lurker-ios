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
        hasMoreNewer: Bool = false,
        typists: [String] = [],
        settings: Settings = Settings(),
        away: AwayState? = nil,
        now: Date? = nil
    ) -> [MessageRow] {
        MessageRows.build(
            messages: messages, dividerAfterId: dividerAfterId, hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer, typists: typists, settings: settings, away: away,
            now: now ?? noon, calendar: utc
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

    /// A buffer can *open* with an undated line — `LurkerStore.appendLocal` synthesizes one for
    /// an unrecognized command, and in an empty system buffer that's the first row. It must
    /// still sit under a day header rather than being stranded above the divider that appears
    /// once real traffic lands.
    func testALeadingUndatedRunAdoptsTheFirstDatedDay() {
        let rows = build([
            msg(1, at: nil),
            msg(2, at: nil),
            msg(3, at: noon),
        ])
        XCTAssertEqual(rows.filter(isDate).count, 1, "one header, not one below the local lines")
        XCTAssertTrue(isDate(row(rows, 0)), "and it sits above them")
        guard case .dateDivider(let day) = row(rows, 0) else { return XCTFail("expected a date divider") }
        XCTAssertEqual(day, utc.startOfDay(for: noon))
        XCTAssertEqual(rows.count, 4)
    }

    func testAllUndatedMessagesGetNoDayHeader() {
        // Nothing to name. Guessing a day would be a claim the data doesn't support.
        let rows = build([msg(1, at: nil), msg(2, at: nil)])
        XCTAssertEqual(rows.filter(isDate).count, 0)
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

    // MARK: - Away/back presence markers (#68)

    /// Away at noon+1h, back at noon+2h — so a message at noon is before both, one at +90m is
    /// between them, and one at +3h is after both.
    private func awayPair(back: Bool = true, message: String? = nil) -> AwayState {
        AwayState(
            active: !back,
            message: message,
            since: noon.addingTimeInterval(3600),
            backAt: back ? noon.addingTimeInterval(7200) : nil
        )
    }

    private func markerIndex(_ rows: [MessageRow], away: Bool) -> Int? {
        rows.firstIndex {
            switch $0 {
            case .awayDivider: away
            case .backDivider: !away
            default: false
            }
        }
    }

    func testTheAwayMarkerLandsAboveTheFirstMessageYouMissed() {
        // The point of the marker: everything below it happened while you were gone.
        let rows = build(
            [msg(1, at: noon), msg(2, at: noon.addingTimeInterval(5400))],
            away: awayPair(back: false)
        )
        guard let index = markerIndex(rows, away: true) else { return XCTFail("expected an away marker") }
        XCTAssertEqual(row(rows, index - 1)?.message?.id, 1, "the last line you were present for")
        XCTAssertEqual(row(rows, index + 1)?.message?.id, 2, "the first one you weren't")
    }

    func testTheBackMarkerLandsAboveTheFirstMessageYouWereBackFor() {
        let rows = build(
            [
                msg(1, at: noon),
                msg(2, at: noon.addingTimeInterval(5400)), // during the away
                msg(3, at: noon.addingTimeInterval(7500)), // after the back
            ],
            away: awayPair(), now: noon.addingTimeInterval(7800)
        )
        guard let awayIndex = markerIndex(rows, away: true),
              let backIndex = markerIndex(rows, away: false)
        else { return XCTFail("expected both markers") }
        XCTAssertLessThan(awayIndex, backIndex, "you go away before you come back")
        XCTAssertEqual(row(rows, backIndex + 1)?.message?.id, 3)
    }

    func testTheBackMarkerCarriesTheAwayInstant() {
        // So the row can say how long you were gone without the renderer holding away state.
        let rows = build([msg(1, at: noon.addingTimeInterval(7500))], away: awayPair(),
                         now: noon.addingTimeInterval(7800))
        guard let index = markerIndex(rows, away: false), case .backDivider(let awayAt, let at) = rows[index]
        else { return XCTFail("expected a back marker") }
        XCTAssertEqual(awayAt, noon.addingTimeInterval(3600))
        XCTAssertEqual(at, noon.addingTimeInterval(7200))
    }

    func testBothMarkersStackWhenNothingWasSaidInBetween() {
        // Nobody spoke during the away, so both anchor to the first line after it. They stack
        // rather than collapsing: the pair is what says the gap sat *here* and cost you
        // nothing, and dropping the away half would take the reason with it. Same call the web
        // makes — pinned so it stays a decision.
        let rows = build(
            [msg(1, at: noon), msg(2, at: noon.addingTimeInterval(7500))],
            away: awayPair(message: "lunch"), now: noon.addingTimeInterval(7800)
        )
        guard let awayIndex = markerIndex(rows, away: true) else { return XCTFail("expected an away marker") }
        XCTAssertEqual(markerIndex(rows, away: false), awayIndex + 1, "back sits directly under away")
        XCTAssertEqual(row(rows, awayIndex + 2)?.message?.id, 2)
    }

    func testAMarkerWithNothingBelowItLandsAtTheFoot() {
        // The common case, not an edge: you go away and nothing has been said since, so neither
        // instant has a message after it to sit above. Anchoring alone would mean the markers
        // only ever appeared in the buffers that kept talking without you — which is to say
        // almost never at the moment you'd look for one.
        let rows = build([msg(1, at: noon)], away: awayPair(back: false))
        XCTAssertEqual(markerIndex(rows, away: true), rows.count - 1, "below the last message")
        XCTAssertEqual(row(rows, rows.count - 2)?.message?.id, 1)
    }

    func testASettledPairWithNothingBelowItLandsAtTheFootInOrder() {
        let rows = build(
            [msg(1, at: noon)], away: awayPair(), now: noon.addingTimeInterval(7500)
        )
        XCTAssertEqual(markerIndex(rows, away: true), rows.count - 2)
        XCTAssertEqual(markerIndex(rows, away: false), rows.count - 1)
    }

    func testTheTypingLineStillSitsBelowAFootMarker() {
        // Typing describes the present; a marker describes something that already happened.
        let rows = build([msg(1, at: noon)], typists: ["bob"], away: awayPair(back: false))
        guard case .typing = rows.last else { return XCTFail("expected the typing line last") }
        XCTAssertEqual(markerIndex(rows, away: true), rows.count - 2)
    }

    func testADetachedBufferGetsNoFootMarker() {
        // Jump to a search hit from last week (#42): the window sits below the live tail, so
        // "nothing has been said since" is a claim about a tail this buffer can't see. Pinning
        // it under a week-old message asserts an absence that happened days afterwards.
        let rows = build([msg(1, at: noon)], hasMoreNewer: true, away: awayPair(back: false))
        XCTAssertNil(markerIndex(rows, away: true))
        XCTAssertNil(markerIndex(rows, away: false))
    }

    func testADetachedBufferStillAnchorsAMarkerItCanPlace() {
        // Only the fallback is suppressed. A marker with a message to sit above is true
        // wherever that message is — the window's relationship to the tail doesn't change what
        // happened between two lines that are both on screen.
        let rows = build(
            [msg(1, at: noon), msg(2, at: noon.addingTimeInterval(5400))],
            hasMoreNewer: true, away: awayPair(back: false)
        )
        guard let index = markerIndex(rows, away: true) else { return XCTFail("expected a marker") }
        XCTAssertEqual(row(rows, index + 1)?.message?.id, 2)
    }

    func testAnEmptyBufferGetsNoMarkers() {
        // A lone marker over no conversation isn't a marker — and it would suppress the
        // empty-state placeholder, which reads `rows.isEmpty`.
        XCTAssertTrue(build([], away: awayPair(back: false)).isEmpty)
    }

    func testNoMarkersWithoutAwayState() {
        let rows = build([msg(1, at: noon), msg(2, at: noon.addingTimeInterval(7200))])
        XCTAssertNil(markerIndex(rows, away: true))
        XCTAssertNil(markerIndex(rows, away: false))
    }

    func testBothMarkersRetireOnceYouHaveBeenBackAWhile() {
        // In a slow buffer they'd otherwise describe an absence nobody remembers. Both go, or
        // the surviving "away" would sit permanently over a user who is demonstrably here.
        let messages = [msg(1, at: noon), msg(2, at: noon.addingTimeInterval(10_800))]
        let backAt = noon.addingTimeInterval(7200)
        let live = build(messages, away: awayPair(), now: backAt.addingTimeInterval(MessageRows.presenceMarkerTTL))
        XCTAssertNotNil(markerIndex(live, away: true), "still inside the lease")
        XCTAssertNotNil(markerIndex(live, away: false))

        let expired = build(
            messages, away: awayPair(), now: backAt.addingTimeInterval(MessageRows.presenceMarkerTTL + 1)
        )
        XCTAssertNil(markerIndex(expired, away: true))
        XCTAssertNil(markerIndex(expired, away: false))
    }

    func testAnUnfinishedAwayNeverExpires() {
        // The lease runs from `backAt`. While you're still away there's nothing to run from,
        // and the marker is describing the present rather than a memory of it.
        let rows = build(
            [msg(1, at: noon), msg(2, at: noon.addingTimeInterval(5400))],
            away: awayPair(back: false),
            now: noon.addingTimeInterval(86_400 * 7)
        )
        XCTAssertNotNil(markerIndex(rows, away: true))
        XCTAssertNil(markerIndex(rows, away: false), "you haven't come back")
    }

    func testTheAwayMarkerCarriesItsReason() {
        let rows = build(
            [msg(1, at: noon), msg(2, at: noon.addingTimeInterval(5400))],
            away: awayPair(back: false, message: "lunch")
        )
        guard let index = markerIndex(rows, away: true), case .awayDivider(_, let reason) = rows[index]
        else { return XCTFail("expected an away marker") }
        XCTAssertEqual(reason, "lunch")
    }

    func testAnUndatedLineNeverAnchorsAPresenceMarker() {
        // An undated line can't answer "did this happen after you left?", so it can't be what a
        // marker sits above — treating it as epoch (which the web's `Date.parse(…) || 0` does)
        // would put the marker over a line that could as easily belong below it. It falls
        // through to the foot instead, which is where "nothing has been said since" belongs.
        let rows = build([msg(1, at: nil), msg(2, at: nil)], away: awayPair(back: false))
        XCTAssertEqual(markerIndex(rows, away: true), rows.count - 1, "at the foot, not between them")
    }

    func testADatedLineAnchorsTheMarkerAboveTheUndatedRunItFollows() {
        // The pair to the test above: with a dated message available, the marker anchors to it
        // rather than falling to the foot — so the undated line above stays above the marker.
        let rows = build(
            [msg(1, at: nil), msg(2, at: noon.addingTimeInterval(5400))],
            away: awayPair(back: false)
        )
        guard let index = markerIndex(rows, away: true) else { return XCTFail("expected a marker") }
        XCTAssertEqual(row(rows, index - 1)?.message?.id, 1)
        XCTAssertEqual(row(rows, index + 1)?.message?.id, 2)
    }

    func testConsolidationDoesNotSpanAPresenceMarker() {
        // Same rule as every other divider: a run half-before and half-after the marker would
        // hide the absence inside a summary.
        let joins = [
            msg(1, .join, "a", text: nil, at: noon),
            msg(2, .join, "b", text: nil, at: noon),
            msg(3, .join, "c", text: nil, at: noon.addingTimeInterval(5400)),
            msg(4, .join, "d", text: nil, at: noon.addingTimeInterval(5400)),
        ]
        let rows = build(joins, away: awayPair(back: false))
        XCTAssertEqual(rows.filter(isSummary).count, 2, "one summary either side, not one across")
    }

    func testTheDateDividerSitsAboveThePresenceMarker() {
        // Both land on the same message when an away spans midnight. The day is context for
        // what follows; the marker is a thing that happened inside that day.
        let away = AwayState(active: true, since: noon, backAt: nil)
        let rows = build([msg(1, at: noon.addingTimeInterval(86_400))], away: away)
        XCTAssertTrue(isDate(row(rows, 0)))
        XCTAssertEqual(markerIndex(rows, away: true), 1)
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

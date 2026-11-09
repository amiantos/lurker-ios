// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// A buffer's rows are shown by time, id as the tiebreak (lurker#1290). The first four are the
/// web's `messageOrder.test.ts`; the rest are what the order has to hold through on the way to
/// the screen: the build, the unread divider, a consolidated run and the badge.
@Suite("Message order")
@MainActor
struct MessageOrderTests {

    private let channel = BufferKey(networkId: 1, target: "#lurker")

    /// 2026-11-06 09:00 UTC plus `minute`.
    private func at(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_793_955_600 + TimeInterval(minute * 60))
    }

    private func msg(
        _ id: Int, _ minute: Int?, _ text: String = "line", nick: String = "alice",
        type: EventType = .message
    ) -> Message {
        Message(id: id, type: type, nick: nick, text: text, date: minute.map(at))
    }

    private func ids(_ rows: [Message]) -> [Int] { rows.map(\.id) }

    /// A join at :22 stored before the two lines of the gap it closed, said at :19 and :20.
    private var filledGap: [Message] {
        [
            msg(10, 18, "before"),
            msg(20, 22, "join", nick: "me", type: .join),
            msg(21, 19, "gap one"),
            msg(22, 20, "gap two"),
            msg(23, 23, "after"),
        ]
    }

    private func state(_ messages: [Message], lastReadId: Int = 0, settings: Settings = Settings()) -> ChatState {
        var s = ChatState()
        s.connection = .connected
        s.reachable = true
        s.snapshotSinceOpen = true
        s.backlogComplete = true
        s.networks = [1: Network(id: 1, name: "Libera", state: .connected, nick: "me")]
        let buffer = Buffer(
            networkId: 1, target: channel.target, kind: .channel, lastReadId: lastReadId,
            joined: true, hydrated: true, readStateKnown: true
        )
        s.buffers[buffer.key.id] = buffer
        s.messages[channel.id] = messages
        s.settings = settings
        return s
    }

    private func build(_ state: ChatState, options: RowOptions = RowOptions(), seq: Int = 0) -> ConversationBuild {
        ConversationBuild.make(state: state, key: channel, kind: .channel, options: options, seq: seq)
    }

    private func shown(_ built: ConversationBuild) -> [String] {
        built.rows.map { row in
            switch row {
            case .bubble(let message, _), .line(let message): "\(message.id)"
            case .consolidated: "summary"
            case .unreadDivider: "unread"
            case .dateDivider: "date"
            default: "other"
            }
        }.filter { $0 != "date" }
    }

    // MARK: - The order

    @Test("a buffer with nothing replayed is left as it is")
    func leavesOrderedRows() {
        let rows = [msg(1, 1), msg(2, 2), msg(3, 2)]
        #expect(ids(MessageOrder.byTime(rows)) == [1, 2, 3])
    }

    @Test("a replayed line goes by its time, above the join it was stored after")
    func placesReplayedLines() {
        #expect(MessageOrder.byTime(filledGap).map(\.text) == ["before", "gap one", "gap two", "join", "after"])
    }

    @Test("a shared time breaks by id")
    func tiesBreakById() {
        #expect(ids(MessageOrder.byTime([msg(2, 5), msg(1, 5), msg(4, 6)])) == [1, 2, 4])
    }

    @Test("a row with a time and no id is last among its time")
    func ephemeralIsLastAmongItsTime() {
        #expect(ids(MessageOrder.byTime([msg(2, 5), msg(0, 5), msg(1, 3)])) == [1, 2, 0])
    }

    @Test("a row with no time rides the row it arrived after")
    func undatedRidesItsPredecessor() {
        // The app's own line, written under the join; the gap's lines go above both.
        let rows = [msg(10, 18), msg(20, 22, "join"), msg(0, nil, "unknown command"), msg(21, 19), msg(22, 20)]
        #expect(MessageOrder.byTime(rows).map(\.text) == ["line", "line", "line", "join", "unknown command"])
        #expect(ids(MessageOrder.byTime(rows)) == [10, 21, 22, 20, 0])
    }

    @Test("rows with no time at the head of the list stay there")
    func leadingUndatedStaysFirst() {
        let rows = [msg(0, nil, "local"), msg(20, 22), msg(21, 19)]
        #expect(ids(MessageOrder.byTime(rows)) == [0, 21, 20])
    }

    // MARK: - On the way to the screen

    @Test("the build shows a filled gap where it was said, and leaves the held list alone")
    func buildShowsGapInPlace() {
        let built = build(state(filledGap))
        #expect(ids(built.visible) == [10, 21, 22, 20, 23])
        #expect(shown(built) == ["10", "21", "22", "20", "23"])
        // The store's list is the id order paging and the tail rule read.
        #expect(ids(built.held ?? []) == [10, 20, 21, 22, 23])
    }

    @Test("the unread divider goes above the first unread row shown, over a join already read")
    func dividerAboveFirstUnreadShown() {
        // Read through the join (20); the gap's lines are unread and sit above it.
        let built = build(state(filledGap, lastReadId: 20), options: RowOptions(dividerAfterId: 20))
        #expect(shown(built) == ["10", "unread", "21", "22", "20", "23"])
        #expect(built.firstUnreadRow.flatMap { built.rows[$0].message?.id } == 21)
    }

    @Test("a consolidated run answers for the events in it, not for the ids between them")
    func summaryRepresentsItsOwnEvents() {
        // A part at :10 (id 40) and a replayed join at :11 (id 105) fold into one run; ids
        // 41 and 42 are lines said later and drawn below it.
        let rows = [
            msg(40, 10, nick: "bob", type: .part),
            msg(41, 12, "later one"),
            msg(42, 13, "later two"),
            msg(105, 11, nick: "carol", type: .join),
        ]
        let built = build(state(rows))
        #expect(shown(built) == ["summary", "41", "42"])
        #expect(built.rowIndex(containing: 40) == built.rowIndex(containing: 105))
        #expect(built.rowIndex(containing: 41).map { built.rows[$0].message?.id } == 41)
        #expect(built.rowIndex(containing: 42).map { built.rows[$0].message?.id } == 42)
    }

    @Test("the badge counts a line above the newest id once, however the rows are shown")
    func badgeCountsByNewestId() {
        let scroll = ConversationScroll(kind: .channel)
        _ = scroll.onFrame(state(filledGap, lastReadId: 23), key: channel, seq: 0)
        _ = scroll.onRows(build(state(filledGap), options: scroll.options), wasNearBottom: false)
        // The last row SHOWN is 23, and so is the newest id. A live line lands: one new.
        _ = scroll.onRows(build(state(filledGap + [msg(24, 24)]), options: scroll.options), wasNearBottom: false)
        #expect(scroll.newWhileAway == 1)
        // A late line of the gap lands above (id 25, said at :21). The last row shown is
        // still 24; nothing already counted is counted again.
        _ = scroll.onRows(build(state(filledGap + [msg(24, 24), msg(25, 21)]), options: scroll.options), wasNearBottom: false)
        #expect(scroll.newWhileAway == 2)
        _ = scroll.onRows(build(state(filledGap + [msg(24, 24), msg(25, 21), msg(26, 25)]), options: scroll.options), wasNearBottom: false)
        #expect(scroll.newWhileAway == 3)
    }
}

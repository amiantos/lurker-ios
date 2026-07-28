// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// The event-noise tier (#666) — which presence events reach the list, and the page unit that
/// has to match.
///
/// Pinned because both halves fail quietly. A tier that filters rows the page wasn't sized for
/// looks like a short buffer, not a bug; and `.none` hiding one type too many makes the buffer
/// lie about what happened rather than merely be quieter.
final class EventFilterTests: XCTestCase {

    private func settings(_ mode: String?) -> Settings {
        var s = Settings()
        if let mode { s.replaceValues([EventFilter.modeKey: .string(mode)]) }
        return s
    }

    // MARK: - The tier

    /// The phone always reads the mobile key. The tier is split by device class and this
    /// device is never the desktop case; reading `chat.events` here would silently honor a
    /// preference the user set for their laptop.
    func testReadsTheMobileKey() {
        XCTAssertEqual(EventFilter.modeKey, "chat.events.mobile")
    }

    func testResolvesEachRung() {
        XCTAssertEqual(EventFilter.mode(settings("all")), .all)
        XCTAssertEqual(EventFilter.mode(settings("smart")), .smart)
        XCTAssertEqual(EventFilter.mode(settings("none")), .none)
    }

    /// Before bootstrap lands, and against a server too old to know the key, the registry's
    /// own default is the only honest answer — anything else changes what the reader sees a
    /// moment after launch.
    func testDefaultsToAll() {
        XCTAssertEqual(EventFilter.mode(settings(nil)), .all)
        XCTAssertEqual(EventFilter.mode(settings("something-newer")), .all)
    }

    // MARK: - The noise set

    func testNoiseIsTheFoldSetPlusMode() {
        XCTAssertEqual(EventFilter.noiseTypes, Consolidation.consolidatableTypes.union([.mode]))
        for type: EventType in [.join, .part, .quit, .nick, .chghost, .mode] {
            XCTAssertTrue(EventFilter.isNoise(type), "\(type) should be noise")
        }
    }

    /// The line between churn and content. These are things that happened — being removed
    /// from a channel, the topic changing, an invite addressed to you — and no rung hides them.
    func testEventsThatCarryInformationAreNeverNoise() {
        for type: EventType in [.kick, .topic, .invite, .error, .message, .action, .notice] {
            XCTAssertFalse(EventFilter.isNoise(type), "\(type) should survive every tier")
        }
    }

    // MARK: - Page sizing

    func testPageUnitMatchesWhatWeRender() {
        var consolidating = settings("all")
        consolidating.apply(changes: ["chat.consolidate_joins": .bool(true)])
        XCTAssertEqual(HistoryCountBy.forRendering(consolidating), .renderable)

        var unfolded = settings("all")
        unfolded.apply(changes: ["chat.consolidate_joins": .bool(false)])
        XCTAssertEqual(HistoryCountBy.forRendering(unfolded), .event)
    }

    /// At `.none` consolidation is moot — there is nothing left to fold — so the tier decides
    /// alone. Leaving this to the consolidation flag would size pages in a unit that still
    /// counts `mode` rows the reader can't see.
    func testNoneAsksForChatCountingRegardlessOfConsolidation() {
        for folds in [true, false] {
            var s = settings("none")
            s.apply(changes: ["chat.consolidate_joins": .bool(folds)])
            XCTAssertEqual(HistoryCountBy.forRendering(s), .chat)
        }
    }

    /// There is no unit for `.smart`: which events it hides depends on who spoke recently,
    /// which the server can't know. It asks for the same unit `.all` would.
    func testSmartAsksForTheSameUnitAsAll() {
        var smart = settings("smart")
        smart.apply(changes: ["chat.consolidate_joins": .bool(true)])
        XCTAssertEqual(HistoryCountBy.forRendering(smart), .renderable)
    }

    // MARK: - The rung this client doesn't implement

    /// `.smart` stays readable but unselectable. The key is shared with the web, so a value
    /// set at a desk has to remain visible here rather than reading back as something else —
    /// but offering it in the picker would let someone choose a rung we then ignore.
    func testSmartIsReadableButNotSelectable() {
        XCTAssertEqual(EventFilter.mode(settings("smart")), .smart)
        XCTAssertFalse(EventFilter.isSelectable(.smart))
        XCTAssertTrue(EventFilter.isSelectable(.all))
        XCTAssertTrue(EventFilter.isSelectable(.none))
    }

    /// And it degrades to `.all` — stated, not inferred from a missing branch.
    func testSmartRendersAsAll() {
        XCTAssertEqual(EventFilter.rendered(.smart), .all)
        XCTAssertEqual(EventFilter.rendered(.none), .none)
        XCTAssertEqual(EventFilter.rendered(.all), .all)

        let rows = build([message(1, .message), message(2, .join, "bob")], mode: "smart")
        XCTAssertEqual(rows.compactMap { if case .line(let m) = $0 { m.id } else { nil } }, [2])
    }

    /// It travels on the wire as its raw value, so the spelling is protocol, not an enum name.
    func testChatWireSpelling() {
        XCTAssertEqual(HistoryCountBy.chat.rawValue, "chat")
    }

    // MARK: - What the list actually drops

    private func build(_ messages: [Message], mode: String) -> [MessageRow] {
        MessageRows.build(
            messages: messages, dividerAfterId: nil, hasMoreOlder: true,
            settings: settings(mode)
        )
    }

    private func message(
        _ id: Int, _ type: EventType, _ nick: String = "alice", isSelf: Bool = false
    ) -> Message {
        Message(
            id: id, type: type, nick: nick,
            text: type == .message ? "hi" : nil,
            isSelf: isSelf,
            date: Date(timeIntervalSince1970: 1_784_548_800),
            newNick: type == .nick ? "\(nick)_afk" : nil,
            modes: type == .mode ? [ModeChange(mode: "+o", param: nick)] : []
        )
    }

    func testNoneDropsEveryNoiseRow() {
        let rows = build(
            [
                message(1, .message),
                message(2, .join, "bob"),
                message(3, .mode, "op"),
                message(4, .quit, "carol"),
                message(5, .message),
            ],
            mode: "none"
        )
        let bubbles = rows.compactMap { if case .bubble(let m, _) = $0 { m.id } else { nil } }
        XCTAssertEqual(bubbles, [1, 5])
        // Nothing consolidated either: there is no run left to summarize.
        XCTAssertFalse(rows.contains { if case .consolidated = $0 { true } else { false } })
    }

    /// `.none` hides your own joins too. Someone who asked for no event noise on their phone
    /// wants none of it, not none-except-mine.
    func testNoneDropsYourOwnEventsAsWell() {
        let rows = build(
            [message(1, .message), message(2, .join, "me", isSelf: true)],
            mode: "none"
        )
        let lines: [Int] = rows.compactMap { if case .line(let m) = $0 { m.id } else { nil } }
        XCTAssertEqual(lines, [])
    }

    /// A buffer with messages can build to NO rows — the precondition behind a blank-screen
    /// bug in `ChatViewController`, which decided its empty-state placeholder from the raw
    /// message count. A quiet channel holding nothing but joins and mode changes has messages
    /// and renders nothing, so anything keyed off "are there messages" has to be keyed off the
    /// built rows instead. Pinned here because the two only started disagreeing with `.none`.
    func testAnAllNoiseBufferBuildsToNothing() {
        let rows = build(
            [message(1, .join, "bob"), message(2, .mode, "op"), message(3, .part, "bob")],
            mode: "none"
        )
        XCTAssertTrue(rows.isEmpty, "expected no rows, got \(rows)")
    }

    func testNoneKeepsKicksAndTopics() {
        let rows = build(
            [message(1, .kick, "bob"), message(2, .topic), message(3, .join, "eve")],
            mode: "none"
        )
        let lines = rows.compactMap { if case .line(let m) = $0 { m.type } else { nil } }
        XCTAssertEqual(lines, [.kick, .topic])
    }

    /// The control: at `.all` everything still arrives, so a regression in the filter can't
    /// hide behind a test that only ever asserts absence.
    func testAllKeepsEverything() {
        let messages = [
            message(1, .message), message(2, .join, "bob"),
            message(3, .mode, "op"), message(4, .message),
        ]
        let rows = build(messages, mode: "all")
        let ids = rows.compactMap {
            switch $0 {
            case .bubble(let m, _), .line(let m): m.id
            default: nil
            }
        }
        XCTAssertEqual(ids, [1, 2, 3, 4])
    }
}

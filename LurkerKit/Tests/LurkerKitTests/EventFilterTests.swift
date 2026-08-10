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

    /// It travels on the wire as its raw value, so the spelling is protocol, not an enum name.
    func testChatWireSpelling() {
        XCTAssertEqual(HistoryCountBy.chat.rawValue, "chat")
    }

    // MARK: - What the list actually drops

    private func build(
        _ messages: [Message],
        mode: String,
        speakers: SpeakerMap = SpeakerMap(),
        ownNick: String? = nil
    ) -> [MessageRow] {
        MessageRows.build(
            messages: messages, dividerAfterId: nil, hasMoreOlder: true,
            settings: settings(mode), speakers: speakers, ownNick: ownNick
        )
    }

    /// An arbitrary fixed instant. Every event and every speaker time in this file is expressed
    /// as an offset from it, so a window test says what it means without any clock arithmetic
    /// in the assertion.
    private static let t0 = Date(timeIntervalSince1970: 1_784_548_800)

    private static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func message(
        _ id: Int,
        _ type: EventType,
        _ nick: String = "alice",
        isSelf: Bool = false,
        at minutes: Double = 0
    ) -> Message {
        Message(
            id: id, type: type, nick: nick,
            text: type == .message ? "hi" : nil,
            isSelf: isSelf,
            date: Self.at(minutes),
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
        XCTAssertEqual(ids(of: rows), [1, 2, 3, 4])
    }

    // MARK: - The smart rung (#63)

    private func ids(of rows: [MessageRow]) -> [Int] {
        rows.compactMap {
            switch $0 {
            case .bubble(let m, _), .line(let m): m.id
            default: nil
            }
        }
    }

    /// The tier plus its five tuning keys. Consolidation is off throughout this section so the
    /// assertions read as "which events survived" rather than "what did the summary say" — the
    /// fold has its own tests, and pairing it with the filter here would let one hide the other.
    private func smart(
        delay: Int = 5, unmask: Int = 30, join: Bool = true, quit: Bool = true, nick: Bool = true
    ) -> Settings {
        var s = settings("smart")
        s.apply(changes: [
            "chat.consolidate_joins": .bool(false),
            "chat.smart_filter_delay": .int(delay),
            "chat.smart_filter_join_unmask": .int(unmask),
            "chat.smart_filter_join": .bool(join),
            "chat.smart_filter_quit": .bool(quit),
            "chat.smart_filter_nick": .bool(nick),
        ])
        return s
    }

    private func rows(
        _ messages: [Message],
        _ settings: Settings,
        speakers: SpeakerMap = SpeakerMap(),
        ownNick: String? = nil
    ) -> [Int] {
        ids(
            of: MessageRows.build(
                messages: messages, dividerAfterId: nil, hasMoreOlder: true,
                settings: settings, speakers: speakers, ownNick: ownNick
            )
        )
    }

    private func spoke(_ nick: String, at minutes: Double) -> SpeakerMap {
        SpeakerMap([Speaker(nick: nick, lastSpoke: Self.at(minutes))])
    }

    /// The premise: churn from someone nobody has heard from goes away, and the same churn from
    /// someone who was just talking stays. Both halves in one test, because either alone passes
    /// for a filter that is simply stuck.
    func testHidesChurnFromSilentNicksAndKeepsItFromRecentSpeakers() {
        let messages = [
            message(1, .message, "carol", at: 0),
            message(2, .part, "bob", at: 1),
            message(3, .part, "alice", at: 1),
        ]
        // alice spoke a minute before her part; bob hasn't spoken at all.
        XCTAssertEqual(rows(messages, smart(), speakers: spoke("alice", at: 0)), [1, 3])
    }

    func testEveryChurnTypeIsFilterable() {
        let churn: [EventType] = [.join, .part, .quit, .chghost, .nick]
        for (index, type) in churn.enumerated() {
            let messages = [message(index + 1, type, "bob", at: 1)]
            XCTAssertEqual(rows(messages, smart()), [], "\(type) from a silent nick should hide")
            XCTAssertEqual(
                rows(messages, smart(), speakers: spoke("bob", at: 0)), [index + 1],
                "\(type) from a recent speaker should render"
            )
        }
    }

    /// Speech *before* the event only counts inside the window. Outside it the nick is a lurker
    /// again — which is the whole point of the window being tunable.
    func testTheDelayWindowIsAWindow() {
        let part = [message(1, .part, "bob", at: 10)]
        XCTAssertEqual(rows(part, smart(delay: 5), speakers: spoke("bob", at: 6)), [1])
        XCTAssertEqual(rows(part, smart(delay: 5), speakers: spoke("bob", at: 5)), [1], "the edge counts")
        XCTAssertEqual(rows(part, smart(delay: 5), speakers: spoke("bob", at: 4)), [])
    }

    /// The unmask rule: someone who joins and immediately starts talking isn't retroactively
    /// invisible. This is the half no fetch can supply — the speech happens after the frame the
    /// speaker list was built from, so it only ever arrives as a live message.
    func testAJoinIsRevealedBySpeakingShortlyAfterIt() {
        let join = [message(1, .join, "bob", at: 0)]
        XCTAssertEqual(rows(join, smart(unmask: 30), speakers: spoke("bob", at: 20)), [1])
        XCTAssertEqual(rows(join, smart(unmask: 30), speakers: spoke("bob", at: 31)), [])
        XCTAssertEqual(rows(join, smart(unmask: 0), speakers: spoke("bob", at: 1)), [], "0 disables it")
    }

    /// Joins only. There is nothing to reveal about a part or a rename by what the nick says
    /// next — and a quit followed by speech is a nick that came back, which is its own join.
    func testOnlyJoinsUnmask() {
        for type: EventType in [.part, .quit, .nick, .chghost] {
            let event = [message(1, type, "bob", at: 0)]
            XCTAssertEqual(rows(event, smart(), speakers: spoke("bob", at: 1)), [], "\(type)")
        }
    }

    /// Per-type toggles, including the one that isn't its own toggle: `chghost` rides the quit
    /// switch rather than getting a fourth setting (lurker#591).
    func testPerTypeTogglesOptOutOfFiltering() {
        func surviving(_ settings: Settings) -> [Int] {
            rows(
                [
                    message(1, .join, "bob", at: 0),
                    message(2, .part, "bob", at: 0),
                    message(3, .quit, "bob", at: 0),
                    message(4, .chghost, "bob", at: 0),
                    message(5, .nick, "bob", at: 0),
                ],
                settings
            )
        }
        XCTAssertEqual(surviving(smart()), [])
        XCTAssertEqual(surviving(smart(join: false)), [1])
        XCTAssertEqual(surviving(smart(quit: false)), [2, 3, 4], "chghost rides the quit toggle")
        XCTAssertEqual(surviving(smart(nick: false)), [5])
    }

    /// Your own churn is never hidden, however quiet you've been. `isSelf` alone doesn't cover
    /// it — the server stamps that on messages you *sent*, not on the JOIN it saw you make —
    /// so the nick has to be checked too, case-insensitively like every other nick comparison.
    func testNeverHidesYourOwnChurn() {
        let messages = [
            message(1, .join, "Me", at: 0),
            message(2, .part, "me", isSelf: true, at: 0),
            message(3, .quit, "bob", at: 0),
        ]
        XCTAssertEqual(rows(messages, smart(), ownNick: "mE"), [1, 2])
    }

    /// The rung filters churn and nothing else. Conversation, kicks, topics and mode changes are
    /// things that happened — `.none` is the tier that hides those, and only some of them.
    func testSmartLeavesEverythingThatIsNotChurnAlone() {
        let messages = [
            message(1, .message, "bob", at: 0),
            message(2, .action, "bob", at: 0),
            message(3, .notice, "bob", at: 0),
            message(4, .kick, "bob", at: 0),
            message(5, .topic, "bob", at: 0),
            message(6, .mode, "bob", at: 0),
            message(7, .invite, "bob", at: 0),
        ]
        XCTAssertEqual(rows(messages, smart()), [1, 2, 3, 4, 5, 6, 7])
    }

    /// An unseeded buffer hides every filterable event, matching the web. Worth pinning because
    /// the alternative failure — showing everything until the map loads — looks like the filter
    /// working intermittently rather than like a missing seed.
    func testAnEmptySpeakerMapHidesAllChurn() {
        XCTAssertEqual(rows([message(1, .join, "bob", at: 0)], smart()), [])
    }

    /// An event with no clock renders. There is no window to judge it against, and the web's
    /// `Date.parse(…) || 0` reads it as the epoch — infinitely stale, therefore always hidden,
    /// which is the wrong way to fail for a row whose only problem is a missing timestamp.
    func testAnUndatedEventIsNotJudged() {
        let undated = Message(id: 1, type: .join, nick: "bob", text: nil, isSelf: false, date: nil)
        XCTAssertEqual(rows([undated], smart()), [1])
    }

    /// The filter runs *above* consolidation, so a hidden event can't be counted by a summary
    /// it never reached. Getting this backwards is invisible in the row stream and shows up as a
    /// summary that names people whose own lines aren't on screen.
    func testFilteringHappensBeforeConsolidation() {
        var folding = smart()
        folding.apply(changes: ["chat.consolidate_joins": .bool(true)])
        let built = MessageRows.build(
            messages: [
                message(1, .join, "alice", at: 1),
                message(2, .join, "bob", at: 1),
                message(3, .join, "carol", at: 1),
            ],
            dividerAfterId: nil, hasMoreOlder: true,
            settings: folding, speakers: spoke("alice", at: 0)
        )
        // alice spoke, so her join survives — alone, which is a line rather than a summary.
        XCTAssertEqual(ids(of: built), [1])
        XCTAssertFalse(built.contains { if case .consolidated = $0 { true } else { false } })
    }
}

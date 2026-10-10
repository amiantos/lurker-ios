// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Which live lines and presence flips become an in-app notification, and of what kind.
final class StatusNotificationTests: XCTestCase {
    private func line(
        notify: Bool = true, isSelf: Bool = false, matched: Bool = false, dm: Bool = false,
        notifyAlways: Bool = false, selfKicked: Bool = false
    ) -> Message {
        Message(
            id: 42, type: .message, nick: "bob", text: "\u{02}hey\u{02} there", isSelf: isSelf,
            matched: matched, notify: notify, dm: dm, notifyAlways: notifyAlways, selfKicked: selfKicked
        )
    }

    private func settings(_ values: [String: SettingValue] = [:]) -> Settings {
        Settings(registry: [:], values: values)
    }

    // MARK: - Lines

    func testKindFollowsTheWebsPriority() {
        let s = settings()
        func kind(_ m: Message) -> StatusNotification.Kind? {
            StatusNotification.make(networkId: 1, target: "#a", message: m, settings: s)?.kind
        }
        XCTAssertEqual(kind(line(matched: true, dm: true, notifyAlways: true, selfKicked: true)), .kicked)
        XCTAssertEqual(kind(line(matched: true, dm: true, notifyAlways: true)), .dm)
        XCTAssertEqual(kind(line(matched: true, notifyAlways: true)), .highlight)
        XCTAssertEqual(kind(line(notifyAlways: true)), .alwaysNotify)
    }

    func testNothingWithoutTheServersVerdictOrForOurOwnLine() {
        let s = settings()
        XCTAssertNil(StatusNotification.make(networkId: 1, target: "#a", message: line(notify: false, matched: true), settings: s))
        XCTAssertNil(StatusNotification.make(networkId: 1, target: "#a", message: line(isSelf: true, matched: true), settings: s))
        XCTAssertNil(StatusNotification.make(networkId: 1, target: "#a", message: line(notify: true), settings: s))
        XCTAssertNil(StatusNotification.make(networkId: nil, target: "#a", message: line(matched: true), settings: s))
    }

    func testAKindSwitchedOffSaysNothing() {
        let off = settings(["notifications.highlight.enabled": .bool(false)])
        XCTAssertNil(StatusNotification.make(networkId: 1, target: "#a", message: line(matched: true), settings: off))
        XCTAssertEqual(
            StatusNotification.make(networkId: 1, target: "bob", message: line(dm: true), settings: off)?.kind, .dm
        )
    }

    func testEachKindHasItsOwnSwitch() {
        func off(_ kind: String) -> Settings { settings(["notifications.\(kind).enabled": .bool(false)]) }
        XCTAssertNil(StatusNotification.make(networkId: 1, target: "#a", message: line(selfKicked: true), settings: off("kicked")))
        XCTAssertNil(StatusNotification.make(networkId: 1, target: "bob", message: line(dm: true), settings: off("dm")))
        XCTAssertNil(StatusNotification.make(networkId: 1, target: "#a", message: line(notifyAlways: true), settings: off("always_notify")))
        // Each switch is its own: turning DMs off leaves always-notify alone.
        XCTAssertEqual(
            StatusNotification.make(networkId: 1, target: "#a", message: line(notifyAlways: true), settings: off("dm"))?.kind,
            .alwaysNotify
        )
    }

    /// The flags as the server's `decorateMessage` spreads them onto a live frame.
    func testTheServersFlagsAreReadOffTheFrame() {
        guard case let .live(_, _, message) = FrameParser.parseWs(
            ##"{"kind":"irc","id":7,"networkId":1,"target":"#lurker","type":"kick","nick":"op","text":"bye","self":false,"notify":true,"dm":true,"notifyAlways":true,"selfKicked":true}"##
        ) else { return XCTFail("expected live") }
        XCTAssertTrue(message.notify)
        XCTAssertTrue(message.dm)
        XCTAssertTrue(message.notifyAlways)
        XCTAssertTrue(message.selfKicked)
        guard case let .live(_, _, plain) = FrameParser.parseWs(
            ##"{"kind":"irc","id":8,"networkId":1,"target":"#lurker","type":"message","nick":"op","text":"hi","self":false}"##
        ) else { return XCTFail("expected live") }
        XCTAssertFalse(plain.notify || plain.dm || plain.notifyAlways || plain.selfKicked)
    }

    /// A detached buffer keeps live lines in `heldLive`; a repeat of one is still a repeat.
    func testAHeldLineCountsAsHeld() {
        var state = ChatState()
        let key = BufferKey(networkId: 1, target: "#a").id
        let held = line(matched: true)
        XCTAssertFalse(state.alreadyHolds(held, key: key))
        state.heldLive[key] = [held]
        XCTAssertTrue(state.alreadyHolds(held, key: key))
        state.heldLive[key] = nil
        state.messages[key] = [held]
        XCTAssertTrue(state.alreadyHolds(held, key: key))
        // Ephemeral lines are never repeats.
        let ephemeral = Message(id: 0, type: .message, nick: "bob", text: "x")
        state.messages[key] = [ephemeral]
        XCTAssertFalse(state.alreadyHolds(ephemeral, key: key))
    }

    func testTextIsStrippedOfFormatting() {
        let n = StatusNotification.make(networkId: 1, target: "#a", message: line(matched: true), settings: settings())
        XCTAssertEqual(n?.text, "hey there")
        XCTAssertEqual(n?.messageId, 42)
        XCTAssertEqual(n?.key, BufferKey(networkId: 1, target: "#a"))
    }

    // MARK: - Sounds

    func testEachKindsSoundFollowsTheRegistryDefaults() {
        func sound(_ m: Message, _ s: Settings = Settings(registry: [:], values: [:])) -> String? {
            StatusNotification.make(networkId: 1, target: "#a", message: m, settings: s)?.sound(in: s)
        }
        // Off by default for the everyday kinds, on for the ones that are rarer and louder.
        XCTAssertNil(sound(line(matched: true)))
        XCTAssertNil(sound(line(dm: true)))
        XCTAssertEqual(sound(line(notifyAlways: true)), "plink")
        XCTAssertEqual(sound(line(selfKicked: true)), "beep")
        // Switched on, each has its own default sound.
        let on = settings([
            "notifications.highlight.sound.enabled": .bool(true),
            "notifications.dm.sound.enabled": .bool(true),
        ])
        XCTAssertEqual(sound(line(matched: true), on), "ping")
        XCTAssertEqual(sound(line(dm: true), on), "chime")
    }

    func testTheChosenSoundAndVolume() {
        let n = StatusNotification.make(networkId: 1, target: "#a", message: line(matched: true), settings: settings())!
        func sound(_ values: [String: SettingValue]) -> String? {
            n.sound(in: settings(["notifications.highlight.sound.enabled": .bool(true)].merging(values) { $1 }))
        }
        XCTAssertEqual(sound(["notifications.highlight.sound.choice": .string("knock")]), "knock")
        // A choice this build doesn't bundle falls back to the kind's default rather than silence.
        XCTAssertEqual(sound(["notifications.highlight.sound.choice": .string("gong")]), "ping")
        XCTAssertNil(sound(["notifications.highlight.sound.volume": .int(0)]))
        XCTAssertNil(sound(["notifications.highlight.sound.enabled": .bool(false)]))
    }

    func testAFriendComingOnlineHasItsOwnSound() {
        var state = ChatState()
        state.peerPresence[1] = ["bob": .offline]
        state.favorites = [FavoriteEntry(networkId: 1, target: "Bob", bufferId: 9)]
        let n = StatusNotification.cameOnline(.peerPresence(networkId: 1, nick: "Bob", state: .online), before: state)
        XCTAssertNil(n?.sound(in: state.settings))
        XCTAssertEqual(n?.sound(in: settings(["notifications.friend_online.sound.enabled": .bool(true)])), "knock")
    }

    // MARK: - Came online

    private func state(was presence: PresenceState?, favorite: Bool = true, enabled: Bool? = nil) -> ChatState {
        var state = ChatState()
        if let presence { state.peerPresence[1] = ["bob": presence] }
        if favorite { state.favorites = [FavoriteEntry(networkId: 1, target: "Bob", bufferId: 9)] }
        if let enabled { state.settings = settings(["notifications.friend_online.enabled": .bool(enabled)]) }
        return state
    }

    private let online = ServerFrame.peerPresence(networkId: 1, nick: "Bob", state: .online)

    func testAFriendGoingFromOfflineToOnlineIsNews() {
        let n = StatusNotification.cameOnline(online, before: state(was: .offline))
        XCTAssertEqual(n?.kind, .friendOnline)
        XCTAssertEqual(n?.nick, "Bob")
        XCTAssertEqual(n?.key, BufferKey(networkId: 1, target: "Bob"))
        XCTAssertEqual(n?.messageId, 0)
    }

    func testOnlyAWitnessedFlipCounts() {
        // MONITOR's seed, or a nick freshly added to the watch: the current state, not an arrival.
        XCTAssertNil(StatusNotification.cameOnline(online, before: state(was: nil)))
        // Back from away is not coming online.
        XCTAssertNil(StatusNotification.cameOnline(online, before: state(was: .away)))
        XCTAssertNil(StatusNotification.cameOnline(online, before: state(was: .online)))
        XCTAssertNil(StatusNotification.cameOnline(
            .peerPresence(networkId: 1, nick: "Bob", state: .away), before: state(was: .offline)
        ))
    }

    func testOnlyFriendsAndOnlyWhenSwitchedOn() {
        XCTAssertNil(StatusNotification.cameOnline(online, before: state(was: .offline, favorite: false)))
        XCTAssertNil(StatusNotification.cameOnline(online, before: state(was: .offline, enabled: false)))
    }
}

/// The came-online check reads the presence the frame is about to replace, so it has to run
/// before the store applies it — through `handle`, where that order lives.
@MainActor
final class CameOnlineHandleTests: XCTestCase {
    func testHandleSeesTheFlipAndOnlyTheFlip() {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.cameonline"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.cameonline")!)
        )
        model.handle(.socketOpen)
        model.handle(.snapshot(
            [NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])],
            globalIgnores: [], uploadLimits: .unstated
        ))
        model.handle(.favoritesChanged([FavoriteEntry(networkId: 1, target: "bob", bufferId: 9)]))
        var notified: [String] = []
        model.onNotify = { notified.append("\($0.kind.rawValue) \($0.nick ?? "")") }

        model.handle(.peerPresence(networkId: 1, nick: "bob", state: .online)) // the seed
        model.handle(.peerPresence(networkId: 1, nick: "bob", state: .offline))
        model.handle(.peerPresence(networkId: 1, nick: "bob", state: .online))
        model.handle(.peerPresence(networkId: 1, nick: "bob", state: .online)) // a repeat
        XCTAssertEqual(notified, ["friend_online bob"])
    }

    /// A line the store already holds — a backlog/live overlap — is dropped, and so is its alert.
    func testARepeatedLineAlertsOnce() {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.cameonline"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.cameonline")!)
        )
        model.handle(.socketOpen)
        model.handle(.snapshot(
            [NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])],
            globalIgnores: [], uploadLimits: .unstated
        ))
        var notified: [Int] = []
        model.onNotify = { notified.append($0.messageId) }
        let line = Message(id: 77, type: .message, nick: "bob", text: "me: hi", matched: true, notify: true)
        model.handle(.live(networkId: 1, target: "#lurker", message: line))
        model.handle(.live(networkId: 1, target: "#lurker", message: line))
        XCTAssertEqual(notified, [77])
    }
}

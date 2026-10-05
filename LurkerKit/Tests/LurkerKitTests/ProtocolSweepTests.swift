// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Wire fields the kit wasn't reading (the client sweep's protocol batch, L10/L21/L22/L41): the
/// fresh connect's resume cursor, a provisional nicklist, a 421 naming the command it refused, and
/// an invitation addressed to us. The web read all four; the kit dropped them.
@MainActor
final class ProtocolSweepTests: XCTestCase {

    private let channel = BufferKey(networkId: 1, target: "#lurker")

    private func viewModel(ignoring: [IgnoreRule] = []) -> ChatViewModel {
        let model = ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.protocolsweep"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.protocolsweep")!)
        )
        model.handle(.socketOpen)
        model.handle(.snapshot(
            [NetworkSnapshot(
                id: 1, state: .connected, nick: "me",
                channels: [ChannelSnapshot(name: "#lurker", topic: nil, members: [])],
                ignoredMasks: ignoring
            )],
            globalIgnores: [], uploadLimits: .unstated
        ))
        return model
    }

    private func snapshot(_ members: [Member], pending: Bool = false, cursor: Int? = nil) -> ServerFrame {
        .snapshot(
            [NetworkSnapshot(
                id: 1, state: .connected, nick: "me",
                channels: [ChannelSnapshot(name: "#lurker", topic: nil, members: members, membersPending: pending)]
            )],
            globalIgnores: [], uploadLimits: .unstated, cursor: cursor
        )
    }

    // MARK: - L10: the snapshot's cursor

    func testTheSnapshotCursorIsParsedAndAbsentOnAResume() {
        let fresh = FrameParser.parseWs(##"{"kind":"snapshot","networks":[],"cursor":4821}"##)
        guard case let .snapshot(_, _, _, cursor) = fresh else { return XCTFail("got \(fresh)") }
        XCTAssertEqual(cursor, 4821)

        let resume = FrameParser.parseWs(##"{"kind":"snapshot","networks":[]}"##)
        guard case let .snapshot(_, _, _, none) = resume else { return XCTFail("got \(resume)") }
        XCTAssertNil(none)
    }

    /// A fresh connect's channels come as shells with no rows, so the cursor is what moves the
    /// resume point past the server logs. A reconnect before anything live then asks from here,
    /// not from the newest server-log id.
    func testAFreshConnectsCursorRaisesTheResumePoint() {
        let store = LurkerStore()
        store.apply(.live(networkId: 1, target: ":server:1", message: Message(id: 120, type: .notice, nick: "srv", text: "welcome")))
        XCTAssertEqual(store.state.maxEventId, 120)
        store.apply(snapshot([], cursor: 4821))
        XCTAssertEqual(store.state.maxEventId, 4821)

        // Never lowered: the cursor is the server's max when it sent the snapshot, and a row
        // held from before can't be newer, but a stale number must not pull the watermark back.
        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 5000, type: .message, nick: "a", text: "x")))
        store.apply(snapshot([], cursor: 4821))
        XCTAssertEqual(store.state.maxEventId, 5000)

        // A resume's snapshot carries none and moves nothing.
        store.apply(snapshot([]))
        XCTAssertEqual(store.state.maxEventId, 5000)
    }

    // MARK: - L21: membersPending

    func testMembersPendingIsParsedOnTheSnapshotAndOnNames() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":1,"state":"connected","nick":"me","channels":[{"name":"#a","members":[],"membersPending":true},{"name":"#b","members":[]}]}]}"##
        )
        guard case let .snapshot(networks, _, _, _) = frame else { return XCTFail("got \(frame)") }
        XCTAssertEqual(networks[0].channels.map(\.membersPending), [true, false])

        let names = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#a","type":"names","members":[{"nick":"me","modes":[]}],"membersPending":true}"##
        )
        guard case let .channelMembers(_, _, _, pending) = names else { return XCTFail("got \(names)") }
        XCTAssertTrue(pending)
    }

    /// After an engine re-attach the server has heard no channel's NAMES, so what it sends is us
    /// plus whoever has joined since. Taking it reads as everyone leaving.
    func testAPendingListNeverReplacesAHeldOne() {
        let store = LurkerStore()
        store.apply(snapshot([Member(nick: "me"), Member(nick: "alice"), Member(nick: "bob")]))

        store.apply(snapshot([Member(nick: "me")], pending: true))
        XCTAssertEqual(store.state.members[channel.id]?.map(\.nick), ["me", "alice", "bob"], "snapshot")

        store.apply(.channelMembers(networkId: 1, target: "#lurker", members: [Member(nick: "me")], pending: true))
        XCTAssertEqual(store.state.members[channel.id]?.map(\.nick), ["me", "alice", "bob"], "names")

        // The definitive list, when it lands, is the list.
        store.apply(.channelMembers(networkId: 1, target: "#lurker", members: [Member(nick: "me"), Member(nick: "carol")]))
        XCTAssertEqual(store.state.members[channel.id]?.map(\.nick), ["me", "carol"])
    }

    /// With nothing held, a provisional list beats none.
    func testAPendingListIsTakenWhenNoneIsHeld() {
        let store = LurkerStore()
        store.apply(snapshot([Member(nick: "me")], pending: true))
        XCTAssertEqual(store.state.members[channel.id]?.map(\.nick), ["me"])

        let other = LurkerStore()
        other.apply(.channelMembers(networkId: 1, target: "#lurker", members: [Member(nick: "me")], pending: true))
        XCTAssertEqual(other.state.members[channel.id]?.map(\.nick), ["me"])
    }

    // MARK: - L22: unknownCommand

    func testUnknownCommandIsReadOffAnErrorLineOnly() {
        let error = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":":server:1","type":"error","id":50,"text":"unknown_command FROBNICATE — Unknown command","unknownCommand":"FROBNICATE"}"##
        )
        guard case let .live(_, _, message) = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(message.unknownCommand, "FROBNICATE")

        let notice = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":":server:1","type":"notice","id":51,"nick":"srv","text":"x","unknownCommand":"FROBNICATE"}"##
        )
        guard case let .live(_, _, other) = notice else { return XCTFail("got \(notice)") }
        XCTAssertNil(other.unknownCommand)
    }

    private func unknownCommand(_ verb: String, id: Int = 50) -> ServerFrame {
        .live(networkId: 1, target: ":server:1", message: Message(
            id: id, type: .error, nick: nil, text: "unknown_command \(verb) — Unknown command",
            unknownCommand: verb
        ))
    }

    /// The 421 lands in the server log; the buffer the command was typed in says so too, once.
    func testA421SaysSoWhereTheCommandWasTyped() {
        let model = viewModel()
        model.sendRawSeam = { _ in true }
        model.send(channel, text: "/frobnicate now")
        model.handle(unknownCommand("FROBNICATE"))
        XCTAssertEqual(model.state.messages[channel.id]?.last?.text, "Unknown command: /frobnicate")

        let count = model.state.messages[channel.id]?.count
        model.handle(unknownCommand("FROBNICATE", id: 51))
        XCTAssertEqual(model.state.messages[channel.id]?.count, count, "one send, one notice")
    }

    /// Another device's `/frobnicate` 421s on this socket too; that device says so, not this one.
    func testA421ForALineThisDeviceDidntSendSaysNothing() {
        let model = viewModel()
        model.handle(unknownCommand("FROBNICATE"))
        XCTAssertNil(model.state.messages[channel.id]?.last)
    }

    /// Typed in the server log, the 421 already shows where it was typed: one line, not two.
    func testA421ForALineTypedInTheServerLogAddsNothing() {
        let model = viewModel()
        model.sendRawSeam = { _ in true }
        let server = BufferKey(networkId: 1, target: ":server:1")
        model.send(server, text: "/frobnicate")
        model.handle(unknownCommand("FROBNICATE"))
        XCTAssertNotNil(model.state.buffers[server.id], "the 421 made the row, so only the guard is left to say no")
        XCTAssertEqual(model.state.messages[server.id]?.filter { $0.id == 0 }.count ?? 0, 0, "only the server's own line")
    }

    /// A raw line the ircd accepted, or whose 421 was lost with the socket, doesn't wait forever:
    /// past the window, a 421 for that verb is another device's.
    func testA421PastTheWindowIsSomeoneElses() {
        let model = viewModel()
        model.sendRawSeam = { _ in true }
        model.send(channel, text: "/frobnicate")
        guard case let .live(networkId, _, message) = unknownCommand("FROBNICATE") else { return XCTFail() }
        model.noteUnknownCommand(
            networkId: networkId, message, now: Date().addingTimeInterval(ChatViewModel.unknownCommandWindow + 1)
        )
        XCTAssertNil(model.state.messages[channel.id]?.last)
    }

    /// `/raw` lets a tag block or a source prefix come first; the command is the word after them.
    func testTheRawVerbSkipsTagsAndPrefix() {
        XCTAssertEqual(ChatViewModel.rawVerb("frobnicate now"), "frobnicate")
        XCTAssertEqual(ChatViewModel.rawVerb("@label=x FROBNICATE now"), "FROBNICATE")
        XCTAssertEqual(ChatViewModel.rawVerb("@label=x :me FROBNICATE"), "FROBNICATE")
        XCTAssertNil(ChatViewModel.rawVerb("@label=x"))
    }

    /// A line that went nowhere came back to the composer; there is no 421 to wait for.
    func testARawLineThatWentNowhereIsntWaitedOn() {
        let model = viewModel()
        model.sendRawSeam = { _ in false }
        model.send(channel, text: "/frobnicate")
        model.handle(unknownCommand("FROBNICATE"))
        XCTAssertNil(model.state.messages[channel.id]?.last)
    }

    // MARK: - L41: invitations

    func testAnInviteNamingUsIsItsOwnFrameAndAChannelsInviteLineIsALine() {
        XCTAssertEqual(
            FrameParser.parseWs(
                ##"{"kind":"irc","networkId":1,"target":":server:1","type":"invite","channel":"#secret","from":"bob","userhost":"bob!b@example.org"}"##
            ),
            .invited(networkId: 1, channel: "#secret", from: "bob", userhost: "bob!b@example.org")
        )
        let line = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"invite","id":9,"nick":"alice","invited":"carol"}"##
        )
        guard case let .live(_, target, message) = line else { return XCTFail("got \(line)") }
        XCTAssertEqual(target, "#lurker")
        XCTAssertEqual(message.invited, "carol")
        XCTAssertTrue(message.isRenderable)
    }

    func testAnInvitationIsOfferedUnlessWereAlreadyIn() {
        let model = viewModel()
        var offered: [String] = []
        model.onInvited = { networkId, channel, from in offered.append("\(networkId) \(channel) \(from)") }
        model.handle(.invited(networkId: 1, channel: "#secret", from: "bob"))
        model.handle(.invited(networkId: 1, channel: "#lurker", from: "bob"))
        XCTAssertEqual(offered, ["1 #secret bob"])
    }

    /// Someone ignored outright doesn't get a prompt; the system buffer still has the line.
    func testAnIgnoredInvitersInvitationIsNotOffered() {
        let model = viewModel(ignoring: [IgnoreRule(mask: "troll!*@*")])
        var offered: [String] = []
        model.onInvited = { _, channel, from in offered.append("\(channel) \(from)") }
        model.handle(.invited(networkId: 1, channel: "#spam", from: "troll", userhost: "troll!t@example.org"))
        model.handle(.invited(networkId: 1, channel: "#secret", from: "bob", userhost: "bob!b@example.org"))
        XCTAssertEqual(offered, ["#secret bob"])
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The store's frame-folding is the tricky, pure-logic core of the client — shell vs.
/// hydrated backlog, live de-dupe, snapshot merge, name merge. Drive it with hand-built
/// frames (no JSON), asserting the folded state. Ported from the Android LurkerStoreTest.
@MainActor
final class LurkerStoreTests: XCTestCase {

    private let chanKey = "1::#lurker"

    private func msg(_ id: Int, _ text: String, isSelf: Bool = false) -> Message {
        Message(id: id, type: .message, nick: "alice", text: text, isSelf: isSelf)
    }

    private func channelBuffer(hydrated: Bool, messages: [Message]) -> ServerFrame {
        .backlog(
            buffer: Buffer(networkId: 1, target: "#lurker", kind: .channel, hydrated: hydrated),
            messages: messages,
            hydrated: hydrated,
            append: false
        )
    }

    func testShellRegistersTheBufferButLeavesItEmptyAndUnhydrated() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: false, messages: []))

        let state = store.state
        XCTAssertNotNil(state.buffers[chanKey], "buffer should be listed")
        XCTAssertFalse(state.buffers[chanKey]!.hydrated, "shell is not hydrated")
        XCTAssertEqual(state.messages[chanKey], [])
    }

    func testHydratedBacklogFillsTheBufferAndReplacesMessagesWholesale() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: false, messages: []))
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi"), msg(2, "there")]))

        let state = store.state
        XCTAssertTrue(state.buffers[chanKey]!.hydrated)
        XCTAssertEqual(state.messages[chanKey]!.map(\.text), ["hi", "there"])
    }

    func testHydrationPreservesLiveEventsNewerThanTheBacklogTail() {
        let store = LurkerStore()
        // Shell, then a live event arrives before the user opens the buffer.
        store.apply(channelBuffer(hydrated: false, messages: []))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(50, "arrived-before-open")))
        // Open → the hydrated backlog was built a moment earlier and tops out at id 40,
        // so it doesn't contain id 50. The live event must survive the replace.
        store.apply(channelBuffer(hydrated: true, messages: [msg(38, "a"), msg(40, "b")]))

        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["a", "b", "arrived-before-open"])
    }

    func testALaterShellNeverUnhydratesOrWipesAnAlreadyReadBuffer() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        // A resync ships the buffer again as a shell.
        store.apply(channelBuffer(hydrated: false, messages: []))

        let state = store.state
        XCTAssertTrue(state.buffers[chanKey]!.hydrated, "hydration must stick")
        XCTAssertEqual(state.messages[chanKey]!.map(\.text), ["hi"])
    }

    func testLiveEventsAppendButDedupeAgainstAPersistedIdAlreadyPresent() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(5, "hi")]))
        // The same id arrives live (backlog/live overlap) — must not double.
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(5, "hi")))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(6, "new")))

        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["hi", "new"])
    }

    func testEphemeralLiveEventsAlwaysAppendEvenWhenIdentical() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: []))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(0, "poke")))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(0, "poke")))

        XCTAssertEqual(store.state.messages[chanKey]!.count, 2)
    }

    func testALiveEventForAnUnknownTargetMaterializesABufferRow() {
        let store = LurkerStore()
        // A DM from bob arrives with no prior buffer (no snapshot, no backlog).
        store.apply(.live(networkId: 1, target: "bob", message: msg(7, "hey")))

        let state = store.state
        let key = "1::bob"
        XCTAssertNotNil(state.buffers[key], "the new DM must appear in the buffer list")
        XCTAssertEqual(state.buffers[key]!.kind, .dm)
        XCTAssertFalse(state.buffers[key]!.hydrated, "unhydrated so tapping fetches history")
        XCTAssertEqual(state.messages[key]!.map(\.text), ["hey"])
    }

    func testDifferentlyCasedTargetsFoldToTheSameBuffer() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")])) // "#lurker"
        store.apply(.live(networkId: 1, target: "#LURKER", message: msg(2, "yo"))) // upper-cased

        let state = store.state
        XCTAssertEqual(state.buffers.count, 1, "must not split into a second buffer")
        XCTAssertEqual(state.messages[chanKey]!.map(\.text), ["hi", "yo"])
    }

    func testAResumeGapSliceAppendsAndDedupesAResetReplaces() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "a"), msg(2, "b")]))

        // reset:false gap — id 2 overlaps (drop), id 3 is new (append).
        store.apply(.backlog(
            buffer: Buffer(networkId: 1, target: "#lurker", kind: .channel, hydrated: true),
            messages: [msg(2, "b"), msg(3, "c")],
            hydrated: true,
            append: true
        ))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["a", "b", "c"])

        // reset (oversized gap) replaces wholesale.
        store.apply(.backlog(
            buffer: Buffer(networkId: 1, target: "#lurker", kind: .channel, hydrated: true),
            messages: [msg(9, "z")],
            hydrated: true,
            append: false
        ))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["z"])
    }

    func testHistoryBeforePrependsOlderAndDedupes() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(5, "e"), msg(6, "f")]))
        // A before-page brings 3,4 and re-sends 5 (overlap): prepend 3,4, drop the dup 5.
        store.apply(.history(
            networkId: 1, target: "#lurker",
            events: [msg(3, "c"), msg(4, "d"), msg(5, "e")],
            mode: .before, hasMoreOlder: false, hasMoreNewer: false
        ))

        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["c", "d", "e", "f"])
        XCTAssertFalse(store.state.buffers[chanKey]!.hasMoreOlder, "hasMoreOlder:false stops paging")
    }

    func testHistoryTracksHasMoreOlderForThePagingGate() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(5, "e")]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(4, "d")],
            mode: .before, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertTrue(store.state.buffers[chanKey]!.hasMoreOlder)
    }

    func testSnapshotSeedsChannelBuffersMembersAndNetworkLiveState() {
        let store = LurkerStore()
        store.apply(.snapshot([
            NetworkSnapshot(
                id: 1,
                state: .connected,
                nick: "me",
                channels: [
                    ChannelSnapshot(
                        name: "#lurker",
                        topic: "welcome",
                        members: [Member(nick: "alice", modes: ["o"]), Member(nick: "bob")]
                    ),
                ]
            ),
        ]))

        let state = store.state
        XCTAssertEqual(state.networks[1]!.state, .connected)
        XCTAssertEqual(state.networks[1]!.nick, "me")
        XCTAssertTrue(state.buffers[chanKey]!.joined)
        XCTAssertEqual(state.buffers[chanKey]!.kind, .channel)
        XCTAssertEqual(state.members[chanKey]!.map(\.nick), ["alice", "bob"])
    }

    func testRestNamesMergeOntoSnapshotCreatedNetworksWithoutDroppingLiveState() {
        let store = LurkerStore()
        // Snapshot arrives first (name unknown), then the REST roster supplies it.
        store.apply(.snapshot([NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])]))
        store.apply(.networks([Network(id: 1, name: "Libera")]))

        let network = store.state.networks[1]!
        XCTAssertEqual(network.name, "Libera")
        XCTAssertEqual(network.state, .connected, "live state must survive the name merge")
    }

    func testConnectionStatusMovesConnectingToConnectedToReconnecting() {
        let store = LurkerStore()
        XCTAssertEqual(store.state.connection, .connecting)
        store.apply(.socketOpen)
        XCTAssertEqual(store.state.connection, .connected)
        // A drop after being connected is a reconnect, not a first connect.
        store.apply(.socketClosed(reason: "bye", code: 1000))
        XCTAssertEqual(store.state.connection, .reconnecting)
        // Still reconnecting across further failed attempts.
        store.apply(.socketClosed(reason: "again", code: nil))
        XCTAssertEqual(store.state.connection, .reconnecting)
    }

    func testADropBeforeTheFirstOpenStaysConnectingNotReconnecting() {
        let store = LurkerStore()
        store.apply(.socketClosed(reason: "refused", code: nil))
        XCTAssertEqual(store.state.connection, .connecting)
    }

    func testMaxEventIdTracksTheHighestPersistedIdButIgnoresTheSystemBuffer() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(10, "a"), msg(7, "b")]))
        XCTAssertEqual(store.state.maxEventId, 10)

        store.apply(.live(networkId: 1, target: "#lurker", message: msg(15, "c")))
        XCTAssertEqual(store.state.maxEventId, 15)

        // System-buffer ids are a separate space and must not move the resume cursor.
        store.apply(.live(networkId: nil, target: ":system:", message: msg(9999, "sys")))
        XCTAssertEqual(store.state.maxEventId, 15)

        // An older id doesn't lower the watermark.
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(3, "old")))
        XCTAssertEqual(store.state.maxEventId, 15)
    }

    func testAFailedSendResultSurfacesItsErrorAnOkOneDoesNot() {
        let store = LurkerStore()
        store.apply(.sendResult(clientId: "c1", ok: false, error: "account-paused"))
        XCTAssertEqual(store.state.error, "account-paused")

        store.apply(.socketOpen) // clears error
        XCTAssertNil(store.state.error)
        store.apply(.sendResult(clientId: "c2", ok: true, error: nil))
        XCTAssertNil(store.state.error)
    }
}

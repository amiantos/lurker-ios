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

    func testHistoryAroundReplacesRatherThanSplicingOntoFarNewerMessages() {
        let store = LurkerStore()
        // The buffer holds recent messages; a jump to an OLD message fetches a slice centered
        // far below them. Keeping the recent ones would render a hole — around replaces.
        store.apply(channelBuffer(hydrated: true, messages: [msg(500, "recent1"), msg(501, "recent2")]))
        store.apply(.history(
            networkId: 1, target: "#lurker",
            events: [msg(9, "old1"), msg(10, "anchor"), msg(11, "old2")],
            mode: .around, hasMoreOlder: true, hasMoreNewer: true
        ))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["old1", "anchor", "old2"])
        XCTAssertTrue(store.state.buffers[chanKey]!.hydrated)
    }

    func testAroundBelowTheTailDetachesAndHoldsBackLiveEvents() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(500, "recent")]))
        // Jump to an old message: the slice reports newer messages remain → detached.
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "anchor")],
            mode: .around, hasMoreOlder: true, hasMoreNewer: true
        ))
        XCTAssertTrue(store.state.buffers[chanKey]!.hasMoreNewer, "an around slice below the tail detaches")
        // A live message must NOT splice onto the old slice.
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(999, "live")))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["anchor"], "live is held back while detached")
        XCTAssertEqual(store.state.maxEventId, 999, "but the resume cursor still advances past it")
    }

    /// The reconnect bug: a resume frame must not stitch the present onto a jump slice.
    func testResumeBacklogLeavesADetachedBufferAloneRatherThanSplicingIt() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(500, "recent")]))
        // Jump to a much older message (a bookmark, #42) — the buffer detaches.
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "anchor")],
            mode: .around, hasMoreOlder: true, hasMoreNewer: true
        ))
        // Traffic arrives while detached: held out of the log, but it advances the resume
        // cursor, so the server will never re-send it in a gap.
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(600, "missed")))
        // Now the socket drops and comes back (backgrounding the app is enough). The resume
        // frame carries only what landed while we were away — everything from 601 up.
        store.apply(.backlog(
            buffer: Buffer(networkId: 1, target: "#lurker", kind: .channel, hydrated: true),
            messages: [msg(700, "while away")],
            hydrated: true, append: true
        ))
        XCTAssertEqual(
            store.state.messages[chanKey]!.map(\.text), ["anchor"],
            "the gap must not append onto the jump slice — 600 was never delivered, so it'd be a hole"
        )
        XCTAssertTrue(
            store.state.buffers[chanKey]!.hasMoreNewer,
            "and the buffer stays detached: the jump-to-latest pill is the only way back to live"
        )
        // Which still works, and is where the missing rows come from.
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(600, "missed"), msg(700, "while away")],
            mode: .latest, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["missed", "while away"])
        XCTAssertFalse(store.state.buffers[chanKey]!.hasMoreNewer)
    }

    /// The bug Brad hit: no reconnect, just a jump and a walk back to the present.
    ///
    /// Re-entering a detached buffer lands at the bottom of its slice, which fires `loadNewer`,
    /// which appends and lands at the bottom again — the reader walks forward to live one
    /// `after` page per round trip. Traffic that arrives during the LAST of those round trips
    /// is the hole: the buffer is still detached so the log won't take it, and the reply that
    /// re-attaches was built by the server before it was said.
    func testTrafficDuringTheReattachRoundTripSurvivesRatherThanVanishing() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(500, "recent")]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "anchor")],
            mode: .around, hasMoreOlder: true, hasMoreNewer: true
        ))
        // Walking forward. This page still reports more ahead, so we stay detached.
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(11, "b"), msg(12, "c")],
            mode: .after, hasMoreOlder: true, hasMoreNewer: true
        ))
        // The final page is now in flight. The server has already read up to 13 — so 14 and 15,
        // said while it's on the wire, cannot be in it.
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(14, "said mid-flight")))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(15, "and again")))
        XCTAssertEqual(
            store.state.messages[chanKey]!.map(\.text), ["anchor", "b", "c"],
            "still held out of the log while detached"
        )
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(13, "d")],
            mode: .after, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertFalse(store.state.buffers[chanKey]!.hasMoreNewer, "reaching the tail re-attaches")
        XCTAssertEqual(
            store.state.messages[chanKey]!.map(\.text),
            ["anchor", "b", "c", "d", "said mid-flight", "and again"],
            "and the held events land behind the slice they couldn't have been in"
        )
        // Live resumes normally, with nothing left over to double up.
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(16, "live")))
        XCTAssertEqual(store.state.messages[chanKey]!.count, 6 + 1)
    }

    /// The same seam on the jump-to-latest pill, which fetches a slice rather than walking to
    /// it — and where the held events overlap what the fetch returns.
    func testReattachingViaLatestKeepsHeldTrafficAndDoesNotDoubleIt() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(10, "old")]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "old")],
            mode: .around, hasMoreOlder: false, hasMoreNewer: true
        ))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(500, "during")))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(501, "after the query")))
        // The latest slice the server built includes 500 (it existed when the query ran) but
        // not 501 (it didn't).
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(499, "x"), msg(500, "during")],
            mode: .latest, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertEqual(
            store.state.messages[chanKey]!.map(\.text), ["x", "during", "after the query"],
            "the overlap de-dupes by id; only the genuinely-missing tail is added"
        )
        XCTAssertNil(store.state.heldLive[chanKey], "and the hold is spent")
    }

    /// An ephemeral held during a detach has no id to place it by and no fetch that could ever
    /// return it — a `/ctcp` or `/e2e` status line is never persisted. It rides out the
    /// re-attach on the same terms it lives everywhere else: kept, and appended last.
    func testHeldEphemeralsSurviveReattachDespiteHavingNoId() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(10, "old")]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "old")],
            mode: .around, hasMoreOlder: false, hasMoreNewer: true
        ))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(0, "CTCP reply")))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(500, "latest")],
            mode: .latest, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["latest", "CTCP reply"])
    }

    /// A second jump abandons the first window, so what was held for it goes too — those
    /// events are older than anything the next re-attach will fetch.
    func testANewJumpStartsTheHoldOver() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(500, "recent")]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "anchor")],
            mode: .around, hasMoreOlder: true, hasMoreNewer: true
        ))
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(600, "held")))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(80, "second anchor")],
            mode: .around, hasMoreOlder: true, hasMoreNewer: true
        ))
        XCTAssertEqual(store.state.heldLive[chanKey], [])
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(700, "tail")],
            mode: .latest, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertEqual(
            store.state.messages[chanKey]!.map(\.text), ["tail"],
            "600 is the fetch's business now, not the hold's"
        )
    }

    /// The same frame must not blank buffer state it doesn't carry: the connect burst sends
    /// the snapshot (which has the topic) BEFORE the per-buffer backlogs (which don't).
    func testBacklogKeepsTheTopicItDoesntCarry() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        store.apply(.channelTopic(networkId: 1, target: "#lurker", topic: "the topic"))
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi"), msg(2, "there")]))
        XCTAssertEqual(store.state.buffers[chanKey]!.topic, "the topic")
    }

    func testLoadingLatestReattachesAndResumesLiveAppends() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(10, "old")]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "old")],
            mode: .around, hasMoreOlder: false, hasMoreNewer: true
        ))
        XCTAssertTrue(store.state.buffers[chanKey]!.hasMoreNewer)
        // Return to live: the latest slice re-attaches (clears the detached flag).
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(500, "latest")],
            mode: .latest, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertFalse(store.state.buffers[chanKey]!.hasMoreNewer, "latest re-attaches to the tail")
        // Live appends resume now that we're attached.
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(501, "live")))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["latest", "live"])
    }

    func testAfterPagingAppendsNewerThenReattachesAtTheTail() {
        let store = LurkerStore()
        // Jump lands a detached slice below the tail (#42).
        store.apply(channelBuffer(hydrated: true, messages: [msg(500, "recent")]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(10, "anchor"), msg(11, "b")],
            mode: .around, hasMoreOlder: false, hasMoreNewer: true
        ))
        XCTAssertTrue(store.state.buffers[chanKey]!.hasMoreNewer, "detached after the around jump")
        // Read forward: an `after` page appends newer and, with more still ahead, stays detached.
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(11, "b"), msg(12, "c"), msg(13, "d")],
            mode: .after, hasMoreOlder: true, hasMoreNewer: true
        ))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["anchor", "b", "c", "d"], "appends, dedupes the overlap")
        XCTAssertTrue(store.state.buffers[chanKey]!.hasMoreNewer, "still detached while newer remains")
        // The final page reaches the tail → re-attach, and live appends resume.
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(14, "e")],
            mode: .after, hasMoreOlder: true, hasMoreNewer: false
        ))
        XCTAssertFalse(store.state.buffers[chanKey]!.hasMoreNewer, "reaching the tail re-attaches")
        store.apply(.live(networkId: 1, target: "#lurker", message: msg(15, "live")))
        XCTAssertEqual(store.state.messages[chanKey]!.map(\.text), ["anchor", "b", "c", "d", "e", "live"])
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

    /// ⚠⚠ The trap that made the first version of the unread-divider fix inert. `hydrateIfNeeded`
    /// asks for `history mode:latest`, and that reply hydrates the buffer while carrying no read
    /// fields at all (`parseHistory` reads none). So anything that treats `hydrated` as "the
    /// server has stated the read boundary" opens its gate on a `lastReadId` that is still this
    /// struct's default 0 — and a screen that then marks the buffer read destroys the real
    /// pointer before the `backlog` frame carrying it ever lands.
    func testHistoryHydratesWithoutClaimingToKnowTheReadState() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: false, messages: []))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(5, "e")],
            mode: .latest, hasMoreOlder: false, hasMoreNewer: false
        ))

        let buffer = store.state.buffers[chanKey]!
        XCTAssertTrue(buffer.hydrated, "a history reply is what hydrates a buffer")
        XCTAssertFalse(buffer.readStateKnown, "…but it carries no pointer, so it states nothing")
        XCTAssertEqual(buffer.lastReadId, 0, "still the default — not a boundary anyone gave us")
    }

    /// The other half: `read-state` carries the pointer by definition, so it may say so.
    func testReadStateMarksTheBoundaryKnown() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: false, messages: []))
        XCTAssertFalse(store.state.buffers[chanKey]!.readStateKnown, "a pointer-less shell states nothing")

        store.apply(.readState(networkId: 1, target: "#lurker", lastReadId: 10, unread: 4, highlights: 2))
        XCTAssertTrue(store.state.buffers[chanKey]!.readStateKnown)
    }

    /// A reconnect resyncs buffers as shells. One that carries no pointer hasn't retracted the
    /// one we already have — and must not overwrite its value with the field's default either,
    /// which would silently move a reader's divider to the top of the buffer.
    func testAPointerlessResyncNeitherRetractsNorZeroesAKnownReadState() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "a")]))
        store.apply(.readState(networkId: 1, target: "#lurker", lastReadId: 10, unread: 4, highlights: 2))
        store.apply(channelBuffer(hydrated: false, messages: []))

        let buffer = store.state.buffers[chanKey]!
        XCTAssertTrue(buffer.readStateKnown)
        XCTAssertEqual(buffer.lastReadId, 10)
        XCTAssertEqual(buffer.unread, 4)
        XCTAssertEqual(buffer.highlights, 2)
    }

    func testReadStateMirrorsCountsOntoTheBuffer() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "a")]))
        store.apply(.readState(networkId: 1, target: "#lurker", lastReadId: 10, unread: 4, highlights: 2))

        let buffer = store.state.buffers[chanKey]!
        XCTAssertEqual(buffer.lastReadId, 10)
        XCTAssertEqual(buffer.unread, 4)
        XCTAssertEqual(buffer.highlights, 2)
    }

    /// The app answering the user in place (the web's `localInfo`) — used by the system
    /// buffer's composer until commands land (#10). Ephemeral by construction: id 0, so a
    /// backlog replace drops it like any other unpersisted line.
    func testAppendLocalAddsAnEphemeralSystemLine() {
        let store = LurkerStore()
        // The production scenario: answering the system buffer's composer, which may not
        // even have a messages entry yet — appendLocal must create one.
        store.appendLocal(Buffer.system.key, text: "not yet")

        let appended = store.state.messages[Buffer.system.key.id]!.last!
        XCTAssertEqual(appended.id, 0, "local lines never claim a persisted id")
        XCTAssertEqual(appended.type, .system)
        XCTAssertEqual(appended.text, "not yet")
    }

    func testRemoveBufferDropsItAndItsMessages() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "a")]))
        XCTAssertNotNil(store.state.buffers[chanKey])

        store.removeBuffer(BufferKey(networkId: 1, target: "#lurker"))

        XCTAssertNil(store.state.buffers[chanKey])
        XCTAssertNil(store.state.messages[chanKey])
    }

    func testReadStateForAnUnknownBufferIsANoOp() {
        let store = LurkerStore()
        store.apply(.readState(networkId: 1, target: "#nope", lastReadId: 5, unread: 1, highlights: 0))
        XCTAssertNil(store.state.buffers["1::#nope"])
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
        ], globalIgnores: []))

        let state = store.state
        XCTAssertEqual(state.networks[1]!.state, .connected)
        XCTAssertEqual(state.networks[1]!.nick, "me")
        XCTAssertTrue(state.buffers[chanKey]!.joined)
        XCTAssertEqual(state.buffers[chanKey]!.kind, .channel)
        XCTAssertEqual(state.buffers[chanKey]!.topic, "welcome")
        XCTAssertEqual(state.members[chanKey]!.map(\.nick), ["alice", "bob"])
    }

    // MARK: - Members (#30)
    //
    // The snapshot seeds the list (above); live join/part/quit/kick/nick churn folds into
    // it, `names` replaces it wholesale, and `member-update` patches one entry. Before
    // this the list was accurate as of the last connect and rotted from there.

    private func seedMembers(_ store: LurkerStore, _ members: [Member]) {
        store.apply(.snapshot([
            NetworkSnapshot(
                id: 1, state: .connected, nick: "me",
                channels: [ChannelSnapshot(name: "#lurker", topic: nil, members: members)]
            ),
        ], globalIgnores: []))
    }

    func testAJoinAddsAMemberAndAPartRemovesThem() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "alice")])
        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 10, type: .join, nick: "bob", text: nil)))
        XCTAssertEqual(store.state.members[chanKey]!.map(\.nick), ["alice", "bob"])

        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 11, type: .part, nick: "alice", text: nil)))
        XCTAssertEqual(store.state.members[chanKey]!.map(\.nick), ["bob"])
    }

    /// The one the id de-dupe exists for: a backlog/live overlap replaying an old join
    /// must not resurrect a member who has since left — so the membership fold sits
    /// below the de-dupe, exactly like the topic mutation.
    func testAReplayedJoinDoesNotResurrectAPartedMember() {
        let store = LurkerStore()
        seedMembers(store, [])
        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 10, type: .join, nick: "bob", text: nil)))
        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 11, type: .quit, nick: "bob", text: nil)))

        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 10, type: .join, nick: "bob", text: nil)))

        XCTAssertEqual(store.state.members[chanKey], [], "a replay must not re-add bob")
    }

    func testMembershipMatchesNicksCaseInsensitively() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "Alice"), Member(nick: "bob")])
        // The server echoes the part with different casing than NAMES gave us.
        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 10, type: .part, nick: "ALICE", text: nil)))

        XCTAssertEqual(store.state.members[chanKey]!.map(\.nick), ["bob"])
    }

    func testAJoinForANickAlreadyListedKeepsTheExistingEntry() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "alice", modes: ["o"])])
        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 10, type: .join, nick: "ALICE", text: nil)))

        let members = store.state.members[chanKey]!
        XCTAssertEqual(members.count, 1, "must not duplicate")
        XCTAssertEqual(members[0].modes, ["o"], "and must not wipe what we know")
    }

    func testAKickRemovesTheKickedNotTheKicker() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "alice"), Member(nick: "bob")])
        // alice kicks bob: `nick` is the actor, `kicked` is who left.
        store.apply(.live(
            networkId: 1, target: "#lurker",
            message: Message(id: 10, type: .kick, nick: "alice", text: nil, kicked: "bob")
        ))

        XCTAssertEqual(store.state.members[chanKey]!.map(\.nick), ["alice"])
    }

    func testANickEventRenamesInPlacePreservingModesAndAway() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "alice", modes: ["o"], away: true, user: "al", host: "example.org")])
        store.apply(.live(
            networkId: 1, target: "#lurker",
            message: Message(id: 10, type: .nick, nick: "alice", text: nil, newNick: "alicia")
        ))

        let member = store.state.members[chanKey]![0]
        XCTAssertEqual(member.nick, "alicia")
        XCTAssertEqual(member.modes, ["o"])
        XCTAssertTrue(member.away)
        XCTAssertEqual(member.host, "example.org")
    }

    /// Our own join precedes the `names` broadcast, so a join must be able to seed a
    /// list from nothing — the roster lands a moment later and replaces it.
    func testAJoinSeedsAListWhereNoneExistsYet() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: []))
        store.apply(.live(networkId: 1, target: "#lurker", message: Message(id: 10, type: .join, nick: "me", text: nil, isSelf: true)))

        XCTAssertEqual(store.state.members[chanKey]!.map(\.nick), ["me"])
    }

    /// A quit fans out to every shared buffer, including DMs — which have no member
    /// list. Removing from nothing must stay nothing, not conjure an empty list.
    func testAQuitAgainstABufferWithNoListStaysListless() {
        let store = LurkerStore()
        store.apply(.live(networkId: 1, target: "bob", message: msg(7, "hey")))
        store.apply(.live(networkId: 1, target: "bob", message: Message(id: 8, type: .quit, nick: "bob", text: nil)))

        XCTAssertNil(store.state.members["1::bob"])
    }

    func testANamesBroadcastReplacesTheListWholesale() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "alice"), Member(nick: "bob")])
        // A prefix-mode change re-broadcasts the whole roster: alice is now opped, bob gone.
        store.apply(.channelMembers(
            networkId: 1, target: "#lurker",
            members: [Member(nick: "alice", modes: ["o"]), Member(nick: "carol")]
        ))

        XCTAssertEqual(store.state.members[chanKey]!.map(\.nick), ["alice", "carol"])
        XCTAssertEqual(store.state.members[chanKey]![0].modes, ["o"])
        XCTAssertEqual(store.state.messages[chanKey] ?? [], [], "names is silent — it prints nothing")
    }

    func testAMemberUpdatePatchesTheMatchingMemberInPlace() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "alice"), Member(nick: "Bob", modes: ["v"])])
        // A chghost snapshot for bob — matched case-insensitively, replaced wholesale.
        store.apply(.memberUpdate(
            networkId: 1, target: "#lurker",
            member: Member(nick: "Bob", modes: ["v"], away: true, user: "rob", host: "new.example.org")
        ))

        let members = store.state.members[chanKey]!
        XCTAssertEqual(members.map(\.nick), ["alice", "Bob"], "patched in place, not re-appended")
        XCTAssertTrue(members[1].away)
        XCTAssertEqual(members[1].host, "new.example.org")
    }

    func testAMemberUpdateForAnUnknownMemberOrBufferCreatesNothing() {
        let store = LurkerStore()
        seedMembers(store, [Member(nick: "alice")])
        store.apply(.memberUpdate(networkId: 1, target: "#lurker", member: Member(nick: "nobody")))
        store.apply(.memberUpdate(networkId: 1, target: "#nowhere", member: Member(nick: "alice")))

        XCTAssertEqual(store.state.members[chanKey]!.map(\.nick), ["alice"], "resolve, never create")
        XCTAssertNil(store.state.buffers["1::#nowhere"], "no row should be conjured for a patch alone")
    }

    // MARK: - Topic
    //
    // The server has three ways of saying what a channel's topic is, and the client needs
    // all three: the snapshot (above), a `channel-topic` ephemeral on join, and a `topic`
    // event when someone changes it. Miss one and the topic is right until it isn't.

    private func topicEvent(_ id: Int, _ topic: String) -> Message {
        Message(id: id, type: .topic, nick: "alice", text: topic)
    }

    func testAChannelTopicEventSetsTheTopicWithoutAddingALine() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: []))
        store.apply(.channelTopic(networkId: 1, target: "#lurker", topic: "on join"))

        XCTAssertEqual(store.state.buffers[chanKey]!.topic, "on join")
        XCTAssertEqual(store.state.messages[chanKey], [], "RPL_TOPIC is silent — it prints nothing")
    }

    func testAChannelTopicForAnUnknownBufferIsANoOp() {
        let store = LurkerStore()
        store.apply(.channelTopic(networkId: 1, target: "#nowhere", topic: "x"))

        XCTAssertNil(store.state.buffers["1::#nowhere"], "no row should be conjured for a topic alone")
    }

    func testAChannelTopicFoldsTargetCaseLikeEveryOtherTarget() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: []))
        store.apply(.channelTopic(networkId: 1, target: "#LURKER", topic: "cased"))

        XCTAssertEqual(store.state.buffers[chanKey]!.topic, "cased")
    }

    func testALiveTopicEventBothPrintsALineAndUpdatesTheTopic() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: []))
        store.apply(.live(networkId: 1, target: "#lurker", message: topicEvent(5, "changed")))

        XCTAssertEqual(store.state.buffers[chanKey]!.topic, "changed")
        XCTAssertEqual(store.state.messages[chanKey]?.count, 1, "a topic change is also a line")
    }

    /// The one that bites. A `topic` event replayed by a backlog/live overlap must not
    /// re-apply its stale topic over the current one — so the topic mutation has to sit
    /// below the id de-dupe, not beside the parse. The Vue client documents the same trap.
    func testAReplayedTopicEventDoesNotRevertTheTopic() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: []))
        store.apply(.live(networkId: 1, target: "#lurker", message: topicEvent(5, "old")))
        store.apply(.live(networkId: 1, target: "#lurker", message: topicEvent(6, "new")))

        // id 5 arrives a second time (the overlap), carrying the topic it had back then.
        store.apply(.live(networkId: 1, target: "#lurker", message: topicEvent(5, "old")))

        XCTAssertEqual(store.state.buffers[chanKey]!.topic, "new", "a replay must not revert the topic")
        XCTAssertEqual(store.state.messages[chanKey]?.count, 2, "and must not re-print the line")
    }

    func testAClearedTopicReadsAsNoTopicRatherThanTheLastOne() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: []))
        store.apply(.channelTopic(networkId: 1, target: "#lurker", topic: "something"))
        store.apply(.channelTopic(networkId: 1, target: "#lurker", topic: nil))

        XCTAssertNil(store.state.buffers[chanKey]!.topic)
    }

    func testRestNamesMergeOntoSnapshotCreatedNetworksWithoutDroppingLiveState() {
        let store = LurkerStore()
        // Snapshot arrives first (name unknown), then the REST roster supplies it.
        store.apply(.snapshot([NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])], globalIgnores: []))
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

    func testBufferForKeyReturnsTheStoredRowWhenThereIsOne() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))

        let found = store.state.buffer(for: BufferKey(networkId: 1, target: "#LURKER"))
        XCTAssertTrue(found.hydrated, "the real row, not a fresh synthetic one")
    }

    /// The divergence that motivated pulling this out of its four call sites: `!foo` carries
    /// a channel sigil for *input* (`ChannelName.sigils`, which the join form prefixes with)
    /// but is not one of the two sigils a buffer is classified by. A site that hardcoded
    /// `.channel` gave its screen a member list the store row would never agree with.
    func testBufferForKeySynthesizesWithTheSameKindClassificationTheStoreUses() {
        let state = ChatState()
        XCTAssertEqual(state.buffer(for: BufferKey(networkId: 1, target: "#lurker")).kind, .channel)
        XCTAssertEqual(state.buffer(for: BufferKey(networkId: 1, target: "&local")).kind, .channel)
        XCTAssertEqual(state.buffer(for: BufferKey(networkId: 1, target: "!foo")).kind, .dm)
        XCTAssertEqual(state.buffer(for: BufferKey(networkId: 1, target: "bob")).kind, .dm)
        XCTAssertEqual(state.buffer(for: BufferKey(networkId: nil, target: Buffer.systemTarget)).kind, .system)
    }

    /// A synthesized buffer must be unhydrated, or the screen built from it would skip
    /// asking for history and sit empty forever.
    func testASynthesizedBufferIsUnhydratedSoItsScreenStillFetches() {
        let buffer = ChatState().buffer(for: BufferKey(networkId: 1, target: "#lurker"))
        XCTAssertFalse(buffer.hydrated)
        XCTAssertEqual(buffer.target, "#lurker", "case is preserved, unlike BufferKey.id")
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

    // MARK: - Reachability

    func testReachabilityDefaultsToTrue() {
        // Assuming offline until told otherwise would paint every fresh launch red.
        XCTAssertTrue(LurkerStore().state.reachable)
    }

    func testReachabilitySurvivesReset() {
        // It's a fact about the device, not the session, and nothing re-reports it on
        // sign-out — so a reset back to the `true` default would leave an offline phone
        // claiming it's online, with no path monitor callback coming to correct it.
        let store = LurkerStore()
        store.setReachable(false)
        store.reset()
        XCTAssertFalse(store.state.reachable)
    }

    func testResetStillClearsEverythingSessionScoped() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        store.setReachable(false)
        store.reset()
        XCTAssertTrue(store.state.buffers.isEmpty)
        XCTAssertTrue(store.state.messages.isEmpty)
        XCTAssertEqual(store.state.maxEventId, 0)
    }

    func testBufferClosedDropsTheBufferAndEverythingKeyedToIt() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        store.apply(.channelMembers(networkId: 1, target: "#lurker", members: [Member(nick: "alice")]))
        XCTAssertNotNil(store.state.buffers[chanKey])

        store.apply(.bufferClosed(networkId: 1, target: "#lurker"))

        // Closed is absent, not flagged: the server keeps the history, so a reopen restores
        // it in full and there's nothing local worth holding on to.
        XCTAssertNil(store.state.buffers[chanKey], "the row is gone")
        XCTAssertNil(store.state.messages[chanKey], "and so are its messages")
        XCTAssertNil(store.state.members[chanKey], "a reopen must not inherit a stale nicklist")
    }

    func testBufferClosedFoldsCaseLikeEveryOtherTargetLookup() {
        // The server echoes whatever casing it holds, which needn't match what we stored.
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))

        store.apply(.bufferClosed(networkId: 1, target: "#LURKER"))

        XCTAssertNil(store.state.buffers[chanKey], "differently-cased close still lands")
    }

    func testBufferClosedLeavesOtherBuffersAlone() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        store.apply(
            .backlog(
                buffer: Buffer(networkId: 1, target: "#other", kind: .channel, hydrated: true),
                messages: [msg(2, "elsewhere")],
                hydrated: true,
                append: false
            )
        )

        store.apply(.bufferClosed(networkId: 1, target: "#lurker"))

        XCTAssertNil(store.state.buffers[chanKey])
        XCTAssertNotNil(store.state.buffers["1::#other"], "an unrelated buffer survives")
        XCTAssertEqual(store.state.messages["1::#other"]?.map(\.text), ["elsewhere"])
    }

    func testBacklogCompletePrunesABufferTheBurstNoLongerLists() {
        // The offline half of buffer-closed, and the common one on a phone: the close
        // happened while this device wasn't connected, so no `buffer-closed` ever arrived.
        // The burst enumerates only OPEN buffers, so the omission is the signal.
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        XCTAssertNotNil(store.state.buffers[chanKey])

        // A fresh burst that doesn't mention #lurker.
        store.apply(.snapshot([], globalIgnores: []))
        store.apply(
            .backlog(
                buffer: Buffer(networkId: 1, target: "#other", kind: .channel, hydrated: true),
                messages: [], hydrated: true, append: false
            )
        )
        store.apply(.backlogComplete)

        XCTAssertNil(store.state.buffers[chanKey], "unlisted buffer is no longer open")
        XCTAssertNil(store.state.messages[chanKey])
        XCTAssertNotNil(store.state.buffers["1::#other"], "the listed one survives")
    }

    func testBacklogCompleteKeepsEverythingTheBurstDidList() {
        let store = LurkerStore()
        store.apply(.snapshot([], globalIgnores: []))
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        store.apply(.backlogComplete)

        XCTAssertNotNil(store.state.buffers[chanKey])
        XCTAssertEqual(store.state.messages[chanKey]?.map(\.text), ["hi"])
    }

    func testBacklogCompleteWithNoBurstBehindItPrunesNothing() {
        // A stray terminal frame must not read as "the server listed nothing" and wipe the
        // roster — only a burst that actually started (a `snapshot` frame) opens the window.
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [msg(1, "hi")]))
        store.apply(.backlogComplete)

        XCTAssertNotNil(store.state.buffers[chanKey], "no snapshot, no prune")
    }

    func testADmMaterializedMidBurstSurvivesTheClosingPrune() {
        // The row was created after the server enumerated the roster, so the burst can't
        // name it. Pruning it would drop a DM the moment it arrived.
        let store = LurkerStore()
        store.apply(.snapshot([], globalIgnores: []))
        store.apply(
            .live(networkId: 1, target: "bob", message: msg(7, "hey"))
        )
        store.apply(.backlogComplete)

        XCTAssertNotNil(store.state.buffers["1::bob"], "a DM that landed mid-burst stays")
        XCTAssertEqual(store.state.messages["1::bob"]?.map(\.text), ["hey"])
    }

    func testRosterSettledOnlyOnceABurstHasFinishedAndNoneIsInFlight() {
        // What a by-key screen (launch restore, notification tap) needs before it can read
        // absence as "this buffer isn't open" instead of "its frame hasn't arrived".
        let store = LurkerStore()
        XCTAssertFalse(store.state.rosterSettled, "nothing has arrived yet")

        store.apply(.snapshot([], globalIgnores: []))
        XCTAssertFalse(store.state.rosterSettled, "burst in flight")

        store.apply(.backlogComplete)
        XCTAssertTrue(store.state.rosterSettled, "the server listed everything it has")

        // A later burst reopens the window: `backlogComplete` latches for the session, so
        // it alone would keep claiming proof while `buffers` is mid-rebuild.
        store.apply(.snapshot([], globalIgnores: []))
        XCTAssertTrue(store.state.backlogComplete, "still latched...")
        XCTAssertFalse(store.state.rosterSettled, "...but the roster is being rebuilt")
    }

    func testBurstGenerationAdvancesOncePerSnapshot() {
        // What a one-shot request keys off instead of `connection`. A socket can die and be
        // replaced without `connection` ever leaving `.connected` (a close arriving after
        // the replacement is dropped so it can't clobber the live socket), which loses any
        // request written to the dying socket with no observable state change. A burst is
        // unmissable — every reconnect produces one.
        let store = LurkerStore()
        XCTAssertEqual(store.state.burstGeneration, 0)

        store.apply(.snapshot([], globalIgnores: []))
        XCTAssertEqual(store.state.burstGeneration, 1)
        store.apply(.backlogComplete)
        XCTAssertEqual(store.state.burstGeneration, 1, "only a snapshot advances it")

        // A reconnect's burst — the moment anything asked over the old socket is void.
        store.apply(.snapshot([], globalIgnores: []))
        XCTAssertEqual(store.state.burstGeneration, 2)
    }

    func testReachabilityIsIndependentOfTheSocket() {
        // Two different truths: the socket only ever reports connecting/connected/
        // reconnecting, so it can never say "there is no internet".
        let store = LurkerStore()
        store.apply(.socketOpen)
        store.setReachable(false)
        XCTAssertEqual(store.state.connection, .connected, "the socket doesn't know yet")
        XCTAssertFalse(store.state.reachable)
        XCTAssertEqual(
            StatusLight.of(reachable: store.state.reachable, connection: store.state.connection, network: nil),
            .bad,
            "and the light believes the device over the stale socket"
        )
    }

    // MARK: - Bookmarks

    /// The set is seeded from the message rows themselves, because there is no bookmark
    /// snapshot in the connect burst — the server used to send every saved id on every
    /// connect, which is the one piece of connect state that grows without bound.
    func testBookmarkedFlagOnBacklogRowsSeedsTheSet() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [
            msg(1, "plain"),
            saved(msg(2, "kept")),
        ]))
        XCTAssertTrue(store.state.isBookmarked(2))
        XCTAssertFalse(store.state.isBookmarked(1))
    }

    /// A later page knows only its own slice, so its silence about an id must not evict what
    /// an earlier one established — otherwise scrolling up would quietly unlight every
    /// bookmark above the fold.
    func testALaterPageDoesNotEvictBookmarksItDoesNotMention() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [saved(msg(2, "kept"))]))
        store.apply(.history(
            networkId: 1, target: "#lurker", events: [msg(1, "older")],
            mode: .before, hasMoreOlder: false, hasMoreNewer: false
        ))
        XCTAssertTrue(store.state.isBookmarked(2), "the older page said nothing about id 2")
    }

    /// A row that comes back UNFLAGGED is authoritative for itself — the server omits the
    /// field when false. This is the only way an unsave made elsewhere while this client was
    /// offline ever lands: the echo was missed, and the reconnect backlog carries the truth.
    func testAnUnflaggedRowClearsItsOwnBookmark() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [saved(msg(2, "kept"))]))
        XCTAssertTrue(store.state.isBookmarked(2))
        // The same line comes back on reconnect, no longer saved.
        store.apply(channelBuffer(hydrated: true, messages: [msg(2, "kept")]))
        XCTAssertFalse(store.state.isBookmarked(2))
    }

    /// System-buffer rows have their own id sequence, overlapping the message ids this set is
    /// keyed by, and never carry the flag — so reconciling against them would clear a real
    /// bookmark that happens to share an id.
    func testSystemBufferPagesCannotClearBookmarks() {
        let store = LurkerStore()
        store.apply(channelBuffer(hydrated: true, messages: [saved(msg(2, "kept"))]))
        store.apply(.backlog(
            buffer: Buffer(networkId: nil, target: ":system:", kind: .system, hydrated: true),
            messages: [msg(2, "an unrelated system line that happens to be id 2")],
            hydrated: true,
            append: false
        ))
        XCTAssertTrue(store.state.isBookmarked(2))
    }

    /// The saved-messages feed carries no per-row flag — every row in it is saved — so it
    /// folds in additively, and in one mutation rather than one per row.
    func testNoteBookmarkedIdsSeedsTheSet() {
        let store = LurkerStore()
        store.noteBookmarked(ids: [4, 5])
        XCTAssertTrue(store.state.isBookmarked(4))
        XCTAssertTrue(store.state.isBookmarked(5))
    }

    /// The echo is the source of truth for a toggle — it's fanned to every socket including
    /// the one that asked, so nothing renders optimistically.
    func testBookmarkUpdatedAddsAndRemoves() {
        let store = LurkerStore()
        store.apply(.bookmarkUpdated(messageId: 7, saved: true))
        XCTAssertTrue(store.state.isBookmarked(7))
        store.apply(.bookmarkUpdated(messageId: 7, saved: false))
        XCTAssertFalse(store.state.isBookmarked(7))
    }

    /// Removing an id the set never held is normal, not a lost update: without a connect
    /// snapshot the set only knows the lines this session has loaded, so an unsave made on
    /// another device for an unloaded buffer arrives as exactly this.
    func testRemovingAnUnknownBookmarkIsHarmless() {
        let store = LurkerStore()
        store.apply(.bookmarkUpdated(messageId: 999, saved: false))
        XCTAssertFalse(store.state.isBookmarked(999))
        XCTAssertTrue(store.state.bookmarkedIds.isEmpty)
    }

    private func saved(_ message: Message) -> Message {
        Message(
            id: message.id, type: message.type, nick: message.nick, text: message.text,
            isSelf: message.isSelf, bookmarked: true
        )
    }
}

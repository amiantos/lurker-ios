// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The `+typing` path, end to end: the parser reads the real wire frame, the store folds it,
/// and `typists(in:now:)` applies the lease.
///
/// The multi-typist and expiry cases are the whole reason this is a value-typed, read-time
/// lease rather than the web's timer-driven map — every one of them is exercised here at an
/// exact instant, with no sleeping and nothing to go flaky. `reduce` takes `now`, so "six
/// seconds later" is a parameter, not a wait.
@MainActor
final class TypingTests: XCTestCase {

    private let key = BufferKey(networkId: 1, target: "#chan")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A state holding one open channel — typing is only ever stored against a buffer that
    /// already exists, so every case needs one.
    private func stateWithChannel(_ target: String = "#chan") -> ChatState {
        var state = ChatState()
        let key = BufferKey(networkId: 1, target: target)
        state.buffers[key.id] = Buffer(networkId: 1, target: target, kind: .channel)
        return state
    }

    private func typing(
        _ nick: String,
        _ activity: String,
        target: String = "#chan",
        userhost: String? = nil
    ) -> ServerFrame {
        .typing(
            networkId: 1, target: target, nick: nick,
            activity: TypingActivity.from(activity), userhost: userhost
        )
    }

    // MARK: - Parser

    func testTypingFrameParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","type":"typing","networkId":1,"target":"#chan","nick":"alice","state":"active","userhost":"alice!u@h"}"##
        )
        guard case let .typing(networkId, target, nick, activity, userhost) = frame else {
            return XCTFail("expected typing, got \(frame)")
        }
        XCTAssertEqual(networkId, 1)
        XCTAssertEqual(target, "#chan")
        XCTAssertEqual(nick, "alice")
        XCTAssertEqual(activity, .active)
        XCTAssertEqual(userhost, "alice!u@h")
    }

    /// `done` is the absence of typing, not a kind of it — so it parses to nil activity and
    /// the store reads that as "remove them".
    func testDoneAndUnknownStatesParseToNoActivity() {
        for raw in ["done", "wat", ""] {
            let frame = FrameParser.parseWs(
                ##"{"kind":"irc","type":"typing","networkId":1,"target":"#chan","nick":"alice","state":"\##(raw)"}"##
            )
            guard case let .typing(_, _, _, activity, _) = frame else {
                return XCTFail("expected typing for state \(raw), got \(frame)")
            }
            XCTAssertNil(activity, "state \(raw) should carry no activity")
        }
    }

    /// A typing frame with nobody to attribute it to would key an entry on the empty string.
    func testTypingWithoutNickIsIgnored() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","type":"typing","networkId":1,"target":"#chan","nick":"","state":"active"}"##
        )
        XCTAssertEqual(frame, .ignored)
    }

    /// A typing frame must not be mistaken for a renderable event — it carries no id and its
    /// payload is in `state`, so falling through to `parseEvent` would append a junk line.
    func testTypingIsNotParsedAsALiveMessage() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","type":"typing","networkId":1,"target":"#chan","nick":"alice","state":"active"}"##
        )
        if case .live = frame { XCTFail("typing must not parse as a live message") }
    }

    // MARK: - Store: the basics

    func testActiveTypingSurfacesTheTypist() {
        let state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0), ["alice"])
    }

    func testDoneRemovesTheTypist() {
        var state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("alice", "done"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0), [])
        // …and leaves no empty shell behind.
        XCTAssertNil(state.typing[key.id])
    }

    /// The bug the web had to go back and fix: an unrecognized state used to be ignored, which
    /// stranded the prior entry with no timer left to clear it. Here it must delete.
    func testUnrecognizedStateClearsRatherThanStranding() {
        var state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("alice", "sideways"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0), [])
    }

    /// Case-variant tags from one peer are one typist, not two, and the display keeps the
    /// casing the server most recently sent.
    func testCaseVariantTagsCollapseToOneEntry() {
        var state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("ALICE", "active"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0), ["ALICE"])
    }

    /// `BufferKey.id` folds the target, so a server that cases the channel differently from
    /// how we joined it still lands on our buffer (web #289).
    func testTargetCaseFoldsOntoTheOpenBuffer() {
        let state = LurkerStore.reduce(
            stateWithChannel("#chan"), typing("alice", "active", target: "#CHAN"), now: t0
        )
        XCTAssertEqual(state.typists(in: key, now: t0), ["alice"])
    }

    // MARK: - Store: resolve, never materialize (#292)

    func testTypingForAnUnknownBufferIsDropped() {
        let state = LurkerStore.reduce(ChatState(), typing("stranger", "active", target: "stranger"), now: t0)
        XCTAssertTrue(state.buffers.isEmpty, "a typing tag must never materialize a buffer")
        XCTAssertTrue(state.typing.isEmpty)
    }

    // MARK: - Store: the lease

    func testActiveEntryExpiresAfterItsLease() {
        let state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(5.9)), ["alice"])
        // Exclusive of the boundary: a lease that runs out exactly on the tick is over.
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(6)), [])
    }

    /// `paused` means "stopped, but the draft is still there" and is sent once, so it has to
    /// outlive a long pause on its own — five times the `active` lease.
    func testPausedOutlivesActive() {
        let state = LurkerStore.reduce(stateWithChannel(), typing("alice", "paused"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(29)), ["alice"])
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(30)), [])
    }

    func testRefreshExtendsTheLease() {
        var state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        let t5 = t0.addingTimeInterval(5)
        state = LurkerStore.reduce(state, typing("alice", "active"), now: t5)
        // Would have lapsed on the original lease; the refresh carries it past that.
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(8)), ["alice"])
        XCTAssertEqual(state.typists(in: key, now: t5.addingTimeInterval(6)), [])
    }

    /// Expiry is evaluated at read time and never mutates the map, so asking at a later
    /// instant can't corrupt an earlier answer. This is what lets the view tick lazily.
    func testReadTimeExpiryDoesNotMutateState() {
        let state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(600)), [])
        XCTAssertEqual(state.typists(in: key, now: t0), ["alice"], "the earlier answer must still hold")
    }

    // MARK: - Store: several typists at once

    func testMultipleTypistsAreOrderedByWhenTheyStarted() {
        var state = stateWithChannel()
        state = LurkerStore.reduce(state, typing("carol", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("alice", "active"), now: t0.addingTimeInterval(1))
        state = LurkerStore.reduce(state, typing("bob", "active"), now: t0.addingTimeInterval(2))
        XCTAssertEqual(
            state.typists(in: key, now: t0.addingTimeInterval(3)),
            ["carol", "alice", "bob"],
            "longest-running first, not alphabetical and not dictionary order"
        )
    }

    /// The reason `startedAt` is carried across a refresh: without it, ordering on `expiresAt`
    /// would reshuffle the list every time somebody's `active` refreshed.
    func testRefreshDoesNotReorderTheList() {
        var state = stateWithChannel()
        state = LurkerStore.reduce(state, typing("carol", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("alice", "active"), now: t0.addingTimeInterval(1))
        // Carol keeps typing — she must stay first even though her lease now ends last.
        state = LurkerStore.reduce(state, typing("carol", "active"), now: t0.addingTimeInterval(2))
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(3)), ["carol", "alice"])
    }

    /// A peer whose lease lapsed and who then types again has started a *new* run, so they go
    /// to the back rather than reclaiming their original place.
    func testResumingAfterALapseStartsANewRun() {
        var state = stateWithChannel()
        state = LurkerStore.reduce(state, typing("carol", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("alice", "active"), now: t0.addingTimeInterval(1))
        // Carol lapses (t0+6), then comes back.
        let t10 = t0.addingTimeInterval(10)
        state = LurkerStore.reduce(state, typing("alice", "active"), now: t10)
        state = LurkerStore.reduce(state, typing("carol", "active"), now: t10.addingTimeInterval(1))
        XCTAssertEqual(state.typists(in: key, now: t10.addingTimeInterval(2)), ["alice", "carol"])
    }

    func testTypistsExpireIndependently() {
        var state = stateWithChannel()
        state = LurkerStore.reduce(state, typing("alice", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("bob", "paused"), now: t0)
        // Alice's short lease is out; Bob's long one is not.
        XCTAssertEqual(state.typists(in: key, now: t0.addingTimeInterval(7)), ["bob"])
    }

    func testOneTypistStoppingLeavesTheOthers() {
        var state = stateWithChannel()
        state = LurkerStore.reduce(state, typing("alice", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("bob", "active"), now: t0)
        state = LurkerStore.reduce(state, typing("alice", "done"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0), ["bob"])
    }

    // MARK: - Store: isolation between buffers

    func testTypingIsScopedToItsBuffer() {
        var state = stateWithChannel("#chan")
        let other = BufferKey(networkId: 1, target: "#other")
        state.buffers[other.id] = Buffer(networkId: 1, target: "#other", kind: .channel)
        state = LurkerStore.reduce(state, typing("alice", "active", target: "#chan"), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0), ["alice"])
        XCTAssertEqual(state.typists(in: other, now: t0), [])
    }

    func testTypistsForABufferWithNoEntriesIsEmpty() {
        XCTAssertEqual(ChatState().typists(in: key, now: t0), [])
    }

    // MARK: - Store: lifecycle

    /// A `paused` entry holds for 30s — long enough to survive a reconnect and show someone
    /// composing when we've heard nothing from them since before the drop.
    func testSocketCloseClearsTypists() {
        var state = LurkerStore.reduce(stateWithChannel(), typing("alice", "active"), now: t0)
        state = LurkerStore.reduce(state, .socketClosed(reason: nil, code: nil), now: t0)
        XCTAssertEqual(state.typists(in: key, now: t0), [])
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import XCTest
@testable import LurkerKit

// Shared by both suites below — one derivation of key and kind, so the two can't drift.
private func buffer(_ target: String, highlights: Int, unread: Int = 0) -> Buffer {
    Buffer(
        networkId: 1,
        target: target,
        kind: BufferKind.of(networkId: 1, target: target),
        unread: unread,
        highlights: highlights
    )
}

private func state(_ buffers: [Buffer]) -> ChatState {
    var s = ChatState()
    for b in buffers { s.buffers[b.key.id] = b }
    return s
}

/// The app-icon badge total (#490).
///
/// This exists because a push only ever REVISES the badge — iOS applies `aps.badge` and
/// then nothing touches it again — so without a client-side number, reading your messages
/// leaves the icon stuck on whatever the last notification claimed. The arithmetic is
/// therefore load-bearing for a user-visible thing that has no other feedback loop: a
/// wrong total looks exactly like a right one until you count.
@MainActor
final class AppBadgeTests: XCTestCase {

    func testEmptyStateBadgesNothing() {
        XCTAssertEqual(ChatState().totalHighlights, 0)
    }

    func testSumsHighlightsAcrossBuffers() {
        let s = state([
            buffer("#lurker", highlights: 2),
            buffer("bob", highlights: 1),
            buffer("#other", highlights: 3),
        ])
        XCTAssertEqual(s.totalHighlights, 6)
    }

    func testCountsHighlightsNotUnread() {
        // The badge is mentions, not traffic. A busy channel you're not named in must not
        // light up the icon — that's the whole distinction between unread and highlights,
        // and it's what makes the badge worth looking at.
        let s = state([buffer("#lurker", highlights: 0, unread: 400)])
        XCTAssertEqual(s.totalHighlights, 0)
    }

    func testGoesToZeroWhenEverythingIsRead() {
        // The case the bug this fixes gets wrong: push set the icon to 3, the user read
        // all three, and nothing ever told the icon.
        var s = state([buffer("#lurker", highlights: 2), buffer("bob", highlights: 1)])
        XCTAssertEqual(s.totalHighlights, 3)
        for key in s.buffers.keys { s.buffers[key]?.highlights = 0 }
        XCTAssertEqual(s.totalHighlights, 0)
    }

    func testCountsDMsAndChannelsAlike() {
        // A DM's every unread line counts as a highlight server-side, so DMs contribute
        // their full count — the badge should reflect that rather than treating them as a
        // separate kind of thing.
        XCTAssertEqual(state([buffer("bob", highlights: 5)]).totalHighlights, 5)
    }

    func testIncludesTheSystemBuffer() {
        // The system buffer's notable lines double as highlights server-side (its unread
        // IS its highlight count), so an admin/error line lights the icon too. Pinned
        // because it's easy to assume "highlights" means "someone said your nick".
        var s = ChatState()
        s.buffers[Buffer.system.key.id] = Buffer(
            networkId: nil, target: Buffer.systemTarget, kind: .system, unread: 2, highlights: 2
        )
        XCTAssertEqual(s.totalHighlights, 2)
    }
}

/// When the badge is WRITTEN (#134), as distinct from what the number is.
///
/// A push paints the icon behind the app's back, and it is right to while the app is
/// closed. Every write here therefore has to be one the app can vouch for: a count the
/// server has actually stated this session, written when it changes, when the roster is
/// re-stated in full, or on demand — and refused when it's a leftover. The states are
/// driven through the real reducer, because what "settled" and "the server has spoken"
/// mean is the reducer's business and this must break when that changes.
@MainActor
final class AppBadgeWriteTests: XCTestCase {

    private var writes: [Int] = []
    private var badge: AppBadge!
    private let states = CurrentValueSubject<ChatState, Never>(ChatState())

    override func setUp() {
        super.setUp()
        writes = []
        badge = AppBadge { [unowned self] in writes.append($0) }
        badge.follow(states.eraseToAnyPublisher())
    }

    private func apply(_ frame: ServerFrame) {
        states.send(LurkerStore.reduce(states.value, frame))
    }

    private let snapshot = ServerFrame.snapshot([], globalIgnores: [], maxUploadBytes: nil)

    /// The connect-burst frame that carries a buffer's server-side counts.
    private func backlog(_ target: String, highlights: Int, unread: Int = 0) -> ServerFrame {
        .backlog(
            buffer: buffer(target, highlights: highlights, unread: unread),
            messages: [], hydrated: true, append: false, speakers: nil
        )
    }

    func testNothingIsWrittenUntilTheServerHasSpoken() {
        // Cold launch: the replayed store is EMPTY, not zero. Pushes painted a true number
        // while the app was closed, and writing 0 over it would hide real highlights for as
        // long as the connect takes — forever, offline. The snapshot is the first frame
        // every server version sends; from there on the store's count is the store's.
        XCTAssertEqual(writes, [], "an empty store says nothing about the icon")
        badge.reassert(states.value)
        XCTAssertEqual(writes, [], "and can't be re-asserted into saying something")
        apply(snapshot)
        XCTAssertEqual(writes, [0])
    }

    func testTransitionsWriteAndEverythingElseDoesNot() {
        apply(snapshot)
        apply(backlog("#lurker", highlights: 2))
        XCTAssertEqual(writes, [0, 2])
        // Folds that leave the count alone — traffic you're not named in, a typing frame —
        // are not writes. The steady-state path is deduped on the COUNT, not on state
        // identity, so a busy channel doesn't turn into an OS call per line.
        apply(backlog("#other", highlights: 0, unread: 400))
        apply(
            .typing(
                networkId: 1, target: "#lurker", nick: "alice",
                activity: TypingActivity.from("active"), userhost: nil
            )
        )
        XCTAssertEqual(writes, [0, 2])
        apply(backlog("#lurker", highlights: 0))
        XCTAssertEqual(writes, [0, 2, 0])
    }

    func testBurstCompletionWritesAnUnchangedCountButBurstStartDoesNot() {
        apply(snapshot)
        apply(backlog("bob", highlights: 2))
        XCTAssertEqual(writes, [0, 2])
        // The terminator: the roster was just re-stated in full, so the count is as fresh
        // as it gets — written even though it didn't move. This is the write a stale
        // push-painted number gets corrected by on every reconnect.
        apply(.backlogComplete)
        XCTAssertEqual(writes, [0, 2, 2])

        // A reconnect. The snapshot frame unsettles the roster but re-states no counts —
        // the store still holds the pre-reconnect number — so it must NOT write: that
        // would paint a leftover over a push's true one. The buffers land, then the
        // terminator writes the now-confirmed count.
        apply(snapshot)
        XCTAssertEqual(writes, [0, 2, 2], "burst start is not a write")
        apply(backlog("bob", highlights: 2))
        XCTAssertEqual(writes, [0, 2, 2])
        apply(.backlogComplete)
        XCTAssertEqual(writes, [0, 2, 2, 2])
    }

    func testReassertWritesAnUnchangedCount() {
        // The #134 shape: everything read, 0 already written, then a stale push paints 3
        // on the icon. Nothing in state moves, so the transition path would swallow every
        // write forever; a re-assert is what gets 0 back onto the icon.
        apply(snapshot)
        apply(.socketOpen)
        apply(.backlogComplete)
        XCTAssertEqual(writes, [0, 0])
        badge.reassert(states.value)
        XCTAssertEqual(writes, [0, 0, 0])
    }

    func testReassertRefusesACountItCannotVouchFor() {
        apply(snapshot)
        apply(.socketOpen)
        apply(backlog("bob", highlights: 1))
        XCTAssertEqual(writes, [0, 1])

        // No network path: whatever pushes painted is newer than anything we hold.
        var offline = states.value
        offline.reachable = false
        badge.reassert(offline)
        XCTAssertEqual(writes, [0, 1], "unreachable: the count can't be current")

        // A socket known to be down: the reconnect's burst will re-state the count; a
        // write now would be the pre-drop leftover.
        apply(.socketClosed(reason: nil, code: nil))
        XCTAssertEqual(states.value.connection, .reconnecting)
        badge.reassert(states.value)
        XCTAssertEqual(writes, [0, 1], "reconnecting: the count is a leftover")
    }

    func testSignOutClearsTheIcon() {
        apply(snapshot)
        apply(backlog("bob", highlights: 3))
        XCTAssertEqual(writes, [0, 3])
        // `reset()` publishes a fresh state — the server-has-spoken marker gone with the
        // rest. That is a drop to nothing, and the icon was the old account's.
        states.send(ChatState())
        XCTAssertEqual(writes, [0, 3, 0])
        states.send(ChatState())
        XCTAssertEqual(writes, [0, 3, 0], "nothing-to-nothing is not a write")
    }
}

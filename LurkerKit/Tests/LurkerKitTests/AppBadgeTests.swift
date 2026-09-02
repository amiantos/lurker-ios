// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import XCTest
@testable import LurkerKit

/// The app-icon badge total (#490).
///
/// This exists because a push only ever REVISES the badge — iOS applies `aps.badge` and
/// then nothing touches it again — so without a client-side number, reading your messages
/// leaves the icon stuck on whatever the last notification claimed. The arithmetic is
/// therefore load-bearing for a user-visible thing that has no other feedback loop: a
/// wrong total looks exactly like a right one until you count.
@MainActor
final class AppBadgeTests: XCTestCase {

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
/// A push paints the icon behind the app's back, and publishing only the count's
/// transitions can't repair a paint the count disagrees with: the count didn't move.
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

    private func state(highlights: Int, settled: Bool = false) -> ChatState {
        var s = ChatState()
        s.buffers["1::bob"] = Buffer(networkId: 1, target: "bob", kind: .dm, highlights: highlights)
        s.backlogComplete = settled
        return s
    }

    func testWritesTheCurrentCountOnSubscribeThenOnlyTransitions() {
        // The replayed initial state is a write: a cold launch has to put SOMETHING on
        // the icon before the snapshot lands. After that, a fold that leaves the count
        // where it was (a message in a channel you're not named in, a typing frame) is
        // not a write — the steady-state path is deduped so a busy network doesn't turn
        // into an OS call per line.
        XCTAssertEqual(writes, [0])
        states.send(state(highlights: 3))
        states.send(state(highlights: 3))
        states.send(state(highlights: 0))
        XCTAssertEqual(writes, [0, 3, 0])
    }

    func testReassertWritesAnUnchangedCount() {
        // The #134 shape: everything read, count 0 already written, then a stale push
        // paints 3 on the icon. Nothing in state moves, so the dedupe would swallow every
        // write forever; a re-assert is the one that gets 0 back onto the icon.
        states.send(state(highlights: 0))
        XCTAssertEqual(writes, [0])
        badge.reassert(states.value)
        XCTAssertEqual(writes, [0, 0])
    }

    func testBurstCompletionWritesAnUnchangedCount() {
        // A reconnect's snapshot burst is the moment the count is known fresh, and every
        // reconnect produces one. Its terminal frame must write even when the count it
        // confirms is the one already on the icon — that's the whole point.
        states.send(state(highlights: 2))
        XCTAssertEqual(writes, [0, 2])
        states.send(state(highlights: 2, settled: true))
        XCTAssertEqual(writes.last, 2)
        XCTAssertEqual(writes.count, 3, "burst completion must write despite an unchanged count")

        // Second burst (a reconnect): the roster unsettles at the snapshot frame and
        // settles again at backlog-complete. Completion writes again.
        var reconnecting = state(highlights: 2, settled: true)
        reconnecting.burstActive = true
        states.send(reconnecting)
        let beforeCompletion = writes.count
        states.send(state(highlights: 2, settled: true))
        XCTAssertEqual(writes.last, 2)
        XCTAssertGreaterThan(writes.count, beforeCompletion)
    }

    func testSettledStateWithNoChangeIsNotAWrite() {
        // Steady state after a burst: folds that don't move the count still don't write.
        states.send(state(highlights: 1, settled: true))
        let n = writes.count
        states.send(state(highlights: 1, settled: true))
        XCTAssertEqual(writes.count, n)
    }
}

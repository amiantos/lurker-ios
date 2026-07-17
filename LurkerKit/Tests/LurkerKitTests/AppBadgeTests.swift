// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

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

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// What the message list shows when it has no messages: still-loading vs. genuinely-empty,
/// which a blank list can't tell apart.
final class BufferPlaceholderTests: XCTestCase {

    func testMessagesPresentMeansNoPlaceholder() {
        // Whatever else is true, if there are lines to show, show them.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: true, hydrated: false, hydratesOnDemand: true, bufferExists: false),
            .none
        )
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: true, hydrated: true, hydratesOnDemand: false, bufferExists: true),
            .none
        )
    }

    // MARK: - On-demand buffers (channels, DMs) — key off `hydrated`

    func testOnDemandBufferLoadsUntilHydrated() {
        // A channel/DM arrives as a shell (the row exists!) and isn't read until its
        // open-buffer reply lands — so row-existence can't tell them apart, only hydration.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: true, bufferExists: true),
            .loading
        )
    }

    func testOnDemandBufferHydratedButEmptyIsEmpty() {
        // The server read the history and there was none — a just-joined channel. Real, not
        // a failure.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: true, hydratesOnDemand: true, bufferExists: true),
            .empty
        )
    }

    // MARK: - Off-demand buffers (system, server logs) — key off row existence

    func testOffDemandBufferLoadsUntilItsRowMaterializes() {
        // The system/server row is created BY its connect backlog. Before that the row is
        // absent — and the socket can already read `.connected`, so keying off the socket
        // would flash `.empty` on the launch screen in the gap. Row absent → still loading.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: false, bufferExists: false),
            .loading
        )
    }

    func testOffDemandBufferEmptyOnceItsRowExists() {
        // Backlog landed and the row is here. An empty system buffer looks exactly like
        // this.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: true, hydratesOnDemand: false, bufferExists: true),
            .empty
        )
    }

    func testEmptyServerLogIsEmptyNotStuckLoading() {
        // The regression guard: an empty `:server:` backlog never sets `hydrated` (the
        // server omits `hasMoreOlder`, the parser defaults it true) and `:server:` can't
        // hydrate on demand to fix that — so a `hydrated`-keyed rule would spin forever.
        // Row existence is what saves it.
        XCTAssertEqual(
            BufferPlaceholder.of(hasMessages: false, hydrated: false, hydratesOnDemand: false, bufferExists: true),
            .empty
        )
    }

    // MARK: - historyLanded, shared with the unread banner's `dividerSeen` latch

    func testOnDemandHistoryLandsOnlyWhenHydrated() {
        // The stub an unread banner must not be judged against: the row is there, but what it
        // holds is the live events that outran the backlog, not the buffer.
        XCTAssertFalse(
            BufferPlaceholder.historyLanded(hydrated: false, hydratesOnDemand: true, bufferExists: true)
        )
        XCTAssertTrue(
            BufferPlaceholder.historyLanded(hydrated: true, hydratesOnDemand: true, bufferExists: true)
        )
    }

    func testOffDemandHistoryLandsWithTheRow() {
        // The other half of the regression guard above, and why the latch can't key off
        // `hydrated` raw: a `:server:` log can stay un-hydrated for its whole life, and a gate
        // that waited for it would hold the banner's retire-latch open all session.
        XCTAssertTrue(
            BufferPlaceholder.historyLanded(hydrated: false, hydratesOnDemand: false, bufferExists: true)
        )
        XCTAssertFalse(
            BufferPlaceholder.historyLanded(hydrated: false, hydratesOnDemand: false, bufferExists: false)
        )
    }
    // MARK: - A server log with no row

    func testAnAbsentServerLogWaitsWhileTheBurstIsStillRunning() {
        // Mid-burst its row may still be on its way, so "loading" is the honest answer.
        XCTAssertEqual(
            BufferPlaceholder.of(
                hasMessages: false, hydrated: false, hydratesOnDemand: false,
                bufferExists: false, rosterSettled: false
            ),
            .loading
        )
    }

    func testAnAbsentServerLogIsEmptyOnceTheBurstHasFinished() {
        // ⚠⚠ Otherwise it spins forever. The buffer list now offers a network's log whether
        // or not a row has arrived — the web always has, its network header being that
        // buffer — so "no row" is something a reader can be looking at, and a server buffer
        // can't hydrate on demand to correct itself.
        XCTAssertEqual(
            BufferPlaceholder.of(
                hasMessages: false, hydrated: false, hydratesOnDemand: false,
                bufferExists: false, rosterSettled: true
            ),
            .empty
        )
    }

    func testASettledRosterChangesNothingForAChannel() {
        // On-demand kinds still key off `hydrated` alone: a channel shell exists long before
        // its history, and reading a settled roster as "landed" would call it empty while its
        // hydrate reply is in flight.
        XCTAssertEqual(
            BufferPlaceholder.of(
                hasMessages: false, hydrated: false, hydratesOnDemand: true,
                bufferExists: true, rosterSettled: true
            ),
            .loading
        )
    }

}

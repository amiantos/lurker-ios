// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// What the buffer list shows when it has no rows.
///
/// The resolver is three lines; the interesting part is the *signal* it reads. Two plausible
/// ones are wrong in ways that only show on some accounts — the socket is up before the burst
/// is applied, and the `snapshot` frame isn't authoritative for buffer existence — so both are
/// pinned here as regressions rather than left to be re-derived.
@MainActor
final class BufferListPlaceholderTests: XCTestCase {

    func testBuffersPresentMeansNoPlaceholder() {
        XCTAssertEqual(
            BufferListPlaceholder.of(hasBuffers: true, hasNetworks: true, backlogComplete: true), .none
        )
        // Even mid-burst: rows on screen beat any placeholder.
        XCTAssertEqual(
            BufferListPlaceholder.of(hasBuffers: true, hasNetworks: true, backlogComplete: false), .none
        )
    }

    func testNothingYetIsLoadingUntilTheBurstFinishes() {
        XCTAssertEqual(
            BufferListPlaceholder.of(hasBuffers: false, hasNetworks: false, backlogComplete: false), .loading
        )
        // Networks known but the burst still running — the DM-only / all-disconnected case.
        // This is the one that flashed when the flag was latched on the `snapshot` frame.
        XCTAssertEqual(
            BufferListPlaceholder.of(hasBuffers: false, hasNetworks: true, backlogComplete: false), .loading
        )
    }

    func testAFreshAccountIsToldToAddANetwork() {
        XCTAssertEqual(
            BufferListPlaceholder.of(hasBuffers: false, hasNetworks: false, backlogComplete: true), .noNetworks
        )
    }

    func testAnAccountWithNetworksIsNotToldToAddOne() {
        // A network that never connects has no buffers, and this is its steady state — not a
        // flash. Telling someone to add a network they've already added reads as the app not
        // knowing its own state.
        XCTAssertEqual(
            BufferListPlaceholder.of(hasBuffers: false, hasNetworks: true, backlogComplete: true), .noBuffers
        )
    }

    // MARK: - The signal itself

    /// The `snapshot` frame must NOT be what latches this. Its per-network `channels` is empty
    /// for every network without a live connection, and DMs and `:server:` logs are never in it
    /// at all — so on a launch while the networks are still connecting it would claim the roster
    /// had landed with nothing in it, and the list would flash "No buffers yet".
    func testASnapshotAloneDoesNotMeanTheRosterLanded() {
        let store = LurkerStore()
        store.apply(.snapshot([]))
        XCTAssertFalse(store.state.backlogComplete, "the snapshot is a prefix, not the whole answer")
    }

    func testBacklogCompleteLatchesTheRoster() {
        let store = LurkerStore()
        XCTAssertFalse(store.state.backlogComplete)

        store.apply(.backlogComplete)
        XCTAssertTrue(store.state.backlogComplete, "an empty burst is still an answer")
    }

    /// It has to survive a socket drop. A reconnect re-sends everything, but the roster we
    /// already have stays on screen while it does — going back to `.loading` would blank a list
    /// with perfectly good content in it.
    func testBacklogCompleteSurvivesAReconnect() {
        let store = LurkerStore()
        store.apply(.backlogComplete)

        store.apply(.socketOpen)
        store.apply(.socketClosed(reason: nil, code: nil))
        XCTAssertEqual(store.state.connection, .reconnecting)
        XCTAssertTrue(store.state.backlogComplete, "a drop doesn't un-answer the question")
    }

    /// Sign-out has to clear it, or the next account's cold launch reads the previous one's
    /// answer and shows "No networks yet" before its own burst lands.
    func testResetClearsBacklogComplete() {
        let store = LurkerStore()
        store.apply(.backlogComplete)
        XCTAssertTrue(store.state.backlogComplete)

        store.reset()
        XCTAssertFalse(store.state.backlogComplete)
    }

    /// The frame carries no payload, so the only thing that can go wrong is not recognizing
    /// its `kind` — in which case it parses as `.ignored` and the list spins forever.
    func testTheTerminalFrameParses() {
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"backlog-complete"}"##), .backlogComplete)
    }
}

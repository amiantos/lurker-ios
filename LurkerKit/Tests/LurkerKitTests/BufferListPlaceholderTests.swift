// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// What the buffer list shows when it has no rows.
///
/// The interesting case isn't the resolver — it's two lines — but the *signal* it reads.
/// Keying this on the socket instead of the snapshot is the mistake that's easy to make and
/// hard to notice: it looks right on a warm launch and flashes "no networks" on a cold one.
@MainActor
final class BufferListPlaceholderTests: XCTestCase {

    func testBuffersPresentMeansNoPlaceholder() {
        XCTAssertEqual(BufferListPlaceholder.of(hasBuffers: true, snapshotLoaded: true), .none)
        // Even mid-fetch: rows on screen beat any placeholder.
        XCTAssertEqual(BufferListPlaceholder.of(hasBuffers: true, snapshotLoaded: false), .none)
    }

    func testNothingYetIsLoadingUntilTheSnapshotLands() {
        XCTAssertEqual(BufferListPlaceholder.of(hasBuffers: false, snapshotLoaded: false), .loading)
    }

    func testAnEmptyAnswerIsAnAnswer() {
        // An account with no networks configured. The server has said so; spinning forever
        // would be the app declining to admit it.
        XCTAssertEqual(BufferListPlaceholder.of(hasBuffers: false, snapshotLoaded: true), .empty)
    }

    // MARK: - The signal itself

    /// `snapshotLoaded` has to survive a socket drop. A reconnect resends the snapshot, but
    /// the roster we already have stays on screen while it does — going back to `.loading`
    /// would blank a list with perfectly good content in it.
    func testSnapshotLoadedLatchesAcrossAReconnect() {
        let store = LurkerStore()
        XCTAssertFalse(store.state.snapshotLoaded)

        store.apply(.snapshot([]))
        XCTAssertTrue(store.state.snapshotLoaded, "an empty snapshot is still an answer")

        store.apply(.socketOpen)
        store.apply(.socketClosed(reason: nil, code: nil))
        XCTAssertEqual(store.state.connection, .reconnecting)
        XCTAssertTrue(store.state.snapshotLoaded, "a drop doesn't un-answer the question")
    }

    /// Sign-out has to clear it, or the next account's cold launch reads the previous one's
    /// answer and shows "No buffers yet" before its snapshot lands.
    func testResetClearsSnapshotLoaded() {
        let store = LurkerStore()
        store.apply(.snapshot([]))
        XCTAssertTrue(store.state.snapshotLoaded)

        store.reset()
        XCTAssertFalse(store.state.snapshotLoaded)
    }
}

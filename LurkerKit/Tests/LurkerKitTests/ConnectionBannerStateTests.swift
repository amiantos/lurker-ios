// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The worded connection banner: which message the top of the chat screen shows, and the
/// one rule that matters most — no network path beats whatever the socket claims.
final class ConnectionBannerStateTests: XCTestCase {

    func testConnectedAndReachableShowsNothing() {
        XCTAssertEqual(ConnectionBannerState.of(reachable: true, connection: .connected), .hidden)
    }

    func testNoPathIsOfflineRegardlessOfSocket() {
        // The socket can't say "no internet" — it only ever reports connecting/connected/
        // reconnecting — so a stale socket state must not hide the offline truth.
        XCTAssertEqual(ConnectionBannerState.of(reachable: false, connection: .connected), .offline)
        XCTAssertEqual(ConnectionBannerState.of(reachable: false, connection: .reconnecting), .offline)
        XCTAssertEqual(ConnectionBannerState.of(reachable: false, connection: .connecting), .offline)
    }

    func testConnectingAndReconnectingAreDistinctWhenReachable() {
        // Two different stories: "we've never connected this session" vs. "we had it and
        // dropped". Both reachable, so both are ours to fix and both spin.
        XCTAssertEqual(ConnectionBannerState.of(reachable: true, connection: .connecting), .connecting)
        XCTAssertEqual(ConnectionBannerState.of(reachable: true, connection: .reconnecting), .reconnecting)
    }

    func testOnlyConnectingAndReconnectingSpin() {
        // Offline has nothing to spin about — there's no attempt in flight until a path
        // comes back — so it reads as a settled, user-actionable state, not a busy one.
        XCTAssertTrue(ConnectionBannerState.connecting.isWorking)
        XCTAssertTrue(ConnectionBannerState.reconnecting.isWorking)
        XCTAssertFalse(ConnectionBannerState.offline.isWorking)
        XCTAssertFalse(ConnectionBannerState.hidden.isWorking)
    }
}

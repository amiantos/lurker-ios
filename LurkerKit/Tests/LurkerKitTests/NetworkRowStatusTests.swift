// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// What a networks-screen row says and offers (#11). Worth its own tests because the rule is
/// about which actions are *absent*, and an action that shouldn't be there is invisible in a
/// screenshot — you only find it by tapping it and reading the server's refusal.
final class NetworkRowStatusTests: XCTestCase {

    func testTheStatusFollowsTheConnection() {
        XCTAssertEqual(NetworkRowStatus.of(connection: .connected, blocked: false), .connected)
        XCTAssertEqual(NetworkRowStatus.of(connection: .connecting, blocked: false), .connecting)
        XCTAssertEqual(NetworkRowStatus.of(connection: .reconnecting, blocked: false), .reconnecting)
        XCTAssertEqual(NetworkRowStatus.of(connection: .disconnected, blocked: false), .disconnected)
    }

    func testBlockedOutranksTheConnection() {
        // The allowlist gates new connections, not existing ones, so a blocked network can
        // legitimately still be connected — and in that state the fact worth leading with is
        // that it can't come back if it drops.
        XCTAssertEqual(NetworkRowStatus.of(connection: .connected, blocked: true), .blocked)
        XCTAssertEqual(NetworkRowStatus.of(connection: .disconnected, blocked: true), .blocked)
    }

    func testADisconnectedNetworkOffersToConnect() {
        XCTAssertEqual(NetworkRowStatus.disconnected.actions, [.connect, .delete])
    }

    func testAConnectedNetworkOffersToCycleIt() {
        // Reconnect as well as disconnect: a config change needs a way to take effect, and a
        // wedged connection needs a way to be cycled without two taps and a wait between.
        XCTAssertEqual(NetworkRowStatus.connected.actions, [.disconnect, .reconnect, .delete])
    }

    func testANetworkMidAttemptOffersToCancel() {
        // Disconnect during connecting/reconnecting IS the cancel — the one useful thing to
        // do to a network stuck retrying. Connect would be a no-op and reconnect a restart of
        // something that hasn't started.
        XCTAssertEqual(NetworkRowStatus.connecting.actions, [.disconnect, .delete])
        XCTAssertEqual(NetworkRowStatus.reconnecting.actions, [.disconnect, .delete])
    }

    func testABlockedNetworkOffersNoWayToConnect() {
        // ⚠⚠ The server answers connect and reconnect with 403 on an off-list host, so
        // offering either would offer an action whose only outcome is an error message. The
        // row's own subtitle is where that story belongs.
        XCTAssertEqual(NetworkRowStatus.blocked.actions, [.delete])
    }

    func testDeleteIsAlwaysAvailableAndAlwaysLast() {
        // A network you can't connect to is exactly one you might want gone — including a
        // blocked one, which is otherwise inert. Last, so it isn't adjacent to the action
        // someone actually came to tap.
        for status: NetworkRowStatus in [.connected, .connecting, .reconnecting, .disconnected, .blocked] {
            XCTAssertEqual(status.actions.last, .delete, "\(status)")
            XCTAssertEqual(status.actions.filter { $0 == .delete }.count, 1, "\(status)")
        }
    }

    func testDeleteIsTheOnlyDestructiveAction() {
        // Everything else is undone by its opposite, so it's the only one owed a confirmation.
        XCTAssertEqual(NetworkAction.allCases.filter(\.isDestructive), [.delete])
    }

    func testTheDotSharesThePillsVocabulary() {
        // One colour, one meaning, app-wide: amber is "still trying", red is "not fixing
        // itself" — the distinction `StatusLight` exists to keep.
        XCTAssertEqual(NetworkRowStatus.connected.light, .good)
        XCTAssertEqual(NetworkRowStatus.connecting.light, .warn)
        XCTAssertEqual(NetworkRowStatus.reconnecting.light, .warn)
        XCTAssertEqual(NetworkRowStatus.disconnected.light, .bad)
        XCTAssertEqual(NetworkRowStatus.blocked.light, .bad)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// What a networks-screen row says and offers (#11). Worth its own tests because the rule is
/// mostly about which actions are *absent*, and an action that shouldn't be there is invisible
/// in a screenshot — you only find it by tapping it and reading the server's refusal, and one
/// that should be there and isn't is found by needing it.
final class NetworkRowTests: XCTestCase {

    private func row(_ connection: ConnectionState, blocked: Bool = false) -> NetworkRow {
        NetworkRow(connection: connection, isBlocked: blocked)
    }

    func testADisconnectedNetworkOffersToConnect() {
        XCTAssertEqual(row(.disconnected).actions, [.connect, .delete])
    }

    func testAConnectedNetworkOffersToCycleIt() {
        // Reconnect as well as disconnect: a config change needs a way to take effect, and a
        // wedged connection needs cycling without two taps and a wait between them.
        XCTAssertEqual(row(.connected).actions, [.disconnect, .reconnect, .delete])
    }

    func testANetworkMidAttemptOffersToCancel() {
        // Disconnect during connecting/reconnecting IS the cancel — the one useful thing to
        // do to a network stuck retrying. Connect would be a no-op and reconnect a restart of
        // something that hasn't started.
        XCTAssertEqual(row(.connecting).actions, [.disconnect, .delete])
        XCTAssertEqual(row(.reconnecting).actions, [.disconnect, .delete])
    }

    // MARK: - Blocked

    func testABlockedNetworkOffersNoWayToConnect() {
        // The server answers connect and reconnect with 403 on an off-list host (#298), so
        // either would be an action whose only outcome is an error message.
        XCTAssertEqual(row(.disconnected, blocked: true).actions, [.delete])
        XCTAssertFalse(row(.connected, blocked: true).actions.contains(.reconnect))
    }

    func testABlockedNetworkCanStillBeDisconnected() {
        // ⚠⚠ The allowlist gates NEW connections — `/connect` and `/reconnect` check it,
        // `/disconnect` does not. So a network can be blocked and connected at once, which is
        // what an admin tightening the list under a live connection produces. Withholding
        // disconnect there would leave the user unable to stop a connection the server would
        // happily stop.
        XCTAssertEqual(row(.connected, blocked: true).actions, [.disconnect, .delete])
    }

    func testBlockedDoesNotRepaintALiveConnectionAsBroken() {
        // Blocked is a fact about what this network can do next, not about whether it works
        // now. A connected row works now, whatever the allowlist says about reconnecting it
        // later.
        XCTAssertEqual(row(.connected, blocked: true).light, .good)
        XCTAssertEqual(row(.connecting, blocked: true).light, .warn)
    }

    // MARK: - Connection-only surfaces (#152)

    func testConnectionActionsOfferTheSameVerbsWithoutDelete() {
        // The server buffer's info sheet manages the connection, not the row: the same offers
        // as the menu, minus the one that destroys the network and its history.
        XCTAssertEqual(row(.disconnected).connectionActions, [.connect])
        XCTAssertEqual(row(.connected).connectionActions, [.disconnect, .reconnect])
        XCTAssertEqual(row(.reconnecting).connectionActions, [.disconnect])
        for connection in [ConnectionState.connected, .connecting, .reconnecting, .disconnected] {
            XCTAssertFalse(row(connection, blocked: true).connectionActions.contains(.delete))
        }
    }

    func testABlockedOfflineNetworkHasNoConnectionActionsAtAll() {
        // Nothing to offer and no Delete to fill the gap — the sheet explains in its footer
        // rather than showing an action whose only outcome is a 403.
        XCTAssertEqual(row(.disconnected, blocked: true).connectionActions, [])
    }

    // MARK: - Shape

    func testDeleteIsAlwaysAvailableAndAlwaysLast() {
        // A network you can't connect to is exactly one you might want gone — including a
        // blocked one, which is otherwise inert. Last, so it isn't adjacent to the action
        // someone actually came to tap.
        for connection: ConnectionState in [.connected, .connecting, .reconnecting, .disconnected] {
            for blocked in [true, false] {
                let actions = row(connection, blocked: blocked).actions
                XCTAssertEqual(actions.last, .delete, "\(connection) blocked:\(blocked)")
                XCTAssertEqual(actions.filter { $0 == .delete }.count, 1, "\(connection) blocked:\(blocked)")
            }
        }
    }

    func testDeleteIsTheOnlyDestructiveAction() {
        // Everything else is undone by its opposite, so it's the only one owed a confirmation.
        XCTAssertEqual(NetworkAction.allCases.filter(\.isDestructive), [.delete])
    }

    func testTheDotSharesThePillsVocabulary() {
        // One colour, one meaning, app-wide: amber is "still trying", red is "not fixing
        // itself" — the distinction `StatusLight` exists to keep.
        XCTAssertEqual(row(.connected).light, .good)
        XCTAssertEqual(row(.connecting).light, .warn)
        XCTAssertEqual(row(.reconnecting).light, .warn)
        XCTAssertEqual(row(.disconnected).light, .bad)
    }
}

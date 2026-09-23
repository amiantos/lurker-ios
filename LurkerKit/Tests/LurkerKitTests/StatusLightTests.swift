// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The indicator light under a buffer's title. Three states, and which one wins when several
/// layers are unhappy at once.
final class StatusLightTests: XCTestCase {

    // MARK: - No path beats everything

    func testNoNetworkPathIsRedRegardlessOfWhatElseClaims() {
        // The socket can't report "there is no internet" — it only ever says
        // connecting/connected/reconnecting — so a stale `.connected` must not paint the
        // light green on a phone in airplane mode.
        XCTAssertEqual(
            StatusLight.of(reachable: false, connection: .connected, network: .connected), .bad
        )
        XCTAssertEqual(StatusLight.of(reachable: false, connection: .connecting, network: nil), .bad)
    }

    // MARK: - The socket layer

    func testAConnectingOrReconnectingSocketIsAmberNeverRed() {
        // A dropped socket is always retrying, so it's "still trying", not "broken".
        // There is deliberately no red here.
        XCTAssertEqual(StatusLight.of(reachable: true, connection: .connecting, network: nil), .warn)
        XCTAssertEqual(StatusLight.of(reachable: true, connection: .reconnecting, network: nil), .warn)
        XCTAssertEqual(
            StatusLight.of(reachable: true, connection: .reconnecting, network: .connected), .warn,
            "no Lurker means the network state we hold is stale, whatever it says"
        )
    }

    func testAServerThatCantTakeThisBuildIsRed() {
        // The one socket state that isn't retrying, so amber would promise a fix that isn't coming.
        XCTAssertEqual(
            StatusLight.of(reachable: true, connection: .incompatible(.appTooOld), network: .connected), .bad
        )
        XCTAssertEqual(
            StatusLight.of(reachable: true, connection: .incompatible(.serverTooOld), network: nil), .bad
        )
    }

    // MARK: - The system buffer

    func testTheSystemBufferIsGreenOnceTheSocketIsUp() {
        // nil network = the system buffer, whose whole story is the socket.
        XCTAssertEqual(StatusLight.of(reachable: true, connection: .connected, network: nil), .good)
    }

    // MARK: - Per-network

    func testANetworkBufferTracksItsNetwork() {
        func light(_ state: ConnectionState) -> StatusLight {
            StatusLight.of(reachable: true, connection: .connected, network: state)
        }
        XCTAssertEqual(light(.connected), .good)
        XCTAssertEqual(light(.connecting), .warn)
        XCTAssertEqual(light(.reconnecting), .warn)
        XCTAssertEqual(light(.disconnected), .bad, "the server gave up; it isn't coming back on its own")
    }

    func testMatchesTheWebClientsNetworkIndicator() {
        // vue_client BufferList.vue stateClass(): connected → good, connecting/
        // reconnecting → warn, otherwise bad. Same signal, same color, both clients.
        let cases: [(ConnectionState, StatusLight)] = [
            (.connected, .good), (.connecting, .warn), (.reconnecting, .warn), (.disconnected, .bad),
        ]
        for (state, expected) in cases {
            XCTAssertEqual(
                StatusLight.of(reachable: true, connection: .connected, network: state), expected,
                "\(state) should be \(expected)"
            )
        }
    }

    // MARK: - Subtitle words

    func testLurkerItselfSaysHowItsOwnConnectionIsDoing() {
        XCTAssertEqual(StatusLight.good.subtitle(detail: nil), "Connected")
        XCTAssertEqual(StatusLight.warn.subtitle(detail: nil), "Connecting…")
        XCTAssertEqual(StatusLight.bad.subtitle(detail: nil), "Disconnected")
    }

    func testAChannelNamesItsNetworkAndWhetherItsUp() {
        XCTAssertEqual(StatusLight.good.subtitle(detail: "Libera"), "Libera · Online")
        XCTAssertEqual(StatusLight.warn.subtitle(detail: "Libera"), "Libera · Connecting…")
        XCTAssertEqual(StatusLight.bad.subtitle(detail: "Libera"), "Libera · Disconnected")
    }

    func testADmSaysWhetherThePersonIsThereNotWhetherTheNetworkIs() {
        XCTAssertEqual(StatusLight.good.subtitle(detail: "Libera", peer: .online), "Libera · Online")
        XCTAssertEqual(StatusLight.good.subtitle(detail: "Libera", peer: .away), "Libera · Away")
        XCTAssertEqual(StatusLight.good.subtitle(detail: "Libera", peer: .offline), "Libera · Offline")
        // No MONITOR, or nothing heard yet: "Online" would be the network's word read as theirs.
        XCTAssertEqual(StatusLight.good.subtitle(detail: "Libera", peer: .unknown), "Libera")
        // A network whose name hasn't arrived: never a blank subtitle.
        XCTAssertEqual(StatusLight.good.subtitle(detail: nil, peer: .unknown), "Connected")
    }

    func testADmOnADownedLinkSaysTheLinkNotAGuessAboutThePeer() {
        // `presence` reads `.offline` for every peer on a network we've lost; the subtitle must
        // not pass that on as a fact about them.
        XCTAssertEqual(StatusLight.bad.subtitle(detail: "Libera", peer: .offline), "Libera · Disconnected")
        XCTAssertEqual(StatusLight.warn.subtitle(detail: "Libera", peer: .away), "Libera · Connecting…")
    }
}

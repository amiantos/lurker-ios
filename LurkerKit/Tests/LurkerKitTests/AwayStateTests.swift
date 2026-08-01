// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Your own away state (#68), from the wire to the store: the snapshot seed, the live
/// `away-state` patch, and the two ways it can be *cleared* — which are the parts worth
/// pinning, because a stale away leaves a permanent marker in every buffer with nothing able
/// to retract it.
@MainActor
final class AwayStateTests: XCTestCase {

    // MARK: - Parser

    func testSnapshotCarriesTheAwayBlob() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"away":{"active":false,"since":"2026-07-20T12:00:00Z","message":"lunch","autoSet":true,"backAt":"2026-07-20T13:00:00Z"}}]}"##
        )
        guard case let .snapshot(networks, _) = frame else { return XCTFail("expected snapshot, got \(frame)") }
        let away = networks.first?.away
        XCTAssertEqual(away?.active, false)
        XCTAssertEqual(away?.message, "lunch")
        XCTAssertEqual(away?.autoSet, true)
        XCTAssertEqual(away?.since, ISOTime.parse("2026-07-20T12:00:00Z"))
        XCTAssertEqual(away?.backAt, ISOTime.parse("2026-07-20T13:00:00Z"))
    }

    func testASnapshotWithNoAwayParsesAsNil() {
        // The server sends `away: null` for an account with nothing on record. Nil, not a
        // default-constructed state: inventing `active: false` would claim the user *returned*
        // rather than that we were never told anything.
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"away":null}]}"##
        )
        guard case let .snapshot(networks, _) = frame else { return XCTFail("expected snapshot, got \(frame)") }
        XCTAssertNil(networks.first?.away)
    }

    func testABlobWithNoReadableSinceIsRefused() {
        // `since` is what both markers are placed from, and the server treats it as the
        // existence test too (`away = a.since ? {…} : null`). So a blob we can't read one out of
        // is a blob no marker can be placed from — reading it as an away with no beginning would
        // put a value in the store that nothing can use and nothing can retract.
        for blob in [##"{"active":true}"##, ##"{"active":true,"since":null}"##, ##"{"since":"not a date"}"##] {
            let frame = FrameParser.parseWs(
                ##"{"kind":"irc","networkId":2,"target":":server:2","type":"away-state","away":"## + blob + "}"
            )
            guard case let .awayState(_, away) = frame else { return XCTFail("expected awayState, got \(frame)") }
            XCTAssertNil(away, "\(blob) has no beginning to anchor from")
        }
    }

    func testAwayStateRidesIrcWithServerTarget() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"away-state","away":{"active":true,"since":"2026-07-20T12:00:00Z","message":"brb","autoSet":false,"backAt":null}}"##
        )
        guard case let .awayState(networkId, away) = frame else {
            return XCTFail("expected awayState, got \(frame)")
        }
        XCTAssertEqual(networkId, 2)
        XCTAssertEqual(away?.active, true)
        XCTAssertEqual(away?.message, "brb")
        XCTAssertNil(away?.backAt, "still away")
    }

    func testANullAwayIsAValueNotADroppedFrame() {
        // This is how "cleared" arrives, so it has to reach the store as a frame carrying nil
        // rather than being refused as unparseable.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"away-state","away":null}"##
        )
        guard case let .awayState(networkId, away) = frame else {
            return XCTFail("expected awayState, got \(frame)")
        }
        XCTAssertEqual(networkId, 2)
        XCTAssertNil(away)
    }

    func testAwayStateWithoutANetworkIsIgnored() {
        // Every real one carries a networkId; one without has no network to patch.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","target":":server:2","type":"away-state","away":{"active":true}}"##
        )
        guard case .ignored = frame else { return XCTFail("expected ignored, got \(frame)") }
    }

    func testAwayStateIsNotReadAsAMessage() {
        // The regression this case exists to prevent: left to `parseEvent` it becomes an
        // `.other` Message appended to the `:server:` buffer, carrying its payload in no field
        // anything reads.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"away-state","away":null}"##
        )
        if case .live = frame { XCTFail("away-state is state, not a line") }
    }

    // MARK: - Store

    private func snapshot(_ away: AwayState?) -> ServerFrame {
        .snapshot(
            [NetworkSnapshot(id: 2, state: .connected, nick: "me", channels: [], away: away)],
            globalIgnores: []
        )
    }

    private let wentAway = AwayState(
        active: true, message: "brb", since: Date(timeIntervalSince1970: 1_784_548_800)
    )

    func testTheSnapshotSeedsTheNetworksAwayState() {
        let store = LurkerStore()
        store.apply(snapshot(wentAway))
        XCTAssertEqual(store.state.networks[2]?.away, wentAway)
    }

    func testALiveFramePatchesIt() {
        let store = LurkerStore()
        store.apply(snapshot(nil))
        store.apply(.awayState(networkId: 2, away: wentAway))
        XCTAssertEqual(store.state.networks[2]?.away?.message, "brb")

        let cameBack = AwayState(
            active: false, message: "brb", since: wentAway.since,
            backAt: Date(timeIntervalSince1970: 1_784_552_400)
        )
        store.apply(.awayState(networkId: 2, away: cameBack))
        XCTAssertEqual(store.state.networks[2]?.away?.backAt, cameBack.backAt)
        XCTAssertEqual(
            store.state.networks[2]?.away?.since, wentAway.since,
            "since survives /back — the completed pair is what the dividers render"
        )
    }

    func testANullFrameClearsIt() {
        let store = LurkerStore()
        store.apply(snapshot(wentAway))
        store.apply(.awayState(networkId: 2, away: nil))
        XCTAssertNil(store.state.networks[2]?.away)
    }

    func testASnapshotWithNoAwayClearsAStaleOne() {
        // A reconnect after coming back on another device. The snapshot is this network's whole
        // live state, so keeping the old value would strand an "away" marker in every buffer.
        let store = LurkerStore()
        store.apply(snapshot(wentAway))
        store.apply(snapshot(nil))
        XCTAssertNil(store.state.networks[2]?.away)
    }

    func testAFrameForAnUnknownNetworkMaterializesNothing() {
        // The away stream is broadcast from a live connection, so its network is in the
        // snapshot by definition. Creating a row here would invent a network with no name and
        // no state, which the roster would then render.
        let store = LurkerStore()
        store.apply(.awayState(networkId: 99, away: wentAway))
        XCTAssertNil(store.state.networks[99])
    }

    func testTheRestRosterDoesNotClobberIt() {
        // `GET /api/networks` carries no live state — it merges a name in. An away lost to it
        // would vanish every time the roster refreshed.
        let store = LurkerStore()
        store.apply(snapshot(wentAway))
        store.apply(.networks([Network(id: 2, name: "Libera")]))
        XCTAssertEqual(store.state.networks[2]?.name, "Libera")
        XCTAssertEqual(store.state.networks[2]?.away, wentAway)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The favorites (Friends/Favorites) + peer-presence path, end to end: the parser reads the
/// real wire frames, and the store folds them — the wholesale favorites list, disconnected-
/// aware presence, null-state clearing. Presence derivation is the subtle part, so it's
/// exercised in every branch.
@MainActor
final class ContactsAndPresenceTests: XCTestCase {

    // MARK: - Parser

    func testFavoritesChangedParsesEntriesInOrder() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"favorites-changed","favorites":[{"networkId":2,"target":"darc","bufferId":41},{"networkId":3,"target":"#lurker","bufferId":7}]}"##
        )
        guard case let .favoritesChanged(favorites) = frame else {
            return XCTFail("expected favoritesChanged, got \(frame)")
        }
        XCTAssertEqual(
            favorites,
            [
                FavoriteEntry(networkId: 2, target: "darc", bufferId: 41),
                FavoriteEntry(networkId: 3, target: "#lurker", bufferId: 7),
            ],
            "one global list, order preserved verbatim — position IS the user's answer"
        )
    }

    func testFavoritesChangedWithEmptyListParses() {
        // Unfavoriting the last entry ships an empty list, not an absent field.
        let frame = FrameParser.parseWs(##"{"kind":"favorites-changed","favorites":[]}"##)
        guard case let .favoritesChanged(favorites) = frame else {
            return XCTFail("expected favoritesChanged, got \(frame)")
        }
        XCTAssertEqual(favorites, [])
    }

    func testPeerPresenceRidesIrcWithServerTarget() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"peer-presence","nick":"darc","state":"online","stateAt":"2026-07-24T00:00:00Z","cameOnline":true}"##
        )
        guard case let .peerPresence(networkId, nick, state) = frame else {
            return XCTFail("expected peerPresence, got \(frame)")
        }
        XCTAssertEqual(networkId, 2)
        XCTAssertEqual(nick, "darc")
        XCTAssertEqual(state, .online)
    }

    func testPeerPresenceWithNullStateParsesAsNil() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"target":":server:2","type":"peer-presence","nick":"darc","state":null}"##
        )
        guard case let .peerPresence(_, _, state) = frame else {
            return XCTFail("expected peerPresence, got \(frame)")
        }
        XCTAssertNil(state)
    }

    func testPeerPresenceWithoutNetworkIsIgnored() {
        // Every real peer-presence carries a networkId (publishEphemeral stamps it); one
        // without has no map to route into.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","target":":server:2","type":"peer-presence","nick":"darc","state":"away"}"##
        )
        guard case .ignored = frame else { return XCTFail("expected ignored, got \(frame)") }
    }

    func testPeerPresenceRoutesByNickEvenWithoutTarget() {
        // Presence is routed by nick, not target (`:server:<id>` is only a carrier). Parsing
        // must not hinge on the target field, so a frame missing it still routes.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"type":"peer-presence","nick":"darc","state":"online"}"##
        )
        guard case let .peerPresence(networkId, nick, state) = frame else {
            return XCTFail("expected peerPresence, got \(frame)")
        }
        XCTAssertEqual(networkId, 2)
        XCTAssertEqual(nick, "darc")
        XCTAssertEqual(state, .online)
    }

    func testSnapshotSeedsPeerPresence() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"peerPresence":{"darc":{"nick":"darc","state":"away","stateAt":null,"awayMessage":"brb"}}}]}"##
        )
        guard case let .snapshot(networks, _) = frame else {
            return XCTFail("expected snapshot, got \(frame)")
        }
        XCTAssertEqual(networks.first?.peerPresence["darc"], .away)
    }

    // MARK: - Store: favorites

    private func entry(_ id: Int, _ target: String, net: Int = 2) -> FavoriteEntry {
        FavoriteEntry(networkId: net, target: target, bufferId: id)
    }

    func testFavoritesChangedReplacesWholesaleKeepingServerOrder() {
        let store = LurkerStore()
        store.apply(.favoritesChanged([entry(1, "zed"), entry(2, "#alpha"), entry(3, "bob")]))
        // NOT re-sorted: the server's global order is user-controlled.
        XCTAssertEqual(store.state.favorites.map(\.target), ["zed", "#alpha", "bob"])
        // A later frame replaces, never merges — removal and reorder are the same op.
        store.apply(.favoritesChanged([entry(3, "bob")]))
        XCTAssertEqual(store.state.favorites.map(\.target), ["bob"])
    }

    func testFavoriteEntryFollowsAPlainBufferRename() {
        // The server only republishes favorites after MERGES, so a plain
        // nick-follow rename must rewrite the entry locally — by bufferId, the
        // identity the frame proves — or the Friends chip ghosts under the dead
        // nick while the renamed DM leaks back into its network roster.
        let store = LurkerStore()
        store.apply(.favoritesChanged([entry(41, "zed", net: 2), entry(7, "#alpha", net: 2)]))
        store.apply(.bufferRenamed(
            networkId: 2, from: "zed", to: "zed_", bufferId: 41, merged: false,
            mergedFromBufferId: nil
        ))
        XCTAssertEqual(store.state.favorites.map(\.target), ["zed_", "#alpha"])
        XCTAssertEqual(store.state.favorites.map(\.bufferId), [41, 7], "identity untouched")
    }

    // MARK: - Store: presence derivation

    private func connectedNetwork(_ id: Int, presence: [String: PresenceState] = [:]) -> ServerFrame {
        .snapshot(
            [NetworkSnapshot(id: id, state: .connected, nick: "me", channels: [], peerPresence: presence)],
            globalIgnores: []
        )
    }

    /// A store with a live socket. presence() now gates on the client's own link, so a test
    /// asserting a specific peer status must first be "connected" or every dot reads offline.
    private func connectedStore() -> LurkerStore {
        let store = LurkerStore()
        store.apply(.socketOpen)
        return store
    }

    func testPresenceOfflineWhileClientIsDisconnected() {
        let store = connectedStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .online)
        // Socket drops → reconnecting: the cached row is stale, so the dot must not claim online
        // even though the network's own state is still .connected from the last snapshot.
        store.apply(.socketClosed(reason: nil, code: nil))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .offline)
    }

    func testPresenceOfflineWhenDeviceUnreachable() {
        let store = connectedStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        store.setReachable(false)
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .offline)
    }

    func testPresenceUnknownForNetworkWeDoNotHave() {
        let store = connectedStore()
        XCTAssertEqual(store.state.presence(networkId: 99, nick: "darc"), .unknown)
    }

    func testPresenceUnknownForConnectedNetworkWithNoRow() {
        let store = connectedStore()
        store.apply(connectedNetwork(2))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .unknown)
    }

    func testPresenceReadsStoredRowCaseInsensitively() {
        let store = connectedStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "Darc"), .online)
    }

    func testBackReadsAsOnline() {
        let store = connectedStore()
        store.apply(connectedNetwork(2, presence: ["darc": .back]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .online)
    }

    func testDisconnectedNetworkReadsOfflineRegardlessOfRow() {
        let store = connectedStore()
        // A network we hold but that isn't connected: its cached rows are stale, so a friend
        // there is unreachable → offline, even if a stale row said otherwise.
        store.apply(.snapshot([
            NetworkSnapshot(id: 2, state: .reconnecting, nick: "me", channels: [], peerPresence: ["darc": .online]),
        ], globalIgnores: []))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .offline)
    }

    func testLivePeerPresenceUpdatesAndNullClears() {
        let store = connectedStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        store.apply(.peerPresence(networkId: 2, nick: "Darc", state: .away))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .away)
        // A null state clears the row → unknown (network is still connected).
        store.apply(.peerPresence(networkId: 2, nick: "darc", state: nil))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .unknown)
    }

    func testPresenceIsPerNetwork() {
        let store = connectedStore()
        store.apply(.snapshot([
            NetworkSnapshot(id: 2, state: .connected, nick: "me", channels: [], peerPresence: ["darc": .away]),
            NetworkSnapshot(id: 3, state: .connected, nick: "me", channels: [], peerPresence: ["darc": .online]),
        ], globalIgnores: []))
        // A Friends chip reads the presence of ITS network's peer — the same nick elsewhere
        // is a different person as far as the dot is concerned.
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .away)
        XCTAssertEqual(store.state.presence(networkId: 3, nick: "darc"), .online)
    }

    func testSnapshotReplacesPeerPresenceWholesale() {
        let store = connectedStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online, "naia": .away]))
        // A fresh snapshot for the network is authoritative — a peer no longer watched drops out.
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .online)
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "naia"), .unknown)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The friends (contacts) + peer-presence path, end to end: the parser reads the real wire
/// frames, and the store folds them — sorted contacts, disconnected-aware presence, null-state
/// clearing. Presence derivation is the subtle part, so it's exercised in every branch.
@MainActor
final class ContactsAndPresenceTests: XCTestCase {

    // MARK: - Parser

    func testContactsSnapshotParsesTargetsAndFlags() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"contacts-snapshot","contacts":[{"id":7,"displayName":"Darc","notifyOnline":true,"targets":[{"networkId":2,"nick":"darc","isPrimary":false},{"networkId":3,"nick":"darc_","isPrimary":true}]}]}"##
        )
        guard case let .contactsSnapshot(contacts) = frame else {
            return XCTFail("expected contactsSnapshot, got \(frame)")
        }
        XCTAssertEqual(contacts.count, 1)
        let contact = contacts[0]
        XCTAssertEqual(contact.id, 7)
        XCTAssertEqual(contact.displayName, "Darc")
        XCTAssertTrue(contact.notifyOnline)
        XCTAssertEqual(contact.targets.count, 2)
        // The primary is the flagged one, not the first.
        XCTAssertEqual(contact.primaryTarget?.nick, "darc_")
        XCTAssertEqual(contact.primaryTarget?.networkId, 3)
    }

    func testContactUpdatedAndDeletedParse() {
        let updated = FrameParser.parseWs(
            ##"{"kind":"contact-updated","contact":{"id":4,"displayName":"Naia","notifyOnline":false,"targets":[{"networkId":1,"nick":"naia","isPrimary":true}]}}"##
        )
        guard case let .contactUpdated(contact) = updated else {
            return XCTFail("expected contactUpdated, got \(updated)")
        }
        XCTAssertEqual(contact.id, 4)
        XCTAssertEqual(contact.displayName, "Naia")

        let deleted = FrameParser.parseWs(##"{"kind":"contact-deleted","contactId":4}"##)
        guard case let .contactDeleted(id) = deleted else {
            return XCTFail("expected contactDeleted, got \(deleted)")
        }
        XCTAssertEqual(id, 4)
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

    func testSnapshotSeedsPeerPresence() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"peerPresence":{"darc":{"nick":"darc","state":"away","stateAt":null,"awayMessage":"brb"}}}]}"##
        )
        guard case let .snapshot(networks) = frame else {
            return XCTFail("expected snapshot, got \(frame)")
        }
        XCTAssertEqual(networks.first?.peerPresence["darc"], .away)
    }

    // MARK: - Store: contacts

    private func contact(_ id: Int, _ name: String, net: Int = 2, nick: String = "n", notify: Bool = false) -> Contact {
        Contact(
            id: id, displayName: name, notifyOnline: notify,
            targets: [ContactTarget(networkId: net, nick: nick, isPrimary: true)]
        )
    }

    func testContactsSnapshotIsSortedCaseInsensitively() {
        let store = LurkerStore()
        store.apply(.contactsSnapshot([contact(1, "bob"), contact(2, "Alice"), contact(3, "charlie")]))
        XCTAssertEqual(store.state.contacts.map(\.displayName), ["Alice", "bob", "charlie"])
    }

    func testContactUpdatedUpsertsAndResorts() {
        let store = LurkerStore()
        store.apply(.contactsSnapshot([contact(1, "Alice"), contact(2, "Zed")]))
        // Rename Zed → Bob: it upserts by id and re-sorts, landing between Alice and any others.
        store.apply(.contactUpdated(contact(2, "Bob")))
        XCTAssertEqual(store.state.contacts.map(\.displayName), ["Alice", "Bob"])
        XCTAssertEqual(store.state.contacts.count, 2, "same id updates in place, not appends")
    }

    func testContactDeletedRemovesById() {
        let store = LurkerStore()
        store.apply(.contactsSnapshot([contact(1, "Alice"), contact(2, "Bob")]))
        store.apply(.contactDeleted(1))
        XCTAssertEqual(store.state.contacts.map(\.displayName), ["Bob"])
    }

    // MARK: - Store: presence derivation

    private func connectedNetwork(_ id: Int, presence: [String: PresenceState] = [:]) -> ServerFrame {
        .snapshot([NetworkSnapshot(id: id, state: .connected, nick: "me", channels: [], peerPresence: presence)])
    }

    func testPresenceUnknownForNetworkWeDoNotHave() {
        let store = LurkerStore()
        XCTAssertEqual(store.state.presence(networkId: 99, nick: "darc"), .unknown)
    }

    func testPresenceUnknownForConnectedNetworkWithNoRow() {
        let store = LurkerStore()
        store.apply(connectedNetwork(2))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .unknown)
    }

    func testPresenceReadsStoredRowCaseInsensitively() {
        let store = LurkerStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "Darc"), .online)
    }

    func testBackReadsAsOnline() {
        let store = LurkerStore()
        store.apply(connectedNetwork(2, presence: ["darc": .back]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .online)
    }

    func testDisconnectedNetworkReadsOfflineRegardlessOfRow() {
        let store = LurkerStore()
        // A network we hold but that isn't connected: its cached rows are stale, so a friend
        // there is unreachable → offline, even if a stale row said otherwise.
        store.apply(.snapshot([
            NetworkSnapshot(id: 2, state: .reconnecting, nick: "me", channels: [], peerPresence: ["darc": .online]),
        ]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .offline)
    }

    func testLivePeerPresenceUpdatesAndNullClears() {
        let store = LurkerStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        store.apply(.peerPresence(networkId: 2, nick: "Darc", state: .away))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .away)
        // A null state clears the row → unknown (network is still connected).
        store.apply(.peerPresence(networkId: 2, nick: "darc", state: nil))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .unknown)
    }

    func testPrimaryPresenceFollowsThePrimaryTarget() {
        let store = LurkerStore()
        store.apply(.snapshot([
            NetworkSnapshot(id: 2, state: .connected, nick: "me", channels: [], peerPresence: ["alt": .away]),
            NetworkSnapshot(id: 3, state: .connected, nick: "me", channels: [], peerPresence: ["main": .online]),
        ]))
        // Primary is the flagged target (main on net 3), so the friend reads online even though
        // the other nick is only away.
        let friend = Contact(
            id: 1, displayName: "Darc", notifyOnline: false,
            targets: [
                ContactTarget(networkId: 2, nick: "alt", isPrimary: false),
                ContactTarget(networkId: 3, nick: "main", isPrimary: true),
            ]
        )
        XCTAssertEqual(store.state.primaryPresence(friend), .online)
    }

    func testSnapshotReplacesPeerPresenceWholesale() {
        let store = LurkerStore()
        store.apply(connectedNetwork(2, presence: ["darc": .online, "naia": .away]))
        // A fresh snapshot for the network is authoritative — a peer no longer watched drops out.
        store.apply(connectedNetwork(2, presence: ["darc": .online]))
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "darc"), .online)
        XCTAssertEqual(store.state.presence(networkId: 2, nick: "naia"), .unknown)
    }
}

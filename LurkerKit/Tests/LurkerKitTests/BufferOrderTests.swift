// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The buffer list's order, where the order is the user's own: their network arrangement and
/// their pins, both made on the web and only rendered here.
@MainActor
final class BufferOrderTests: XCTestCase {

    private func network(_ id: Int, _ name: String, position: Int) -> Network {
        Network(id: id, name: name, position: position)
    }

    private func buffer(_ target: String, kind: BufferKind = .channel) -> Buffer {
        Buffer(networkId: 1, target: target, kind: kind)
    }

    // MARK: - Networks

    func testNetworksFollowTheUsersOrderNotTheAlphabet() {
        let networks = [
            2: network(2, "Aardvark", position: 1),
            1: network(1, "Zulu", position: 0),
        ]
        XCTAssertEqual(BufferOrder.networks(networks).map(\.id), [1, 2])
    }

    func testTiesBreakOnIdTheWayTheServerBreaksThem() {
        // `position` is only densified when something is reordered, so ties are normal — and
        // the server's own `ORDER BY position ASC, id ASC` is what the two clients have to
        // agree on. Name would be the wrong tiebreak: two networks would swap on a rename.
        let networks = [
            9: network(9, "Aardvark", position: 0),
            3: network(3, "Zulu", position: 0),
        ]
        XCTAssertEqual(BufferOrder.networks(networks).map(\.id), [3, 9])
    }

    func testANetworkWeHaveNoRosterRowForSortsLast() {
        // Defaulted position, from a network the snapshot materialized before the roster
        // landed (#136). Last is the less startling of the two ways to be wrong for the
        // moment before the re-fetch names it — it doesn't shove itself to the top.
        let networks = [
            1: network(1, "Libera", position: 5),
            2: Network(id: 2, name: nil),
        ]
        XCTAssertEqual(BufferOrder.networks(networks).map(\.id), [1, 2])
    }

    // MARK: - Pins

    func testPinnedBuffersComeBackInTheUsersPinOrder() {
        let buffers = [buffer("#aardvark"), buffer("#zulu"), buffer("#middle")]
        let split = BufferOrder.split(buffers, pinned: ["#zulu", "#middle"])
        XCTAssertEqual(split.pinned.map(\.target), ["#zulu", "#middle"])
        XCTAssertEqual(split.rest.map(\.target), ["#aardvark"])
    }

    func testTheRestKeepsTheOrdinaryOrder() {
        let buffers = [buffer("bob", kind: .dm), buffer("#zulu"), buffer("#aardvark")]
        let split = BufferOrder.split(buffers, pinned: ["#zulu"])
        // Channels before DMs, alphabetical within — unchanged, just without the pinned one.
        XCTAssertEqual(split.rest.map(\.target), ["#aardvark", "bob"])
    }

    func testAPinnedOnlyNetworkHasNothingLeftOver() {
        // The section the caller drops — and the case that would lose the network's
        // connection state if only the unpinned header carried it.
        let split = BufferOrder.split([buffer("#a"), buffer("#b")], pinned: ["#a", "#b"])
        XCTAssertEqual(split.pinned.count, 2)
        XCTAssertTrue(split.rest.isEmpty)
    }

    func testAPinWithNoOpenBufferContributesNothing() {
        // ⚠ A pin row outlives its buffer being parted or closed, so the pin list is a
        // superset of what can be shown. Mapping it blindly would render rows for buffers
        // that aren't there.
        let split = BufferOrder.split([buffer("#here")], pinned: ["#gone", "#here"])
        XCTAssertEqual(split.pinned.map(\.target), ["#here"])
        XCTAssertTrue(split.rest.isEmpty)
    }

    func testASigilIsPartOfTheTargetNotNoiseToFoldAway() {
        // ⚠⚠ Keyed on `target.lowercased()` — `BufferKey.id`'s rule — and NOT on
        // `ChannelName.fold`, which is the autocomplete fold and drops a leading sigil. Under
        // that key `#ops` and `&ops` collide: the pin could render the wrong one, and the
        // filter for "everything else", matching the same collided key, would drop the loser
        // out of the list altogether.
        let split = BufferOrder.split([buffer("#ops"), buffer("&ops")], pinned: ["&ops"])
        XCTAssertEqual(split.pinned.map(\.target), ["&ops"])
        XCTAssertEqual(split.rest.map(\.target), ["#ops"])
    }

    func testPinsMatchTargetsCaseInsensitively() {
        // The pin is stored under the spelling the server last saw and the buffer under the
        // one this client holds; IRC lets those differ. An exact match would silently drop a
        // pin after a CASEMAPPING refold.
        let split = BufferOrder.split([buffer("#Zulu"), buffer("#aardvark")], pinned: ["#ZULU"])
        XCTAssertEqual(split.pinned.map(\.target), ["#Zulu"])
    }

    func testADuplicatedPinDoesNotPrintTheBufferTwice() {
        let split = BufferOrder.split([buffer("#a"), buffer("#b")], pinned: ["#a", "#a"])
        XCTAssertEqual(split.pinned.map(\.target), ["#a"])
        XCTAssertEqual(split.rest.map(\.target), ["#b"])
    }

    func testNoPinsIsJustTheOrdinaryOrder() {
        let buffers = [buffer("#zulu"), buffer("bob", kind: .dm), buffer("#aardvark")]
        let split = BufferOrder.split(buffers, pinned: [])
        XCTAssertTrue(split.pinned.isEmpty)
        XCTAssertEqual(split.rest.map(\.target), ["#aardvark", "#zulu", "bob"])
    }

    // MARK: - What a network section lists

    func testAFavoritedBufferIsNotAlsoListedUnderItsNetwork() {
        // ⚠⚠ A favorite is a relocation, not a shortcut. This used to be true of favorited
        // DMs alone, so a favorited *channel* appeared twice — and since the buffers people
        // favorite are the ones they look at most, the list they scan most was the one with
        // every row they cared about duplicated in it.
        let favorite = buffer("#kept")
        let ordinary = buffer("#other")
        let grouped = BufferOrder.byNetwork(
            [favorite, ordinary], excluding: [favorite.key.id]
        )
        XCTAssertEqual(grouped[1]?.map(\.target), ["#other"])
    }

    func testAFavoriteMatchesRegardlessOfItsSpelling() {
        // The exclusion set is keyed by `BufferKey.id`, which lowercases the target — so a
        // favorite recorded as "#Kept" still hides the buffer held as "#kept".
        let held = Buffer(networkId: 1, target: "#Kept", kind: .channel)
        let grouped = BufferOrder.byNetwork(
            [held], excluding: [BufferKey(networkId: 1, target: "#kept").id]
        )
        XCTAssertNil(grouped[1])
    }

    func testTheSystemBufferHasNoNetworkSection() {
        // It has no network and no row of its own — it's the title pill in the bar.
        let grouped = BufferOrder.byNetwork([Buffer.system, buffer("#chan")], excluding: [])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[1]?.map(\.target), ["#chan"])
    }

    // MARK: - The ordinary order (moved here from the view controller)

    func testChannelsThenDmsThenTheServerLog() {
        let buffers = [
            buffer(":server:", kind: .server),
            buffer("bob", kind: .dm),
            buffer("#chan"),
        ]
        XCTAssertEqual(
            BufferOrder.split(buffers, pinned: []).rest.map(\.target),
            ["#chan", "bob", ":server:"]
        )
    }

    func testTheAlphabeticalKeyStripsEverySigil() {
        // All four, via `ChannelName.stripSigils`: a hand-written `#&` floated `+`/`!`
        // channels above every named one until lurker-ios#98, which the web never did.
        let buffers = [buffer("#zebra"), buffer("!aardvark"), buffer("+middle"), buffer("&bear")]
        XCTAssertEqual(
            BufferOrder.split(buffers, pinned: []).rest.map(\.target),
            ["!aardvark", "&bear", "+middle", "#zebra"]
        )
    }

    // MARK: - Store

    func testTheSnapshotSeedsPinsAndReplacesThemWholesale() {
        let store = LurkerStore()
        store.apply(FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"pinned":["#a","#b"]}]}"##
        ))
        XCTAssertEqual(store.state.pinned[2], ["#a", "#b"])
        // A pin dropped from the web while this device was away has to disappear here rather
        // than survive as a leftover.
        store.apply(FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":2,"state":"connected","nick":"me","channels":[],"pinned":["#b"]}]}"##
        ))
        XCTAssertEqual(store.state.pinned[2], ["#b"])
    }

    func testPinsChangedReplacesOneNetworksList() {
        let store = LurkerStore()
        store.apply(.pinsChanged(networkId: 1, pinned: ["#a"]))
        store.apply(.pinsChanged(networkId: 2, pinned: ["#b"]))
        store.apply(.pinsChanged(networkId: 1, pinned: []))
        XCTAssertEqual(store.state.pinned[1], [])
        // Sent per network, so it says nothing about the others.
        XCTAssertEqual(store.state.pinned[2], ["#b"])
    }

    func testPinsChangedParsesItsOrderedList() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"pins-changed","networkId":4,"pinned":["#b","#a"],"pinnedIds":[7,3]}"##
        )
        guard case let .pinsChanged(networkId, pinned) = frame else {
            return XCTFail("expected pinsChanged, got \(frame)")
        }
        XCTAssertEqual(networkId, 4)
        XCTAssertEqual(pinned, ["#b", "#a"])
    }

    func testDeletingANetworkTakesItsPinsWithIt() {
        let store = LurkerStore()
        store.apply(.networks([Network(id: 1, name: "Libera", position: 0)]))
        store.apply(.pinsChanged(networkId: 1, pinned: ["#a"]))
        store.apply(.networks([]))
        XCTAssertNil(store.state.pinned[1])
    }

    func testTheRosterMergeCarriesThePositionOntoAnExistingNetwork() {
        // ⚠ `position` is REST-only data exactly like `name`, so the merge has to take both.
        // Taking only the name left every network the snapshot materialized stuck at the
        // default — sorting by id for the life of the process, on any launch where the roster
        // read lost its race with the socket.
        let store = LurkerStore()
        store.apply(FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":7,"state":"connected","nick":"me","channels":[]}]}"##
        ))
        XCTAssertEqual(store.state.networks[7]?.position, .max)
        store.apply(.networks([Network(id: 7, name: "Libera", position: 2)]))
        XCTAssertEqual(store.state.networks[7]?.position, 2)
        XCTAssertEqual(store.state.networks[7]?.name, "Libera")
        // …and the live state the snapshot set is still there.
        XCTAssertEqual(store.state.networks[7]?.state, .connected)
    }

    func testTheRosterCarriesThePosition() {
        let frame = FrameParser.parseNetworks(##"{"networks":[{"id":1,"name":"Libera","position":3}]}"##)
        guard case let .networks(networks) = frame else { return XCTFail("expected networks, got \(frame)") }
        XCTAssertEqual(networks.first?.position, 3)
    }

    func testAnOlderServerWithNoPositionSortsLast() {
        let frame = FrameParser.parseNetworks(##"{"networks":[{"id":1,"name":"Libera"}]}"##)
        guard case let .networks(networks) = frame else { return XCTFail("expected networks, got \(frame)") }
        XCTAssertEqual(networks.first?.position, .max)
    }
}

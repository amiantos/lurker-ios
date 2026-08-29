// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Network management (#11) below the UI: the live `state` event the client used to drop, the
/// nameless-network rule that replaced #136's placeholder, and the config rows and request
/// bodies the networks screen is built on.
@MainActor
final class NetworkConfigTests: XCTestCase {

    // MARK: - The `state` event

    func testAStateEventCarriesTheConnectionAndItsNick() {
        // The connect transition, and the only one that carries a nick.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":2,"type":"state","state":"connected","nick":"me"}"##
        )
        guard case let .networkState(networkId, state, nick) = frame else {
            return XCTFail("expected networkState, got \(frame)")
        }
        XCTAssertEqual(networkId, 2)
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(nick, "me")
    }

    func testAStateEventWithoutANickSaysNothingAboutIt() {
        // Every transition but `connected` sends `{type:'state', state}` and nothing else. An
        // absent nick has to read as "unchanged" — as "" it would blank the nick on every
        // disconnect, and everything that asks "is this me?" would start answering wrong.
        let frame = FrameParser.parseWs(##"{"kind":"irc","networkId":2,"type":"state","state":"reconnecting"}"##)
        guard case let .networkState(_, state, nick) = frame else {
            return XCTFail("expected networkState, got \(frame)")
        }
        XCTAssertEqual(state, .reconnecting)
        XCTAssertNil(nick)
    }

    func testAStateEventCarriesNoTargetAndIsParsedAnyway() {
        // `setState` publishes without a target, so this has to be handled above the target
        // guard the buffer-scoped events sit behind. Dropped there, the app's connection
        // state would stay frozen at whatever the connect snapshot said — which is exactly
        // the bug this frame was added to fix.
        let frame = FrameParser.parseWs(##"{"kind":"irc","networkId":2,"type":"state","state":"disconnected"}"##)
        guard case .networkState = frame else { return XCTFail("expected networkState, got \(frame)") }
    }

    func testTheStoreAppliesTheStateAndTheNick() {
        let store = LurkerStore()
        store.apply(.networks([Network(id: 2, name: "Libera")]))
        store.apply(.networkState(networkId: 2, state: .connected, nick: "me"))
        XCTAssertEqual(store.state.networks[2]?.state, .connected)
        XCTAssertEqual(store.state.networks[2]?.nick, "me")
    }

    func testADisconnectKeepsTheNick() {
        let store = LurkerStore()
        store.apply(.networks([Network(id: 2, name: "Libera")]))
        store.apply(.networkState(networkId: 2, state: .connected, nick: "me"))
        store.apply(.networkState(networkId: 2, state: .disconnected, nick: nil))
        XCTAssertEqual(store.state.networks[2]?.state, .disconnected)
        XCTAssertEqual(store.state.networks[2]?.nick, "me")
    }

    func testAStateForAnUnknownNetworkMaterializesNothing() {
        // Same rule as `own-nick` and `away-state`: a state event describes a network the
        // snapshot has already named. Creating a row from one would invent a nameless network
        // the roster never mentioned — and the roster is what decides what the user sees.
        let store = LurkerStore()
        store.apply(.networkState(networkId: 99, state: .connected, nick: "me"))
        XCTAssertNil(store.state.networks[99])
    }

    func testTheRosterNameSurvivesAStateEvent() {
        let store = LurkerStore()
        store.apply(.networks([Network(id: 2, name: "Libera")]))
        store.apply(.networkState(networkId: 2, state: .connected, nick: "me"))
        XCTAssertEqual(store.state.networks[2]?.name, "Libera")
    }

    // MARK: - Nameless networks (#136)

    func testASnapshotForAnUnknownNetworkLeavesItNameless() {
        // ⚠⚠ The whole of #136. The snapshot carries no names, so a network the roster hasn't
        // named arrives with nothing to call it. It used to arrive called "network" — a
        // placeholder nothing downstream could tell from a real name, which is why the app
        // displayed it for the life of the process instead of re-fetching.
        let store = LurkerStore()
        store.apply(FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":7,"state":"connected","nick":"me","channels":[]}]}"##
        ))
        XCTAssertNotNil(store.state.networks[7])
        XCTAssertNil(store.state.networks[7]?.name)
    }

    func testTheRosterFillsInANamelessNetwork() {
        let store = LurkerStore()
        store.apply(FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":7,"state":"connected","nick":"me","channels":[]}]}"##
        ))
        store.apply(.networks([Network(id: 7, name: "Libera")]))
        XCTAssertEqual(store.state.networks[7]?.name, "Libera")
        // And the live state the snapshot set is still there — the roster carries none of it.
        XCTAssertEqual(store.state.networks[7]?.state, .connected)
        XCTAssertEqual(store.state.networks[7]?.nick, "me")
    }

    func testARosterRowWithNoNameParsesAsNameless() {
        // Belt to the snapshot's braces: the endpoint always sends a name today, and a row
        // without one must still not invent the word "network".
        let frame = FrameParser.parseNetworks(##"{"networks":[{"id":3}]}"##)
        guard case let .networks(networks) = frame else { return XCTFail("expected networks, got \(frame)") }
        XCTAssertNil(networks.first?.name)
    }

    func testANamelessNetworkStillRendersAsSomething() {
        XCTAssertEqual(Network(id: 1, name: nil).displayName, "Unnamed network")
        XCTAssertEqual(Network(id: 1, name: "Libera").displayName, "Libera")
    }

    // MARK: - Config rows

    private static let row = ##"""
    {"networks":[{
      "id":4,"name":"Libera","host":"irc.libera.chat","port":6697,"tls":true,
      "trusted_certificates":false,"nick":"me","username":"meuser","realname":"Me",
      "autoconnect":true,"sasl_account":"me","connect_commands":"/msg NickServ help",
      "has_password":true,"has_sasl_password":true,"blocked":true
    }]}
    """##

    func testAConfigRowReadsEveryFieldTheFormEdits() {
        let config = FrameParser.parseNetworkConfigs(Self.row).first
        XCTAssertEqual(config?.id, 4)
        XCTAssertEqual(config?.name, "Libera")
        XCTAssertEqual(config?.host, "irc.libera.chat")
        XCTAssertEqual(config?.port, 6697)
        XCTAssertEqual(config?.tls, true)
        XCTAssertEqual(config?.trustedCertificates, false)
        XCTAssertEqual(config?.nick, "me")
        XCTAssertEqual(config?.username, "meuser")
        XCTAssertEqual(config?.realname, "Me")
        XCTAssertEqual(config?.autoconnect, true)
        XCTAssertEqual(config?.saslAccount, "me")
        XCTAssertEqual(config?.connectCommands, "/msg NickServ help")
        XCTAssertEqual(config?.hasPassword, true)
        XCTAssertEqual(config?.hasSaslPassword, true)
        XCTAssertEqual(config?.blocked, true)
    }

    func testAnAbsentBlockedFlagReadsAsNotBlocked() {
        // A server predating the admin allowlist (#298) sends no `blocked`. It has no
        // allowlist to be excluded from, so defaulting the other way would grey out every
        // network on every older server.
        let config = FrameParser.parseNetworkConfigs(##"{"networks":[{"id":1,"name":"n","host":"h"}]}"##).first
        XCTAssertEqual(config?.blocked, false)
    }

    func testAMissingPortFallsBackToTheServersDefault() {
        // `int()` reads an absent port as 0, which is not a port anything can connect to.
        let config = FrameParser.parseNetworkConfigs(##"{"networks":[{"id":1,"name":"n","host":"h"}]}"##).first
        XCTAssertEqual(config?.port, 6697)
    }

    func testAnUnreadableBodyIsNoRowsRatherThanACrash() {
        XCTAssertTrue(FrameParser.parseNetworkConfigs("not json").isEmpty)
        XCTAssertNil(FrameParser.parseNetworkReply("not json"))
    }

    func testACreateReplyCarriesTheSavedRow() {
        let config = FrameParser.parseNetworkReply(##"{"network":{"id":9,"name":"OFTC","host":"irc.oftc.net","port":6697,"tls":true,"nick":"me"}}"##)
        XCTAssertEqual(config?.id, 9)
        XCTAssertEqual(config?.name, "OFTC")
    }

    // MARK: - Request bodies

    private func draft() -> NetworkDraft {
        NetworkDraft(name: "Libera", host: "irc.libera.chat", port: 6697, tls: true, nick: "me")
    }

    func testAnUnchangedSecretIsNotSentAtAll() {
        // ⚠⚠ The reason `SecretEdit` exists. The API never returns a password, so an empty
        // field is both "leave it alone" and "remove it"; sending the field's contents on
        // every save would clear a password the user never touched. Omitted key = untouched
        // column, because the server patches only what it is given.
        let body = draft().jsonBody(includeDefaultChannel: false)
        XCTAssertNil(body["server_password"])
        XCTAssertNil(body["sasl_password"])
    }

    func testAClearedSecretSendsAnExplicitNull() {
        var d = draft()
        d.password = .cleared
        let body = d.jsonBody(includeDefaultChannel: false)
        XCTAssertTrue(body["server_password"] is NSNull)
    }

    func testASetSecretSendsTheValue() {
        var d = draft()
        d.saslPassword = .set("hunter2")
        XCTAssertEqual(d.jsonBody(includeDefaultChannel: false)["sasl_password"] as? String, "hunter2")
    }

    func testDefaultChannelsRideOnCreateOnly() {
        var d = draft()
        d.defaultChannel = "#lurker,#libera"
        XCTAssertEqual(d.jsonBody(includeDefaultChannel: true)["default_channel"] as? String, "#lurker,#libera")
        XCTAssertNil(d.jsonBody(includeDefaultChannel: false)["default_channel"])
    }

    func testEmptyOptionalTextIsNullRatherThanEmpty() {
        // The columns are nullable and the server derives username/realname from the nick when
        // they are null. An empty string is a real value and would defeat that.
        var d = draft()
        d.username = ""
        d.realname = nil
        let body = d.jsonBody(includeDefaultChannel: true)
        XCTAssertTrue(body["username"] is NSNull)
        XCTAssertTrue(body["realname"] is NSNull)
    }

    func testTheBodyIsEncodable() {
        // Everything here goes through JSONSerialization, which throws on a value it doesn't
        // know. NSNull is fine; a Swift `nil` in an `Any` is not, which is why the optional
        // fields are written out explicitly.
        var d = draft()
        d.password = .cleared
        d.defaultChannel = "#lurker"
        XCTAssertTrue(JSONSerialization.isValidJSONObject(d.jsonBody(includeDefaultChannel: true)))
    }

    func testEditingADraftStartsBothSecretsUnchanged() {
        // The values were never sent to us. Anything but `unchanged` would be a guess, and the
        // guess that loses a password is the one that costs the user their connection.
        let config = FrameParser.parseNetworkConfigs(Self.row).first!
        let d = NetworkDraft(editing: config)
        XCTAssertEqual(d.password, .unchanged)
        XCTAssertEqual(d.saslPassword, .unchanged)
        XCTAssertEqual(d.name, "Libera")
        XCTAssertEqual(d.host, "irc.libera.chat")
        XCTAssertEqual(d.nick, "me")
        // Create-only, and this draft is for an edit.
        XCTAssertNil(d.defaultChannel)
    }
}

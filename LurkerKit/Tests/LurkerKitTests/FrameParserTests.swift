// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the parser to the real wire contract (mapped from the server source):
/// flat-spread `irc` events, `events:[] + hasMoreOlder:true` shells, names living only
/// in the REST roster, etc. Ported from the Android client's FrameParserTest.
final class FrameParserTests: XCTestCase {

    func testChannelBacklogShellParsesAsUnhydratedWithNoMessages() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":true,"joined":true,"unread":3,"lastReadId":42}"##
        )
        guard case let .backlog(buffer, messages, hydrated, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertFalse(hydrated, "events:[] + hasMoreOlder:true is a shell")
        XCTAssertEqual(messages.count, 0)
        XCTAssertEqual(buffer.kind, .channel)
        XCTAssertEqual(buffer.unread, 3)
        XCTAssertEqual(buffer.lastReadId, 42)
    }

    func testHydratedBacklogParsesItsEvents() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":1,"type":"message","nick":"alice","text":"hi","self":false},{"id":2,"type":"action","nick":"bob","text":"waves","self":true}]}"##
        )
        guard case let .backlog(_, messages, hydrated, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertTrue(hydrated)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].type, .message)
        XCTAssertEqual(messages[0].text, "hi")
        XCTAssertEqual(messages[1].type, .action)
        XCTAssertTrue(messages[1].isSelf)
    }

    func testLiveIrcFrameReadsTheEventSpreadFlatOnTheFrame() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","id":7,"networkId":1,"target":"#lurker","type":"message","nick":"carol","text":"yo","self":false,"matched":true}"##
        )
        guard case let .live(networkId, target, message) = frame else {
            return XCTFail("expected live, got \(frame)")
        }
        XCTAssertEqual(networkId, 1)
        XCTAssertEqual(target, "#lurker")
        XCTAssertEqual(message.id, 7)
        XCTAssertEqual(message.nick, "carol")
        XCTAssertTrue(message.matched)
    }

    func testSnapshotParsesNetworksChannelsAndMembersButNoName() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":1,"state":"connected","nick":"me","channels":[{"name":"#lurker","topic":"hi","members":[{"nick":"alice","modes":["o"],"away":false},{"nick":"bob","modes":[],"away":true}]}]}]}"##
        )
        guard case let .snapshot(networks) = frame else {
            return XCTFail("expected snapshot, got \(frame)")
        }
        XCTAssertEqual(networks.count, 1)
        let network = networks[0]
        XCTAssertEqual(network.id, 1)
        XCTAssertEqual(network.state, .connected)
        XCTAssertEqual(network.nick, "me")
        let channel = network.channels[0]
        XCTAssertEqual(channel.name, "#lurker")
        XCTAssertEqual(channel.members.map(\.nick), ["alice", "bob"])
        XCTAssertEqual(channel.members[0].modes, ["o"])
        XCTAssertTrue(channel.members[1].away)
    }

    func testResumeSliceWithResetFalseIsAnAppend() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","reset":false,"hasMoreOlder":false,"events":[{"id":5,"type":"message","nick":"a","text":"x"}]}"##
        )
        guard case let .backlog(_, _, hydrated, append) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertTrue(hydrated)
        XCTAssertTrue(append, "reset:false gap → append")
    }

    func testResumeSliceWithResetTrueReplaces() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","reset":true,"hasMoreOlder":false,"events":[{"id":5,"type":"message","nick":"a","text":"x"}]}"##
        )
        guard case let .backlog(_, _, _, append) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertFalse(append, "reset:true → replace")
    }

    func testFullBacklogWithNoResetFieldReplaces() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":5,"type":"message","nick":"a","text":"x"}]}"##
        )
        guard case let .backlog(_, _, _, append) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertFalse(append, "absent reset → replace, not append")
    }

    func testHistoryBeforePageParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"history","networkId":1,"target":"#lurker","mode":"before","hasMoreOlder":true,"hasMoreNewer":false,"events":[{"id":10,"type":"message","nick":"a","text":"old"}]}"##
        )
        guard case let .history(networkId, target, events, mode, hasMoreOlder, hasMoreNewer) = frame else {
            return XCTFail("expected history, got \(frame)")
        }
        XCTAssertEqual(networkId, 1)
        XCTAssertEqual(target, "#lurker")
        XCTAssertEqual(mode, .before)
        XCTAssertEqual(events.map(\.text), ["old"])
        XCTAssertTrue(hasMoreOlder)
        XCTAssertFalse(hasMoreNewer)
    }

    func testHistoryHasMoreFallsBackToLegacyAlias() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"history","networkId":1,"target":"#lurker","mode":"before","hasMore":true,"events":[]}"##
        )
        guard case let .history(_, _, _, _, hasMoreOlder, _) = frame else {
            return XCTFail("expected history, got \(frame)")
        }
        XCTAssertTrue(hasMoreOlder, "hasMore is the legacy alias for hasMoreOlder")
    }

    func testSendResultCarriesClientIdOkAndError() {
        let frame = FrameParser.parseWs(##"{"kind":"send-result","clientId":"c1","ok":false,"error":"unknown-network"}"##)
        guard case let .sendResult(clientId, ok, error) = frame else {
            return XCTFail("expected sendResult, got \(frame)")
        }
        XCTAssertEqual(clientId, "c1")
        XCTAssertFalse(ok)
        XCTAssertEqual(error, "unknown-network")
    }

    func testRestNetworksParseIdAndName() {
        let frame = FrameParser.parseNetworks(##"{"networks":[{"id":1,"name":"Libera"},{"id":2,"name":"OFTC"}]}"##)
        guard case let .networks(networks) = frame else {
            return XCTFail("expected networks, got \(frame)")
        }
        XCTAssertEqual(networks.map(\.id), [1, 2])
        XCTAssertEqual(networks.map(\.name), ["Libera", "OFTC"])
    }

    func testAnUnknownFrameKindIsIgnoredNotAnError() {
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"draft-snapshot","drafts":{}}"##), .ignored)
        XCTAssertEqual(FrameParser.parseWs("not json at all"), .ignored)
    }

    func testTheSystemBufferIsClassifiedAsSystemNotADm() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":null,"target":":system:","hasMoreOlder":false,"events":[]}"##
        )
        guard case let .backlog(buffer, _, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertEqual(buffer.kind, .system)
        XCTAssertNil(buffer.networkId)
    }
}

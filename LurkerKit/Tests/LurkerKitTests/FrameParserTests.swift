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

    /// The server's `extractExtras` spreads one structured field onto each structural event
    /// — `newNick` on nick, `kicked` on kick, `invited` on invite, `modes` on mode. The
    /// renderer needs these to synthesize "bob is now bob_afk" etc., so the parser must lift
    /// them off the flat frame.
    func testStructuralEventsParseTheirExtraFields() {
        guard case let .live(_, _, nick) = FrameParser.parseWs(
            ##"{"kind":"irc","id":1,"networkId":1,"target":"#lurker","type":"nick","nick":"bob","newNick":"bob_afk"}"##
        ) else { return XCTFail("expected live nick event") }
        XCTAssertEqual(nick.newNick, "bob_afk")

        guard case let .live(_, _, kick) = FrameParser.parseWs(
            ##"{"kind":"irc","id":2,"networkId":1,"target":"#lurker","type":"kick","nick":"op","kicked":"troll","text":"bye"}"##
        ) else { return XCTFail("expected live kick event") }
        XCTAssertEqual(kick.kicked, "troll")

        guard case let .live(_, _, invite) = FrameParser.parseWs(
            ##"{"kind":"irc","id":3,"networkId":1,"target":"#lurker","type":"invite","nick":"host","invited":"guest"}"##
        ) else { return XCTFail("expected live invite event") }
        XCTAssertEqual(invite.invited, "guest")

        guard case let .live(_, _, mode) = FrameParser.parseWs(
            ##"{"kind":"irc","id":4,"networkId":1,"target":"#lurker","type":"mode","nick":"chan","text":"+o alice","modes":[{"mode":"+o","param":"alice"}]}"##
        ) else { return XCTFail("expected live mode event") }
        XCTAssertEqual(mode.modes.count, 1)
        XCTAssertEqual(mode.modes.first?.mode, "+o")
        XCTAssertEqual(mode.modes.first?.param, "alice")
    }

    /// `channel-topic` rides `kind:"irc"` like an event, but it isn't one: no id, nothing
    /// to render, and its payload is in `topic` rather than `text`. Parsed as an event it
    /// would become an `.other` Message appended to the buffer with the topic in a field
    /// nothing reads.
    func testChannelTopicIsLiftedOutOfIrcRatherThanParsedAsAnEvent() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"channel-topic","topic":"welcome all"}"##
        )
        guard case let .channelTopic(networkId, target, topic) = frame else {
            return XCTFail("expected channelTopic, got \(frame)")
        }
        XCTAssertEqual(networkId, 1)
        XCTAssertEqual(target, "#lurker")
        XCTAssertEqual(topic, "welcome all")
    }

    func testAClearedChannelTopicParsesAsNilNotEmptyString() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"channel-topic"}"##
        )
        guard case let .channelTopic(_, _, topic) = frame else {
            return XCTFail("expected channelTopic, got \(frame)")
        }
        XCTAssertNil(topic)
    }

    /// `names` is lifted out of `irc` for the same reason as `channel-topic`: state, not
    /// a line, with its payload in `members` where `parseEvent` never looks.
    func testANamesEventParsesToChannelMembersNotALine() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"names","members":[{"nick":"alice","modes":["o"],"away":false,"user":"al","host":"example.org"},{"nick":"bob","modes":[],"away":true}]}"##
        )
        guard case let .channelMembers(networkId, target, members) = frame else {
            return XCTFail("expected channelMembers, got \(frame)")
        }
        XCTAssertEqual(networkId, 1)
        XCTAssertEqual(target, "#lurker")
        XCTAssertEqual(members.map(\.nick), ["alice", "bob"])
        XCTAssertEqual(members[0].modes, ["o"])
        XCTAssertEqual(members[0].host, "example.org")
        XCTAssertTrue(members[1].away)
    }

    func testAMemberUpdateParsesItsMemberSnapshot() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"member-update","member":{"nick":"bob","modes":["v"],"away":true,"user":"rob","host":"new.example.org"}}"##
        )
        guard case let .memberUpdate(networkId, target, member) = frame else {
            return XCTFail("expected memberUpdate, got \(frame)")
        }
        XCTAssertEqual(networkId, 1)
        XCTAssertEqual(target, "#lurker")
        XCTAssertEqual(member.nick, "bob")
        XCTAssertEqual(member.modes, ["v"])
        XCTAssertTrue(member.away)
        XCTAssertEqual(member.host, "new.example.org")
    }

    func testAMemberUpdateWithoutANickIsIgnoredNotAppliedToNobody() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","networkId":1,"target":"#lurker","type":"member-update","member":{"away":true}}"##
        )
        guard case .ignored = frame else {
            return XCTFail("expected ignored, got \(frame)")
        }
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

    func testReadStateParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"read-state","networkId":1,"target":"#lurker","lastReadId":42,"unread":3,"highlights":1}"##
        )
        guard case let .readState(networkId, target, lastReadId, unread, highlights) = frame else {
            return XCTFail("expected readState, got \(frame)")
        }
        XCTAssertEqual(networkId, 1)
        XCTAssertEqual(target, "#lurker")
        XCTAssertEqual(lastReadId, 42)
        XCTAssertEqual(unread, 3)
        XCTAssertEqual(highlights, 1)
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

    func testHighlightsPageParsesItemsWithBufferAddressAndCursor() {
        let page = FrameParser.parseHighlights(##"""
        {"items":[
          {"id":91,"networkId":1,"target":"#lurker","networkName":"Libera","type":"message","nick":"alice","text":"hey @you","self":false,"matched":true,"time":"2026-07-22T20:00:00.000Z"},
          {"id":88,"networkId":2,"target":"bob","networkName":"OFTC","type":"message","nick":"bob","text":"ping","self":false,"matched":true}
        ],"nextBefore":88}
        """##)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].message.id, 91)
        XCTAssertEqual(page.items[0].message.nick, "alice")
        XCTAssertEqual(page.items[0].message.text, "hey @you")
        XCTAssertTrue(page.items[0].message.matched)
        XCTAssertNotNil(page.items[0].message.date, "the ISO time is parsed at the wire boundary")
        XCTAssertEqual(page.items[0].networkId, 1)
        XCTAssertEqual(page.items[0].target, "#lurker")
        XCTAssertEqual(page.items[0].networkName, "Libera")
        XCTAssertEqual(page.items[0].bufferKey, BufferKey(networkId: 1, target: "#lurker"))
        // A DM highlight resolves its buffer the same way, keyed on the nick target.
        XCTAssertEqual(page.items[1].bufferKey, BufferKey(networkId: 2, target: "bob"))
        XCTAssertEqual(page.nextBefore, 88)
        XCTAssertTrue(page.hasMore)
    }

    func testHighlightsLastPageHasNoCursor() {
        // The server drops `nextBefore` (null) once a page doesn't fill the limit — that's
        // the end signal, and it must read as "no more" rather than a cursor of 0.
        let page = FrameParser.parseHighlights(##"{"items":[{"id":5,"networkId":1,"target":"#c","type":"message","nick":"a","text":"hi"}],"nextBefore":null}"##)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertNil(page.nextBefore)
        XCTAssertFalse(page.hasMore)
    }

    func testHighlightsMalformedBodyIsAnEmptyPageNotACrash() {
        let page = FrameParser.parseHighlights("not json")
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextBefore)
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

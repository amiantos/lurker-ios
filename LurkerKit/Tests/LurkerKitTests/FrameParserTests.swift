// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the parser to the real wire contract (mapped from the server source):
/// flat-spread `irc` events, `events:[] + hasMoreOlder:true` shells, names living only
/// in the REST roster, etc. Ported from the Android client's FrameParserTest.
final class FrameParserTests: XCTestCase {

    func testBufferClosedParses() {
        let frame = FrameParser.parseWs(##"{"kind":"buffer-closed","networkId":1,"target":"#lurker"}"##)
        XCTAssertEqual(frame, .bufferClosed(networkId: 1, target: "#lurker"))
    }

    func testBufferClosedKeepsANullNetworkIdNullRatherThanFoldingItToZero() {
        // The system buffer's networkId is genuinely null, and BufferKey distinguishes null
        // from network 0 — reading this with a 0 default would key the wrong buffer.
        let frame = FrameParser.parseWs(##"{"kind":"buffer-closed","networkId":null,"target":":system:"}"##)
        XCTAssertEqual(frame, .bufferClosed(networkId: nil, target: ":system:"))
    }

    func testBufferClosedWithoutATargetIsIgnored() {
        // Nothing to key on — dropping beats removing an arbitrary buffer.
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"buffer-closed","networkId":1}"##), .ignored)
    }

    func testBufferRenamedParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"buffer-renamed","networkId":1,"bufferId":7,"from":"alice","to":"alice2","merged":false}"##
        )
        XCTAssertEqual(
            frame,
            .bufferRenamed(
                networkId: 1, from: "alice", to: "alice2", bufferId: 7,
                merged: false, mergedFromBufferId: nil
            )
        )
    }

    func testBufferRenamedMergeCarriesTheAbsorbedBufferId() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"buffer-renamed","networkId":1,"bufferId":7,"from":"alice","to":"alice_away","merged":true,"mergedFromBufferId":9}"##
        )
        XCTAssertEqual(
            frame,
            .bufferRenamed(
                networkId: 1, from: "alice", to: "alice_away", bufferId: 7,
                merged: true, mergedFromBufferId: 9
            )
        )
    }

    func testBufferRenamedWithoutBothNamesIsIgnored() {
        // Same posture as buffer-closed: an empty name can't identify anything, and
        // renaming an arbitrary buffer is worse than dropping the frame.
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"buffer-renamed","networkId":1,"to":"alice2"}"##),
            .ignored
        )
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"buffer-renamed","networkId":1,"from":"alice"}"##),
            .ignored
        )
    }

    func testBacklogCarriesTheBufferIdWhenTheServerStatesOne() {
        // The connect burst doubles as the id⇄name directory (§5.2).
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","bufferId":12,"events":[],"hasMoreOlder":true}"##
        )
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertEqual(buffer.bufferId, 12)
    }

    func testBacklogWithoutABufferIdLeavesItNilNotZero() {
        // A pre-id server sends no field; 0 would collide with nothing today and
        // something eventually. Absent must parse as absent.
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":true}"##
        )
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertNil(buffer.bufferId)
    }

    func testChannelBacklogShellParsesAsUnhydratedWithNoMessages() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":true,"joined":true,"unread":3,"lastReadId":42}"##
        )
        guard case let .backlog(buffer, messages, hydrated, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertFalse(hydrated, "events:[] + hasMoreOlder:true is a shell")
        XCTAssertEqual(messages.count, 0)
        XCTAssertEqual(buffer.kind, .channel)
        XCTAssertEqual(buffer.unread, 3)
        XCTAssertEqual(buffer.lastReadId, 42)
        XCTAssertTrue(buffer.readStateKnown, "the frame carried a pointer, so it stated one")
    }

    /// ⚠ Read from the FIELD'S PRESENCE, never its value: `int()` reads a missing `lastReadId`
    /// as 0, and 0 is also a legitimate "this buffer has been read up to nothing". A frame that
    /// never mentioned the pointer must not be able to claim it stated one — a screen latching
    /// its unread divider from that 0 loses the divider for good.
    func testABacklogWithNoPointerStatesNoReadState() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":true,"joined":true}"##
        )
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertEqual(buffer.lastReadId, 0, "absent parses as 0…")
        XCTAssertFalse(buffer.readStateKnown, "…but that 0 is the default, not a statement")
    }

    /// And a pointer of 0 that the server actually sent IS a statement — the distinction the
    /// value alone can't carry.
    func testAnExplicitZeroPointerCounts() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":true,"lastReadId":0}"##
        )
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertEqual(buffer.lastReadId, 0)
        XCTAssertTrue(buffer.readStateKnown, "the server said 0; that's an answer")
    }

    func testHydratedBacklogParsesItsEvents() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":1,"type":"message","nick":"alice","text":"hi","self":false},{"id":2,"type":"action","nick":"bob","text":"waves","self":true}]}"##
        )
        guard case let .backlog(_, messages, hydrated, _, _) = frame else {
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

        guard case let .live(_, _, chghost) = FrameParser.parseWs(
            ##"{"kind":"irc","id":5,"networkId":1,"target":"#lurker","type":"chghost","nick":"bob","userhost":"bob!old@old.host","newIdent":"~new","newHost":"new.host"}"##
        ) else { return XCTFail("expected live chghost event") }
        XCTAssertEqual(chghost.type, .chghost, "chghost must not fold to .other — it renders nowhere there")
        XCTAssertEqual(chghost.chghostMask, "~new@new.host")
        XCTAssertEqual(chghost.userhost, "bob!old@old.host", "the mask before the change")
        XCTAssertTrue(chghost.isRenderable)

        guard case let .live(_, _, join) = FrameParser.parseWs(
            ##"{"kind":"irc","id":6,"networkId":1,"target":"#lurker","type":"join","nick":"bob","userhost":"bob!u@h","account":"bobby"}"##
        ) else { return XCTFail("expected live join event") }
        XCTAssertEqual(join.account, "bobby")
        XCTAssertEqual(join.userhost, "bob!u@h")
    }

    /// A logged-out user's extended-join account is the `*` sentinel, which the server stores
    /// as null and omits — so it must read as "nothing to show", not as an account named `*`.
    func testAJoinWithoutAnAccountCarriesNone() {
        guard case let .live(_, _, join) = FrameParser.parseWs(
            ##"{"kind":"irc","id":1,"networkId":1,"target":"#lurker","type":"join","nick":"bob"}"##
        ) else { return XCTFail("expected live join event") }
        XCTAssertNil(join.account)
        XCTAssertNil(join.userhost)
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
        guard case let .snapshot(networks, _) = frame else {
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
        guard case let .backlog(_, _, hydrated, append, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertTrue(hydrated)
        XCTAssertTrue(append, "reset:false gap → append")
    }

    func testResumeSliceWithResetTrueReplaces() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","reset":true,"hasMoreOlder":false,"events":[{"id":5,"type":"message","nick":"a","text":"x"}]}"##
        )
        guard case let .backlog(_, _, _, append, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertFalse(append, "reset:true → replace")
    }

    func testFullBacklogWithNoResetFieldReplaces() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":5,"type":"message","nick":"a","text":"x"}]}"##
        )
        guard case let .backlog(_, _, _, append, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertFalse(append, "absent reset → replace, not append")
    }

    func testHistoryBeforePageParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"history","networkId":1,"target":"#lurker","mode":"before","hasMoreOlder":true,"hasMoreNewer":false,"events":[{"id":10,"type":"message","nick":"a","text":"old"}]}"##
        )
        guard case let .history(networkId, target, events, mode, hasMoreOlder, hasMoreNewer, _)
            = frame
        else {
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
        guard case let .history(_, _, _, _, hasMoreOlder, _, _) = frame else {
            return XCTFail("expected history, got \(frame)")
        }
        XCTAssertTrue(hasMoreOlder, "hasMore is the legacy alias for hasMoreOlder")
    }

    // MARK: - Speakers (#63)

    /// `lastTime` is epoch milliseconds, not the ISO string every other timestamp on the wire
    /// uses — so this is the one field where reading it like the others would be off by three
    /// orders of magnitude and read as 1970.
    func testSpeakersParseFromEpochMilliseconds() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"history","networkId":1,"target":"#lurker","mode":"latest","events":[],"speakers":[{"nick":"Alice","lastTime":1784548800000}]}"##
        )
        guard case let .history(_, _, _, _, _, _, speakers) = frame else {
            return XCTFail("expected history, got \(frame)")
        }
        XCTAssertEqual(speakers?.count, 1)
        XCTAssertEqual(speakers?.first?.nick, "Alice", "the server's casing survives")
        XCTAssertEqual(speakers?.first?.lastSpoke, Date(timeIntervalSince1970: 1_784_548_800))
    }

    /// Absent and empty are different answers, and the store acts on the difference: a shell
    /// omits the field so a re-snapshot can't wipe what the client already knows, while an empty
    /// list is the server saying nobody has spoken here.
    func testAnAbsentSpeakersFieldIsNilAndAnEmptyOneIsEmpty() {
        let absent = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"hasMoreOlder":true}"##
        )
        guard case let .backlog(_, _, _, _, absentSpeakers) = absent else {
            return XCTFail("expected backlog, got \(absent)")
        }
        XCTAssertNil(absentSpeakers)

        let empty = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"speakers":[]}"##
        )
        guard case let .backlog(_, _, _, _, emptySpeakers) = empty else {
            return XCTFail("expected backlog, got \(empty)")
        }
        XCTAssertEqual(emptySpeakers, [])
    }

    /// A half-filled entry is dropped rather than defaulted: a speaker stamped at the epoch
    /// reads as infinitely stale, which is the same as being absent but harder to notice.
    func testIncompleteSpeakerEntriesAreDropped() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","events":[],"speakers":[{"nick":"","lastTime":1784548800000},{"nick":"bob"},{"nick":"carol","lastTime":0},{"nick":"dave","lastTime":1784548800000}]}"##
        )
        guard case let .backlog(_, _, _, _, speakers) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertEqual(speakers?.map(\.nick), ["dave"])
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
        guard case let .backlog(buffer, _, _, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertEqual(buffer.kind, .system)
        XCTAssertNil(buffer.networkId)
    }

    // MARK: - Bookmarks

    /// `bookmarked` rides on the message rows in a BACKLOG — that's the path that matters,
    /// since it's the only way the client learns about a save it didn't witness now that the
    /// connect burst carries no bookmark snapshot. (A live message has just arrived, so it is
    /// never already saved.)
    ///
    /// Asserted together with an unsaved row in the same page: absent means unsaved, because
    /// the server omits the field rather than sending false — nearly every row in every
    /// backlog is unsaved, and a false on each is pure wire weight.
    func testBookmarkedFlagParsesOffBacklogRows() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"backlog","networkId":1,"target":"#lurker","hasMoreOlder":false,"events":[{"id":1,"type":"message","nick":"a","text":"plain"},{"id":2,"type":"message","nick":"a","text":"kept","bookmarked":true}]}"##
        )
        guard case let .backlog(_, messages, _, _, _) = frame else {
            return XCTFail("expected backlog, got \(frame)")
        }
        XCTAssertFalse(messages[0].bookmarked, "absent reads as unsaved")
        XCTAssertTrue(messages[1].bookmarked)
    }

    func testBookmarkUpdatedParsesBothDirections() {
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"bookmark-updated","messageId":42,"saved":true}"##),
            .bookmarkUpdated(messageId: 42, saved: true)
        )
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"bookmark-updated","messageId":42,"saved":false}"##),
            .bookmarkUpdated(messageId: 42, saved: false)
        )
    }

    /// A zero/missing id can't address a row, so it's dropped rather than folded into the set
    /// where it would sit forever as a phantom bookmark.
    func testBookmarkUpdatedWithoutAnIdIsIgnored() {
        XCTAssertEqual(FrameParser.parseWs(##"{"kind":"bookmark-updated","saved":true}"##), .ignored)
    }

    // MARK: - search-result

    /// Rows arrive under `results` (not `items`, the REST feeds' key) but in the same shape,
    /// carrying their own buffer address because a match can come from anywhere.
    func testSearchResultParsesRowsWithTheirBufferAddress() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"search-result","token":7,"hasMore":false,"results":[
          {"id":91,"type":"message","nick":"alice","text":"needle","time":"2026-07-01T10:00:00.000Z",
           "networkId":1,"target":"#dev","networkName":"libera"}
        ]}
        """##)
        guard case let .searchResult(token, page) = frame else {
            return XCTFail("expected searchResult, got \(frame)")
        }
        XCTAssertEqual(token, 7)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].message.text, "needle")
        XCTAssertEqual(page.items[0].target, "#dev")
        XCTAssertEqual(page.items[0].networkName, "libera")
        XCTAssertEqual(page.items[0].networkId, 1)
    }

    /// Search answers `hasMore` and no cursor — the cursor is the last (oldest) row's id,
    /// since matches come back newest-first by message id. Synthesizing it here is what lets a
    /// search page through the same feed screen as highlights and bookmarks.
    func testSearchResultDerivesTheNextCursorFromTheLastRow() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"search-result","token":1,"hasMore":true,"results":[
          {"id":91,"type":"message","target":"#dev","networkId":1},
          {"id":40,"type":"message","target":"#dev","networkId":1}
        ]}
        """##)
        guard case let .searchResult(_, page) = frame else {
            return XCTFail("expected searchResult, got \(frame)")
        }
        XCTAssertEqual(page.nextBefore, 40)
        XCTAssertTrue(page.hasMore)
    }

    func testSearchResultWithoutMoreHasNoCursor() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"search-result","token":1,"hasMore":false,"results":[{"id":91,"target":"#dev","networkId":1}]}"##
        )
        guard case let .searchResult(_, page) = frame else {
            return XCTFail("expected searchResult, got \(frame)")
        }
        XCTAssertNil(page.nextBefore)
        XCTAssertFalse(page.hasMore)
    }

    /// `hasMore` with nothing to page from is not more: there is no id to send as `before`, so
    /// claiming another page would leave the list asking for one it can't address.
    func testSearchResultWithMoreButNoRowsHasNoCursor() {
        let frame = FrameParser.parseWs(##"{"kind":"search-result","token":1,"hasMore":true,"results":[]}"##)
        guard case let .searchResult(_, page) = frame else {
            return XCTFail("expected searchResult, got \(frame)")
        }
        XCTAssertNil(page.nextBefore)
        XCTAssertTrue(page.items.isEmpty)
    }

    /// An empty result set is a real answer ("nothing matched"), not a parse failure — the
    /// screen shows a different thing for each, so the two must not collapse.
    func testSearchResultWithNoMatchesIsAnEmptyPageNotIgnored() {
        let frame = FrameParser.parseWs(##"{"kind":"search-result","token":3,"hasMore":false,"results":[]}"##)
        XCTAssertEqual(frame, .searchResult(token: 3, page: HighlightsPage(items: [], nextBefore: nil)))
    }

    /// A reply with no token can't be matched to the call waiting for it. Read with `int()` it
    /// would become token 0 — a value no request ever carries, so the frame would be consumed
    /// as a `.searchResult` and correlate to nothing.
    func testSearchResultWithoutATokenIsIgnored() {
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"search-result","hasMore":false,"results":[]}"##),
            .ignored
        )
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"search-result","token":null,"hasMore":false,"results":[]}"##),
            .ignored
        )
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Whois and nick notes end to end (#12): the wire in, the types they build, what the store
/// does with them, and the in-flight bookkeeping that decides whether a lookup can be retried.
///
/// The marker rules are ported from the web's `stores/whois.test.ts` rather than invented —
/// each was a shipped bug (lurker#818) before it was a rule, and each fails differently.
@MainActor
final class WhoisTests: XCTestCase {

    /// Its own Keychain service and its own defaults suite, so nothing here touches the app's.
    private func viewModel() -> ChatViewModel {
        ChatViewModel(
            sessions: SessionStore(service: "chat.lurker.tests.whois"),
            settingsCache: SettingsCache(defaults: UserDefaults(suiteName: "chat.lurker.tests.whois")!)
        )
    }

    // MARK: - The payload

    func testParsesTheFullReplyUsingIrcFrameworksFieldNames() {
        // Field-for-field the object irc-framework assembles and `ircConnection.ts` forwards
        // untouched. `real_name`, `actual_ip`, `server_info` and `registered_nick` are its
        // spellings, and this is the only place that should know them.
        let frame = FrameParser.parseWs(##"""
        {"kind":"irc","type":"whois_result","networkId":7,"whois":{
          "nick":"Alice","ident":"~alice","hostname":"example.org","real_name":"Alice A",
          "actual_hostname":"gateway.example.org","actual_ip":"198.51.100.4",
          "server":"irc.example.org","server_info":"Example Network","account":"alice",
          "channels":"@#foo +#bar","modes":"+iw","operator":"is an IRC Operator",
          "helpop":"is available for help","bot":"is a bot","registered_nick":"is identified",
          "secure":true,"certfp":"abc123","away":"back later","idle":"345","logon":"1700000000"}}
        """##)
        guard case let .whoisResult(networkId, whois) = frame else {
            return XCTFail("expected a whoisResult, got \(frame)")
        }
        XCTAssertEqual(networkId, 7)
        XCTAssertEqual(whois.nick, "Alice")
        XCTAssertEqual(whois.ident, "~alice")
        XCTAssertEqual(whois.hostname, "example.org")
        XCTAssertEqual(whois.realName, "Alice A")
        XCTAssertEqual(whois.actualHostname, "gateway.example.org")
        XCTAssertEqual(whois.actualIP, "198.51.100.4")
        XCTAssertEqual(whois.server, "irc.example.org")
        XCTAssertEqual(whois.serverInfo, "Example Network")
        XCTAssertEqual(whois.account, "alice")
        XCTAssertEqual(whois.modes, "+iw")
        XCTAssertEqual(whois.isOperator, "is an IRC Operator")
        XCTAssertEqual(whois.helpop, "is available for help")
        XCTAssertEqual(whois.bot, "is a bot")
        XCTAssertEqual(whois.registeredNick, "is identified")
        XCTAssertTrue(whois.isSecure)
        XCTAssertEqual(whois.certfp, "abc123")
        XCTAssertEqual(whois.away, "back later")
        XCTAssertFalse(whois.isNotFound)
    }

    func testIdleAndSignonArriveAsStringsBecauseIrcParametersAreText() {
        // ⚠⚠ The regression this locks: irc-framework assigns `idle`/`logon` straight off
        // `command.params` (user.js:238), and IRC parameters are text. A bare `as? Int` reads
        // nil on every real reply, so both rows would silently never render.
        let frame = FrameParser.parseWs(##"""
        {"kind":"irc","type":"whois_result","networkId":1,
         "whois":{"nick":"bob","idle":"345","logon":"1700000000"}}
        """##)
        guard case let .whoisResult(_, whois) = frame else { return XCTFail("expected a whoisResult") }
        XCTAssertEqual(whois.idleSeconds, 345)
        XCTAssertEqual(whois.signedOn, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testIdleAndSignonAlsoAcceptRealJsonNumbers() {
        // A server (or a future irc-framework) that sends them as numbers must work too —
        // the point is that the reader takes either, not that it swapped one guess for another.
        let frame = FrameParser.parseWs(##"""
        {"kind":"irc","type":"whois_result","networkId":1,
         "whois":{"nick":"bob","idle":345,"logon":1700000000}}
        """##)
        guard case let .whoisResult(_, whois) = frame else { return XCTFail("expected a whoisResult") }
        XCTAssertEqual(whois.idleSeconds, 345)
        XCTAssertEqual(whois.signedOn, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testAnAbsentSignonIsNilRatherThanTheEpoch() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","type":"whois_result","networkId":1,"whois":{"nick":"bob"}}"##
        )
        guard case let .whoisResult(_, whois) = frame else { return XCTFail("expected a whoisResult") }
        // 1970 is plausible-looking and wrong; a missing row simply doesn't draw.
        XCTAssertNil(whois.signedOn)
        XCTAssertNil(whois.idleSeconds)
    }

    func testTheNotFoundMissIsAnOrdinaryReplyCarryingAnError() {
        // ⚠⚠ This does NOT come from ERR_NOSUCHNICK — that numeric produces no whois event at
        // all. irc-framework synthesizes this at RPL_ENDOFWHOIS when nothing filled the cache,
        // which is why it arrives with a nick and nothing else.
        let frame = FrameParser.parseWs(##"""
        {"kind":"irc","type":"whois_result","networkId":1,
         "whois":{"nick":"ghost","error":"not_found"}}
        """##)
        guard case let .whoisResult(_, whois) = frame else { return XCTFail("expected a whoisResult") }
        XCTAssertTrue(whois.isNotFound)
        XCTAssertEqual(whois.nick, "ghost")
    }

    func testHostmaskFillsAMissingHalfWithAStarAndIsNilWithNeither() {
        XCTAssertEqual(
            WhoisResult(nick: "bob", ident: "~bob", hostname: "example.org").hostmask,
            "bob!~bob@example.org"
        )
        // Unlike `Member.userhost`, which is fed to the matcher and must refuse a half-mask,
        // this one is for display, where "we know the host but not the ident" is worth showing.
        XCTAssertEqual(WhoisResult(nick: "bob", hostname: "example.org").hostmask, "bob!*@example.org")
        XCTAssertEqual(WhoisResult(nick: "bob", ident: "~bob").hostmask, "bob!~bob@*")
        XCTAssertNil(WhoisResult(nick: "bob").hostmask)
    }

    // MARK: - The channels line

    func testChannelsIsOneSpaceSeparatedStringNotAnArray() {
        let whois = WhoisResult(nick: "bob", channelsLine: "@#foo +#bar #baz")
        XCTAssertEqual(whois.channels.map(\.name), ["#foo", "#bar", "#baz"])
        XCTAssertEqual(whois.channels.map(\.prefix), ["@", "+", ""])
    }

    func testAGreedySigilPeelWouldEatTheChannelSigil() {
        // ⚠⚠ The bug the web client has (`UserProfileModal.vue`, `channelsList`): `&` and `+`
        // are membership glyphs AND channel sigils, so a greedy `[~&@%+]*` turns `@&chan` into
        // `chan` — a channel that doesn't exist, offered as something to tap.
        XCTAssertEqual(
            WhoisResult(nick: "bob", channelsLine: "@&chan").channels.map(\.name), ["&chan"]
        )
        XCTAssertEqual(
            WhoisResult(nick: "bob", channelsLine: "@&chan").channels.map(\.prefix), ["@"]
        )
    }

    func testAnUnprefixedChannelKeepsItsOwnSigil() {
        // `&chan` and `+chan` are channels in their own right (RFC 2811 §2.1). Peeling here
        // would leave `chan`, which names nothing.
        for name in ["&chan", "+chan", "!chan", "#chan", "##anime"] {
            let entry = WhoisResult(nick: "bob", channelsLine: name).channels.first
            XCTAssertEqual(entry?.name, name, name)
            XCTAssertEqual(entry?.prefix, "", name)
        }
    }

    func testSplitPrefersTheLargestPeelThatStillLeavesAChannel() {
        // `+#chan` is ambiguous — voiced in `#chan`, or a channel named `+#chan` — and nothing
        // here can tell without ISUPPORT. Preferring the largest legal peel resolves it the way
        // traffic actually runs, and leaves `+chan` (whose peel isn't legal) alone.
        XCTAssertEqual(MemberPrefix.splitChannelToken("+#chan")?.prefix, "+")
        XCTAssertEqual(MemberPrefix.splitChannelToken("+#chan")?.name, "#chan")
        XCTAssertEqual(MemberPrefix.splitChannelToken("+chan")?.prefix, "")
        XCTAssertEqual(MemberPrefix.splitChannelToken("+chan")?.name, "+chan")
        // Two glyphs deep, with a sigil-shaped one in the middle.
        XCTAssertEqual(MemberPrefix.splitChannelToken("~&chan")?.prefix, "~")
        XCTAssertEqual(MemberPrefix.splitChannelToken("~&chan")?.name, "&chan")
    }

    func testASigilOnlyTokenIsDroppedRatherThanBecomingATappableBlank() {
        XCTAssertEqual(WhoisResult(nick: "bob", channelsLine: "@ #real").channels.map(\.name), ["#real"])
        XCTAssertNil(MemberPrefix.splitChannelToken("@"))
        XCTAssertNil(MemberPrefix.splitChannelToken("@@"))
    }

    func testATokenOnAnUnknownChannelTypeIsKeptUnpeeledRatherThanDropped() {
        // No legal peel (nothing left is a channel by this client's CHANTYPES), but a network
        // that uses another one still has real channels there. Showing it unpeeled beats
        // silently hiding it.
        XCTAssertEqual(MemberPrefix.splitChannelToken("chan")?.name, "chan")
        XCTAssertEqual(MemberPrefix.splitChannelToken("chan")?.prefix, "")
    }

    func testAnAbsentChannelsLineIsNoChannels() {
        XCTAssertTrue(WhoisResult(nick: "bob").channels.isEmpty)
    }

    // MARK: - The frame

    func testWhoisResultSurvivesCarryingNoTarget() {
        // ⚠⚠ The regression that made `/whois` do nothing on this client for its whole life:
        // the reply has no `target`, so below `parseIrc`'s target guard it folded to `.other`
        // and was discarded. This asserts it is recognised *above* that guard.
        let frame = FrameParser.parseWs(
            ##"{"kind":"irc","type":"whois_result","networkId":3,"whois":{"nick":"bob"}}"##
        )
        guard case .whoisResult = frame else { return XCTFail("expected a whoisResult, got \(frame)") }
    }

    func testAReplyWeCannotAddressIsRefused() {
        for bad in [
            ##"{"kind":"irc","type":"whois_result","whois":{"nick":"bob"}}"##,
            ##"{"kind":"irc","type":"whois_result","networkId":null,"whois":{"nick":"bob"}}"##,
            ##"{"kind":"irc","type":"whois_result","networkId":1}"##,
            ##"{"kind":"irc","type":"whois_result","networkId":1,"whois":{}}"##,
            ##"{"kind":"irc","type":"whois_result","networkId":1,"whois":{"nick":""}}"##,
        ] {
            XCTAssertEqual(FrameParser.parseWs(bad), .ignored, bad)
        }
    }

    // MARK: - The store

    func testAReplyIsCachedUnderTheServersCasingAndFoundUnderAnyOther() {
        let store = LurkerStore()
        store.apply(.whoisResult(networkId: 1, whois: WhoisResult(nick: "Alice", account: "alice")))
        XCTAssertEqual(store.state.whoisResult(networkId: 1, nick: "ALICE")?.account, "alice")
        XCTAssertEqual(store.state.whoisResult(networkId: 1, nick: "Alice")?.nick, "Alice")
        // Network-scoped, like every other per-nick fact here.
        XCTAssertNil(store.state.whoisResult(networkId: 2, nick: "Alice"))
    }

    func testAReplyFreesTheInFlightSlot() {
        let store = LurkerStore()
        store.markWhoisPending(networkId: 1, nick: "alice")
        XCTAssertTrue(store.state.isWhoisPending(networkId: 1, nick: "alice"))
        store.apply(.whoisResult(networkId: 1, whois: WhoisResult(nick: "Alice")))
        XCTAssertFalse(store.state.isWhoisPending(networkId: 1, nick: "alice"))
    }

    func testANotFoundFreesTheSlotToo() {
        // ⚠⚠ lurker#818 itself. A miss IS an answer; leaving the slot claimed kept the slot
        // held for the session, so reopening that nick declined to retry forever.
        let store = LurkerStore()
        store.markWhoisPending(networkId: 1, nick: "ghost")
        store.apply(.whoisResult(networkId: 1, whois: WhoisResult(nick: "ghost", error: "not_found")))
        XCTAssertFalse(store.state.isWhoisPending(networkId: 1, nick: "ghost"))
        // And the miss is cached, so a screen can render it rather than sitting blank.
        XCTAssertEqual(store.state.whoisResult(networkId: 1, nick: "ghost")?.isNotFound, true)
    }

    func testAReplyForOneNickLeavesAnotherLookupPending() {
        let store = LurkerStore()
        store.markWhoisPending(networkId: 1, nick: "alice")
        store.markWhoisPending(networkId: 1, nick: "bob")
        store.apply(.whoisResult(networkId: 1, whois: WhoisResult(nick: "alice")))
        XCTAssertFalse(store.state.isWhoisPending(networkId: 1, nick: "alice"))
        XCTAssertTrue(store.state.isWhoisPending(networkId: 1, nick: "bob"))
    }

    func testTheSameNickOnTwoNetworksIsTwoLookups() {
        let store = LurkerStore()
        store.markWhoisPending(networkId: 1, nick: "alice")
        store.apply(.whoisResult(networkId: 2, whois: WhoisResult(nick: "alice")))
        XCTAssertTrue(store.state.isWhoisPending(networkId: 1, nick: "alice"))
    }

    func testDroppingANetworkForgetsItsRepliesNotesAndPendingLookups() {
        let store = LurkerStore()
        store.apply(.whoisResult(networkId: 1, whois: WhoisResult(nick: "alice")))
        store.apply(.whoisResult(networkId: 2, whois: WhoisResult(nick: "alice")))
        store.apply(.nickNoteUpdated(networkId: 1, nick: "alice", note: "n1", updatedAt: nil))
        store.apply(.nickNoteUpdated(networkId: 2, nick: "alice", note: "n2", updatedAt: nil))
        store.markWhoisPending(networkId: 1, nick: "bob")
        store.markWhoisPending(networkId: 2, nick: "bob")

        var next = store.state
        next.dropNetwork(1)

        XCTAssertNil(next.whoisResult(networkId: 1, nick: "alice"))
        XCTAssertNil(next.nickNotes.note(networkId: 1, nick: "alice"))
        // Nothing is coming back to free this one — the connection it was asked over is gone.
        XCTAssertFalse(next.isWhoisPending(networkId: 1, nick: "bob"))
        // And the other network is untouched.
        XCTAssertNotNil(next.whoisResult(networkId: 2, nick: "alice"))
        XCTAssertEqual(next.nickNotes.note(networkId: 2, nick: "alice")?.note, "n2")
        XCTAssertTrue(next.isWhoisPending(networkId: 2, nick: "bob"))
    }

    // MARK: - Asking

    func testRequestingAWhoisWithNoSocketClaimsNothing() {
        // ⚠⚠ Rule 2 of the marker (lurker#818): claim only if the WHOIS actually left. A slot
        // held for a request that never went out wedges exactly like one that is never freed —
        // no reply is coming. A fresh view model has no socket, so `sendRaw` returns false.
        let model = viewModel()
        model.requestWhois(networkId: 1, nick: "alice")
        XCTAssertTrue(model.state.whoisPending.isEmpty)
    }

    func testRequestingAWhoisForNobodyDoesNothing() {
        let model = viewModel()
        for nobody in ["", " ", "\n", "   \t "] {
            model.requestWhois(networkId: 1, nick: nobody)
        }
        XCTAssertTrue(model.state.whoisPending.isEmpty)
    }

    func testAPaddedNickIsKeyedTheWayTheServerWillAnswerIt() {
        // ⚠⚠ The reply names the bare nick, so keying the slot on the padded form would free
        // a slot nobody claimed and leave the claimed one held forever — the wedge again,
        // reachable with no malformed input at all. Asserted at the store, since the send that
        // would claim it needs a socket.
        let store = LurkerStore()
        store.markWhoisPending(networkId: 1, nick: "alice")
        store.apply(.whoisResult(networkId: 1, whois: WhoisResult(nick: "alice")))
        XCTAssertTrue(store.state.whoisPending.isEmpty)
        // And the trimmed spelling is what `requestWhois` would have keyed.
        XCTAssertEqual(
            ChatState.whoisKey(networkId: 1, nick: "  Alice  ".trimmingCharacters(in: .whitespacesAndNewlines)),
            ChatState.whoisKey(networkId: 1, nick: "alice")
        )
    }

    func testASocketDropFreesEveryLookupThatWasOutOverIt() {
        // ⚠⚠ The most ordinary route to the wedge: a reconnect between asking and
        // RPL_ENDOFWHOIS. No reply is coming over the socket that closed, so a slot left
        // claimed here would make `requestWhois` refuse that nick for the rest of the session —
        // profile stuck on "waiting…", Refresh inert. `typing` is cleared beside it for the
        // same reason.
        let store = LurkerStore()
        store.markWhoisPending(networkId: 1, nick: "alice")
        store.markWhoisPending(networkId: 2, nick: "bob")
        store.apply(.socketClosed(reason: nil, code: nil))
        XCTAssertTrue(store.state.whoisPending.isEmpty)
        // Cached replies survive: they're answers we already have, not requests waiting on a
        // socket. The screen re-asks on open anyway.
        store.apply(.whoisResult(networkId: 1, whois: WhoisResult(nick: "alice")))
        store.apply(.socketClosed(reason: nil, code: nil))
        XCTAssertNotNil(store.state.whoisResult(networkId: 1, nick: "alice"))
    }

    // MARK: - Nick notes

    func testNotesFoldCaseButKeepTheirStoredCasingForDisplay() {
        let set = NickNoteSet(byNetwork: [1: [NickNote(nick: "Alice", note: "lives in Berlin")]])
        XCTAssertEqual(set.note(networkId: 1, nick: "ALICE")?.note, "lives in Berlin")
        XCTAssertEqual(set.note(networkId: 1, nick: "alice")?.nick, "Alice")
        XCTAssertTrue(set.hasNote(networkId: 1, nick: "alice"))
    }

    func testNotesAreScopedToOneNetwork() {
        // The same nick on two networks may be two people — the server keys them apart too.
        let set = NickNoteSet(byNetwork: [1: [NickNote(nick: "alice", note: "n")]])
        XCTAssertFalse(set.hasNote(networkId: 2, nick: "alice"))
        XCTAssertFalse(set.hasNote(networkId: nil, nick: "alice"))
    }

    func testABlankNoteNeverBecomesAnEntry() {
        // An empty note is the server's spelling of "no note" — `set_nick_note` deletes the row
        // rather than storing a blank. A present-but-blank entry would make `hasNote` lie.
        let set = NickNoteSet(byNetwork: [1: [NickNote(nick: "alice", note: ""), NickNote(nick: "", note: "x")]])
        XCTAssertFalse(set.hasNote(networkId: 1, nick: "alice"))
        XCTAssertNil(set.note(networkId: 1, nick: ""))
    }

    func testApplyingWritesAndClearsOneNoteWithoutDisturbingTheOthers() {
        let set = NickNoteSet(byNetwork: [
            1: [NickNote(nick: "alice", note: "a"), NickNote(nick: "bob", note: "b")],
        ])
        let written = set.applying(networkId: 1, nick: "carol", note: "c", updatedAt: nil)
        XCTAssertEqual(written.note(networkId: 1, nick: "carol")?.note, "c")
        XCTAssertEqual(written.note(networkId: 1, nick: "alice")?.note, "a")

        // An empty note is the delete — the same frame shape as a write.
        let cleared = written.applying(networkId: 1, nick: "ALICE", note: "", updatedAt: nil)
        XCTAssertNil(cleared.note(networkId: 1, nick: "alice"))
        XCTAssertEqual(cleared.note(networkId: 1, nick: "bob")?.note, "b")

        // And the original is untouched — these are replaced, never mutated, which is what
        // makes `===` a valid "did the notes change" test for the screens.
        XCTAssertEqual(set.note(networkId: 1, nick: "alice")?.note, "a")
        XCTAssertNil(set.note(networkId: 1, nick: "carol"))
    }

    func testRewritingANoteReplacesItRatherThanAddingASecondRow() {
        let set = NickNoteSet(byNetwork: [1: [NickNote(nick: "alice", note: "old")]])
            .applying(networkId: 1, nick: "ALICE", note: "new", updatedAt: nil)
        XCTAssertEqual(set.note(networkId: 1, nick: "alice")?.note, "new")
        // The server's canonical casing wins, because that's what the echo carries.
        XCTAssertEqual(set.note(networkId: 1, nick: "alice")?.nick, "ALICE")
    }

    func testRemovingANetworkDropsOnlyItsNotes() {
        let set = NickNoteSet(byNetwork: [
            1: [NickNote(nick: "alice", note: "a")],
            2: [NickNote(nick: "alice", note: "b")],
        ]).removing(networkId: 1)
        XCTAssertNil(set.note(networkId: 1, nick: "alice"))
        XCTAssertEqual(set.note(networkId: 2, nick: "alice")?.note, "b")
    }

    func testParsesTheNoteUpdateFrame() {
        // ⚠⚠ `"2026-08-29 12:00:00"` — a space, no zone — is what the server actually sends.
        // `user_nick_notes.updated_at` is `DEFAULT (datetime('now'))` and `nickNotes.ts` echoes
        // the column verbatim, unlike the tables declared with an explicit
        // `strftime('%Y-%m-%dT%H:%M:%fZ')`. Feeding this an ISO string is a test that passes
        // over a broken production path — which is what the first cut of it did.
        XCTAssertEqual(
            FrameParser.parseWs(##"""
            {"kind":"nick-note-updated","networkId":7,"nick":"Alice","note":"hi",
             "updatedAt":"2026-08-29 12:00:00"}
            """##),
            .nickNoteUpdated(
                networkId: 7, nick: "Alice", note: "hi",
                updatedAt: Date(timeIntervalSince1970: 1_788_004_800)
            )
        )
        // The clear arrives as the same frame with an empty note and no timestamp.
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"nick-note-updated","networkId":7,"nick":"Alice","note":""}"##),
            .nickNoteUpdated(networkId: 7, nick: "Alice", note: "", updatedAt: nil)
        )
    }

    func testANoteAboutNobodyIsRefused() {
        for bad in [
            ##"{"kind":"nick-note-updated","nick":"alice","note":"n"}"##,
            ##"{"kind":"nick-note-updated","networkId":null,"nick":"alice","note":"n"}"##,
            ##"{"kind":"nick-note-updated","networkId":7,"note":"n"}"##,
            ##"{"kind":"nick-note-updated","networkId":7,"nick":"","note":"n"}"##,
        ] {
            XCTAssertEqual(FrameParser.parseWs(bad), .ignored, bad)
        }
    }

    func testAFrameWithNoReadableNoteIsRefusedRatherThanTreatedAsAClear() {
        // ⚠⚠ An empty note is a DELETE, so folding an absent or non-string `note` to `""`
        // would let a malformed frame destroy something the user typed. Absent is not a
        // statement that the note is empty. The asymmetry settles it: refusing costs a missed
        // update, accepting costs the note.
        for bad in [
            ##"{"kind":"nick-note-updated","networkId":7,"nick":"alice"}"##,
            ##"{"kind":"nick-note-updated","networkId":7,"nick":"alice","note":null}"##,
            ##"{"kind":"nick-note-updated","networkId":7,"nick":"alice","note":42}"##,
        ] {
            XCTAssertEqual(FrameParser.parseWs(bad), .ignored, bad)
        }
        // The real clear still lands — `""` is present.
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"nick-note-updated","networkId":7,"nick":"alice","note":""}"##),
            .nickNoteUpdated(networkId: 7, nick: "alice", note: "", updatedAt: nil)
        )
    }

    func testTheNoteUpdateFramePatchesOneNick() {
        let store = LurkerStore()
        store.apply(.nickNoteUpdated(networkId: 1, nick: "alice", note: "a", updatedAt: nil))
        store.apply(.nickNoteUpdated(networkId: 1, nick: "bob", note: "b", updatedAt: nil))
        store.apply(.nickNoteUpdated(networkId: 1, nick: "alice", note: "", updatedAt: nil))
        XCTAssertNil(store.state.nickNotes.note(networkId: 1, nick: "alice"))
        XCTAssertEqual(store.state.nickNotes.note(networkId: 1, nick: "bob")?.note, "b")
    }

    func testTheSnapshotSeedsNotesAndDropsUnusableRows() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"snapshot","networks":[{"networkId":7,"state":"connected","nick":"me","channels":[],
         "nickNotes":[{"nick":"Alice","note":"lives in Berlin","updatedAt":"2026-08-29 12:00:00"},
                      {"nick":"","note":"x"},{"nick":"bob","note":""}]}]}
        """##)
        guard case let .snapshot(networks, _) = frame else { return XCTFail("expected a snapshot") }
        XCTAssertEqual(networks.first?.nickNotes.map(\.nick), ["Alice"])
        XCTAssertEqual(
            networks.first?.nickNotes.first?.updatedAt,
            Date(timeIntervalSince1970: 1_788_004_800)
        )
    }

    func testTheSnapshotReplacesNotesWholesale() {
        // A note cleared on the web while this device was away has to be GONE here, not survive
        // as a leftover the profile screen keeps showing.
        let store = LurkerStore()
        store.apply(.nickNoteUpdated(networkId: 7, nick: "alice", note: "stale", updatedAt: nil))
        store.apply(.snapshot(
            [NetworkSnapshot(id: 7, state: .connected, nick: "me", channels: [])],
            globalIgnores: []
        ))
        XCTAssertNil(store.state.nickNotes.note(networkId: 7, nick: "alice"))
    }
}

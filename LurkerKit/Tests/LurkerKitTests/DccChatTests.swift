// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// DCC CHAT (lurker#270): a `=nick` buffer is its own kind, the `/dcc` chat verbs follow irssi
/// exactly (the web's parser tests, ported), and the store holds which chats are live and which
/// offers are waiting — reconciled against every snapshot, because a phone misses live events.
@MainActor
final class DccChatTests: XCTestCase {

    // MARK: - Names

    func testAnEqualsTargetIsADccChat() {
        XCTAssertEqual(BufferKind.of(networkId: 1, target: "=bob"), .dcc)
        XCTAssertEqual(BufferKind.of(networkId: 1, target: "bob"), .dm)
        XCTAssertEqual(BufferKind.of(networkId: 1, target: "#bob"), .channel)
        // A bare `=` is still no nick: classed as a DM, it would reach the wire as `PRIVMSG =`.
        XCTAssertEqual(BufferKind.of(networkId: 1, target: "="), .dcc)
    }

    func testThePeerIsTheNameAfterTheSigil() {
        XCTAssertEqual(DccChat.peer("=bob"), "bob")
        XCTAssertEqual(DccChat.peer("bob"), "bob", "a plain nick passes through")
        XCTAssertEqual(DccChat.peer("="), "")
        XCTAssertEqual(DccChat.target(for: "bob"), "=bob")
    }

    func testADccChatShowsWhatADmShows() {
        XCTAssertTrue(BufferKind.dcc.renders(.message))
        XCTAssertTrue(BufferKind.dcc.renders(.notice))
        XCTAssertFalse(BufferKind.dcc.renders(.motd))
        XCTAssertTrue(BufferKind.dcc.hydratesOnDemand)
    }

    // MARK: - Order

    private func buffer(_ target: String) -> Buffer {
        Buffer(networkId: 1, target: target, kind: BufferKind.of(networkId: 1, target: target))
    }

    func testAChatFilesAmongTheDmsUnderItsPeer() {
        let sorted = [buffer("=zed"), buffer("carol"), buffer("=bob"), buffer("#lurker"), buffer("bob")]
            .sorted(by: BufferOrder.order)
            .map(\.target)
        // Keyed on the buffer name, every chat would pile up at the top of the DMs under `=`.
        XCTAssertEqual(sorted, ["#lurker", "bob", "=bob", "carol", "=zed"])
    }

    // MARK: - Search scope

    func testAChatCanScopeASearch() {
        XCTAssertEqual(SearchQuery.scope(for: buffer("=bob"), networkName: "libera"), "in:=bob on:libera ")
    }

    // MARK: - /dcc (the web's dcc.test.ts, chat half)

    private func effects(_ input: String, networkId: Int? = 1, target: String = "#chan") -> [CommandEffect] {
        guard case .command(let effects) = CommandParser.parse(input, networkId: networkId, target: target) else {
            XCTFail("expected a command from \(input)")
            return []
        }
        return effects
    }

    /// The info line a command answered with, or nil if it did something else.
    private func info(_ input: String, target: String = "#chan") -> String? {
        guard case .info(let text) = effects(input, target: target).first else { return nil }
        return text
    }

    func testDccChatOffersToANick() {
        XCTAssertEqual(effects("/dcc chat alice"), [.dccChat(nick: "alice", passive: false)])
        XCTAssertEqual(effects("/DCC CHAT Bob"), [.dccChat(nick: "Bob", passive: false)])
        XCTAssertNotNil(info("/dcc chat"))
    }

    /// Opt-in, never a fallback: WeeChat and HexDroid turn a passive offer into a silent dial to
    /// port 0, so it has to be asked for by name.
    func testPassiveIsAFlagInEitherPosition() {
        XCTAssertEqual(effects("/dcc chat -passive alice"), [.dccChat(nick: "alice", passive: true)])
        XCTAssertEqual(effects("/dcc chat alice -passive"), [.dccChat(nick: "alice", passive: true)])
    }

    func testAnUnknownOptionIsRefusedRatherThanReadAsANick() {
        XCTAssertEqual(info("/dcc chat -active alice")?.contains("-active"), true)
    }

    /// Read literally, `/dcc chat close bob` would OFFER a chat to a peer named "close".
    func testChatCloseIsCaughtAndPointedAtTheRealSpelling() {
        XCTAssertEqual(info("/dcc chat close alice")?.contains("/dcc close chat <nick>"), true)
        // …but someone genuinely nicked "close" is still reachable.
        XCTAssertEqual(effects("/dcc chat close"), [.dccChat(nick: "close", passive: false)])
    }

    /// ⚠⚠ The web's QA finding: a `/dcc close <nick>` shorthand read irssi's `/dcc close chat bob`
    /// as closing a chat with a peer called "chat", and left the real one open.
    func testCloseIsIrssisTypeFirstForm() {
        XCTAssertEqual(effects("/dcc close chat ami|shellter"), [.dccCloseChat(nick: "ami|shellter")])
        XCTAssertEqual(effects("/dcc close CHAT bob"), [.dccCloseChat(nick: "bob")])
        XCTAssertNotNil(info("/dcc close bob"), "the non-irssi shorthand is gone")
        XCTAssertNotNil(info("/dcc close"))
        XCTAssertNotNil(info("/dcc close chat"), "asks for a nick rather than closing a peer named chat")
        XCTAssertEqual(effects("/dcc close chat chat"), [.dccCloseChat(nick: "chat")])
        XCTAssertNotNil(info("/dcc close chat bob extra"))
    }

    /// `=bob` is the BUFFER; `/dcc chat =bob` would offer to someone literally named "=bob". And a
    /// channel would broadcast the offer to everyone in it — all four sigils.
    func testABufferNameOrAChannelIsNotAPeer() {
        for input in ["/dcc chat =bob", "/dcc chat #room", "/dcc chat &local", "/dcc chat +modeless",
                      "/dcc chat !safe", "/dcc close chat =bob", "/dcc close chat #room"] {
            XCTAssertNotNil(info(input), input)
        }
    }

    func testFileTransfersSayTheyAreNotHereRatherThanGoingRaw() {
        for input in ["/dcc list", "/dcc accept 3", "/dcc cancel 3", "/dcc close send bob",
                      "/dcc send bob file.txt", "/dcc resume bob file.txt"] {
            XCTAssertEqual(info(input), "DCC file transfers aren't in the app yet.", input)
        }
        // And nothing falls through to the raw default, which put `DCC chat bob` on the IRC wire.
        for input in ["/dcc", "/dcc frobnicate", "/dcc chat"] {
            XCTAssertNotNil(info(input), input)
        }
    }

    func testDccNeedsANetwork() {
        let effects = effects("/dcc chat bob", networkId: nil, target: Buffer.systemTarget)
        guard case .info = effects.first else { return XCTFail("expected the network gate") }
        XCTAssertEqual(effects.count, 1)
    }

    // MARK: - /dcc help and completion

    /// Both come from the spec, and one positional list could only describe `/dcc` as a shape
    /// neither form has (`/dcc <chat|close chat> <nick>`, no `-passive`).
    func testTheHelpShowsBothFormsAsTheyAreTyped() {
        XCTAssertEqual(
            CommandRegistry.spec(for: "dcc")?.usage,
            "/dcc chat [-passive] <nick> · /dcc close chat <nick>"
        )
    }

    private func completes(_ text: String) -> ArgKind? {
        guard case .argument(_, _, let kind, _, _) =
            CommandCompletion.context(in: text, caret: (text as NSString).length)
        else { return nil }
        return kind
    }

    func testCompletionFindsTheNickInEitherForm() {
        XCTAssertEqual(completes("/dcc chat b"), .nick)
        XCTAssertEqual(completes("/dcc chat "), .nick, "the optional flag is skipped")
        XCTAssertEqual(completes("/dcc chat -passive b"), .nick)
        XCTAssertEqual(completes("/dcc close chat b"), .nick)
        XCTAssertNil(completes("/dcc close b"), "the word after close is `chat`, not a nick")
        XCTAssertNil(completes("/dcc chat -pa"), "a flag is typed, not completed")
        XCTAssertNil(completes("/dcc ch"))
        XCTAssertNil(completes("/dcc chat bob b"), "nothing after the nick")
    }

    // MARK: - Bare /whois and /ping in a chat

    /// ⚠⚠ Both put their argument on the IRC wire, and `/ping` as a CTCP no server guard covers —
    /// so a bare one in `=bob` must mean bob.
    func testABareWhoisOrPingInAChatMeansThePeer() {
        XCTAssertEqual(effects("/whois", target: "=bob"), [.showProfile(nick: "bob")])
        XCTAssertEqual(effects("/ping", target: "=bob"), [.ctcp(target: "bob", type: "PING", args: "")])
        XCTAssertNotNil(info("/ping", target: "="), "a bare `=` has no peer to ping")
    }

    // MARK: - Status light

    /// The chat's session, never the network's state: the chat works while the IRC link is down.
    func testTheLightFollowsTheSessionNotTheNetwork() {
        XCTAssertEqual(StatusLight.ofDccChat(reachable: true, connection: .connected, live: true), .good)
        XCTAssertEqual(StatusLight.ofDccChat(reachable: true, connection: .connected, live: false), .bad)
        XCTAssertEqual(
            StatusLight.ofDccChat(reachable: true, connection: .connected, live: nil), .warn,
            "not known until this socket's snapshot lands"
        )
        // The outer layers still win: a live chat is out of reach from a phone with no path.
        XCTAssertEqual(StatusLight.ofDccChat(reachable: false, connection: .connected, live: true), .bad)
        XCTAssertEqual(StatusLight.ofDccChat(reachable: true, connection: .reconnecting, live: true), .warn)
    }

    // MARK: - Wire

    func testTheSnapshotCarriesLiveChatsAndWaitingOffers() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"snapshot","networks":[{"networkId":1,"state":"disconnected","nick":"me","channels":[],"dccChats":["Bob",""],"dccChatOffers":["carol"]}]}"##
        )
        guard case let .snapshot(networks, _, _) = frame else { return XCTFail("got \(frame)") }
        XCTAssertEqual(networks.first?.dccChats, ["Bob"], "an empty peer names no one")
        XCTAssertEqual(networks.first?.dccChatOffers, ["carol"])
    }

    func testTheThreeEventsNameThePeerInTheFromField() {
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"irc","type":"dcc-chat-offer","networkId":1,"target":":server:1","from":"bob","passive":true}"##),
            .dccChatOffer(networkId: 1, nick: "bob", passive: true)
        )
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"irc","type":"dcc-chat-offer-closed","networkId":1,"target":":server:1","from":"bob"}"##),
            .dccChatOfferClosed(networkId: 1, nick: "bob")
        )
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"irc","type":"dcc-chat-state","networkId":1,"target":":server:1","from":"bob","live":true}"##),
            .dccChatState(networkId: 1, nick: "bob", live: true)
        )
        // Nobody named, nothing to key on.
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"irc","type":"dcc-chat-offer","networkId":1,"target":":server:1"}"##),
            .ignored
        )
    }

    // MARK: - Store

    private func snapshot(_ id: Int = 1, state: ConnectionState = .connected, chats: [String] = [], offers: [String] = []) -> ServerFrame {
        .snapshot([
            NetworkSnapshot(id: id, state: state, nick: "me", channels: [], dccChats: chats, dccChatOffers: offers),
        ], globalIgnores: [], maxUploadBytes: nil)
    }

    private let bob = BufferKey(networkId: 1, target: "=bob")

    /// The reverse of a DM: the chat is a socket straight to the peer, so a dropped network says
    /// nothing about it.
    func testAChatIsLiveWhateverTheNetworkIsDoing() {
        let store = LurkerStore()
        store.apply(snapshot(state: .disconnected, chats: ["Bob"]))
        XCTAssertTrue(store.state.isDccChatLive(bob), "listed live, and case-folded")
        XCTAssertFalse(store.state.isDccChatLive(BufferKey(networkId: 1, target: "=carol")))
        XCTAssertFalse(store.state.isDccChatLive(BufferKey(networkId: 1, target: "bob")), "a DM is not a chat")
    }

    func testLiveStateFollowsTheEvents() {
        let store = LurkerStore()
        store.apply(snapshot())
        store.apply(.dccChatState(networkId: 1, nick: "bob", live: true))
        XCTAssertTrue(store.state.isDccChatLive(bob))
        store.apply(.dccChatState(networkId: 1, nick: "BOB", live: false))
        XCTAssertFalse(store.state.isDccChatLive(bob))
    }

    func testTheSnapshotReplacesLiveChatsWholesale() {
        let store = LurkerStore()
        store.apply(.dccChatState(networkId: 1, nick: "bob", live: true))
        // The chat ended while this device was away: only the snapshot can say so.
        store.apply(snapshot(chats: []))
        XCTAssertFalse(store.state.isDccChatLive(bob))
    }

    func testAnOfferWaitsUntilTheServerClosesIt() {
        let store = LurkerStore()
        store.apply(.dccChatOffer(networkId: 1, nick: "bob", passive: true))
        XCTAssertEqual(store.state.dccChatOffers.map(\.nick), ["bob"])
        XCTAssertEqual(store.state.dccChatOffers.first?.passive, true)
        XCTAssertEqual(store.state.dccChatOffers.first?.key, bob)
        store.apply(.dccChatOfferClosed(networkId: 1, nick: "Bob"))
        XCTAssertEqual(store.state.dccChatOffers, [])
    }

    /// Offering again is a new question, so it gets a new id — which is what makes the app ask it.
    func testAnOfferMadeAgainReplacesTheOldOneWithANewId() {
        let store = LurkerStore()
        store.apply(.dccChatOffer(networkId: 1, nick: "bob", passive: false))
        let first = store.state.dccChatOffers[0].id
        store.apply(.dccChatOffer(networkId: 1, nick: "bob", passive: false))
        XCTAssertEqual(store.state.dccChatOffers.count, 1)
        XCTAssertNotEqual(store.state.dccChatOffers[0].id, first)
    }

    /// A reconnect re-lists an offer still pending. It must stay the SAME offer, or the app would
    /// ask about it again on every reconnect.
    func testASnapshotKeepsAnOfferWeAlreadyHold() {
        let store = LurkerStore()
        store.apply(.dccChatOffer(networkId: 1, nick: "bob", passive: true))
        let held = store.state.dccChatOffers[0]
        store.apply(snapshot(offers: ["Bob"]))
        XCTAssertEqual(store.state.dccChatOffers, [held], "same id, and `passive` survives")
    }

    /// The case the snapshot exists for: the offer came in while the phone's socket was asleep.
    func testASnapshotSurfacesAnOfferWeMissed() {
        let store = LurkerStore()
        store.apply(snapshot(offers: ["carol"]))
        XCTAssertEqual(store.state.dccChatOffers.map(\.nick), ["carol"])
        XCTAssertEqual(store.state.dccChatOffers.first?.passive, false, "the snapshot doesn't say")
    }

    /// …and the other half: the offer was answered or expired while we weren't listening, so the
    /// closing event never reached us.
    func testASnapshotRetiresAnOfferItNoLongerLists() {
        let store = LurkerStore()
        store.apply(.dccChatOffer(networkId: 1, nick: "bob", passive: false))
        store.apply(snapshot(offers: []))
        XCTAssertEqual(store.state.dccChatOffers, [])
    }

    /// ⚠ The list survives a reconnect until the new snapshot replaces it, so until then nobody may
    /// read it as an answer — the info sheet offered End or Start off the last session's list.
    func testASessionIsUnknownUntilThisSocketsSnapshot() {
        let store = LurkerStore()
        XCTAssertNil(store.state.dccChatSession(bob), "nothing heard yet")
        store.apply(.socketOpen)
        store.apply(snapshot(chats: ["bob"]))
        XCTAssertEqual(store.state.dccChatSession(bob), true)
        XCTAssertEqual(store.state.dccChatSession(BufferKey(networkId: 1, target: "=carol")), false)

        store.apply(.socketClosed(reason: nil, code: nil))
        XCTAssertNil(store.state.dccChatSession(bob), "the socket is down; the list is last session's")
        store.apply(.socketOpen)
        XCTAssertNil(store.state.dccChatSession(bob), "back, but the snapshot hasn't landed")
        store.apply(snapshot(chats: []))
        XCTAssertEqual(store.state.dccChatSession(bob), false)
    }

    /// A deleted network's chats end with it, and its offers can't be answered any more.
    func testDroppingANetworkForgetsItsChatsAndOffers() {
        let store = LurkerStore()
        store.apply(.snapshot([
            NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [], dccChats: ["bob"], dccChatOffers: ["carol"]),
            NetworkSnapshot(id: 2, state: .connected, nick: "me", channels: [], dccChatOffers: ["dave"]),
        ], globalIgnores: [], maxUploadBytes: nil))
        store.apply(.networks([Network(id: 2, name: "Other")]))
        XCTAssertFalse(store.state.isDccChatLive(bob))
        XCTAssertEqual(store.state.dccChatOffers.map(\.nick), ["dave"], "the other network's offer stays")
    }

    // MARK: - Going to a chat once its buffer exists

    private let opened = Date(timeIntervalSince1970: 1_000)

    func testAnOpenWaitsForTheRowThenGoesThere() {
        let pending = PendingDccOpen(networkId: 1, nick: "bob", now: opened)
        XCTAssertEqual(pending.settle(buffers: [:], now: opened.addingTimeInterval(1)), .waiting)
        let row = Buffer(networkId: 1, target: "=Bob", kind: .dcc)
        XCTAssertEqual(
            pending.settle(buffers: [row.key.id: row], now: opened.addingTimeInterval(1)),
            .open(row.key), "the server's spelling of the name"
        )
    }

    /// What a close checks before it cancels the wait: the same chat, however it was spelled.
    func testAWaitKnowsWhichChatItIsFor() {
        let pending = PendingDccOpen(networkId: 1, nick: "bob", now: opened)
        XCTAssertTrue(pending.isFor(networkId: 1, nick: "Bob"))
        XCTAssertFalse(pending.isFor(networkId: 1, nick: "carol"))
        XCTAssertFalse(pending.isFor(networkId: 2, nick: "bob"))
    }

    /// ⚠ The deadline wins over a row that arrives late: by then nobody is waiting for it, and
    /// going there would pull the user out of whatever they're reading.
    func testARowThatLandsAfterTheDeadlineGoesNowhere() {
        let pending = PendingDccOpen(networkId: 1, nick: "bob", now: opened)
        let late = opened.addingTimeInterval(PendingDccOpen.patience + 1)
        XCTAssertEqual(pending.settle(buffers: [:], now: late), .expired)
        let row = Buffer(networkId: 1, target: "=bob", kind: .dcc)
        XCTAssertEqual(pending.settle(buffers: [row.key.id: row], now: late), .expired)
    }

    // MARK: - Opens and closes that race

    private func row(_ target: String) -> [String: Buffer] {
        let buffer = Buffer(networkId: 1, target: target, kind: .dcc)
        return [buffer.key.id: buffer]
    }

    private let bobKey = BufferKey(networkId: 1, target: "=bob")
    private let carolKey = BufferKey(networkId: 1, target: "=carol")

    /// ⚠⚠ Start, then End before Start's request returns: the close found nothing to cancel, and
    /// Start's reply then installed a wait that took the user into the chat they had just ended.
    func testACloseOvertakesAnOpenStillInFlight() {
        var opens = DccOpens()
        let ticket = opens.begin(networkId: 1, nick: "bob")
        _ = opens.closing(networkId: 1, nick: "Bob")
        opens.opened(ticket, now: opened)
        XCTAssertNil(opens.waiting)
        XCTAssertNil(opens.settle(buffers: row("=bob"), now: opened))
    }

    func testACloseOfAnotherChatDoesNot() {
        var opens = DccOpens()
        let ticket = opens.begin(networkId: 1, nick: "bob")
        _ = opens.closing(networkId: 1, nick: "carol")
        opens.opened(ticket, now: opened)
        XCTAssertEqual(opens.settle(buffers: row("=bob"), now: opened), bobKey)
    }

    /// Once a close is behind it, opening the same chat again works as it did the first time.
    func testAnOpenAfterACloseStillWaits() {
        var opens = DccOpens()
        _ = opens.closing(networkId: 1, nick: "bob")
        let ticket = opens.begin(networkId: 1, nick: "bob")
        opens.opened(ticket, now: opened)
        XCTAssertNotNil(opens.waiting)
    }

    /// ⚠⚠ The close marks BEFORE its request goes out: its own "Cancelled…" notice mints the row
    /// over the socket, usually ahead of the HTTP reply, and must find nothing waiting.
    func testACloseStopsAWaitBeforeItsOwnNoticeCanSatisfyIt() {
        var opens = DccOpens()
        opens.opened(opens.begin(networkId: 1, nick: "bob"), now: opened)
        _ = opens.closing(networkId: 1, nick: "bob")
        XCTAssertNil(opens.settle(buffers: row("=bob"), now: opened))
    }

    /// A refused close ended nothing: the chat is still coming, so the wait comes back.
    func testARefusedClosePutsTheWaitBack() {
        var opens = DccOpens()
        opens.opened(opens.begin(networkId: 1, nick: "bob"), now: opened)
        let mark = opens.closing(networkId: 1, nick: "bob")
        opens.closeRefused(mark)
        XCTAssertEqual(opens.settle(buffers: row("=bob"), now: opened), bobKey)
    }

    /// …unless the user has asked for something else since.
    func testARefusedCloseDoesNotOverrideANewerOpen() {
        var opens = DccOpens()
        opens.opened(opens.begin(networkId: 1, nick: "bob"), now: opened)
        let mark = opens.closing(networkId: 1, nick: "bob")
        _ = opens.begin(networkId: 1, nick: "carol")
        opens.closeRefused(mark)
        XCTAssertNil(opens.waiting)
    }

    /// One wait, deliberately — and "last" means the last ASKED, not the last to answer. Bob's
    /// reply arriving after Carol's is stale and must not take the user to Bob.
    func testTheLatestRequestWinsWhateverOrderTheRepliesArrive() {
        var opens = DccOpens()
        let bob = opens.begin(networkId: 1, nick: "bob")
        let carol = opens.begin(networkId: 1, nick: "carol")
        opens.opened(carol, now: opened)
        opens.opened(bob, now: opened)
        XCTAssertNil(opens.settle(buffers: row("=bob"), now: opened))
        XCTAssertEqual(opens.settle(buffers: row("=carol"), now: opened), carolKey)
        XCTAssertNil(opens.waiting, "settled once, then done")
    }

    /// An open sent before a sign-out must not land in whoever signs in next.
    func testAReplyFromBeforeASignOutIsStale() {
        var opens = DccOpens()
        let ticket = opens.begin(networkId: 1, nick: "bob")
        opens.reset()
        opens.opened(ticket, now: opened)
        XCTAssertNil(opens.waiting)
    }

    func testSignOutForgetsOffersAndChats() {
        let store = LurkerStore()
        store.apply(snapshot(chats: ["bob"], offers: ["carol"]))
        store.reset()
        XCTAssertEqual(store.state.dccChatOffers, [])
        XCTAssertFalse(store.state.isDccChatLive(bob))
    }
}

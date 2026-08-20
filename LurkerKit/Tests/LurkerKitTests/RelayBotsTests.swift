// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Relay-bot marks end to end (#277): the wire in, the set they build, what they do to a list of
/// messages, and the `/relay` verb that asks for one.
@MainActor
final class RelayBotsTests: XCTestCase {

    private func message(
        _ id: Int, nick: String, text: String, type: EventType = .message, isSelf: Bool = false
    ) -> Message {
        Message(id: id, type: type, nick: nick, text: text, isSelf: isSelf)
    }

    // MARK: - The set

    func testMarksFoldCaseButKeepTheirStoredCasingForDisplay() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "RelayBot")]])
        XCTAssertTrue(set.isRelay(networkId: 1, nick: "relaybot"))
        XCTAssertTrue(set.isRelay(networkId: 1, nick: "RELAYBOT"))
        XCTAssertEqual(set.listing(for: 1).map(\.nick), ["RelayBot"])
    }

    func testMarksAreScopedToOneNetwork() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]])
        XCTAssertTrue(set.isRelay(networkId: 1, nick: "bridge"))
        XCTAssertFalse(set.isRelay(networkId: 2, nick: "bridge"))
        // Nil is the app-scoped system buffer, where no network's marks are in scope.
        XCTAssertFalse(set.isRelay(networkId: nil, nick: "bridge"))
    }

    func testApplyingSetsAndClearsOneMarkWithoutDisturbingTheOthers() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "a"), RelayBot(nick: "b")]])
        let marked = set.applying(networkId: 1, nick: "c", marked: true, pattern: "{nick}: {message}")
        XCTAssertEqual(marked.listing(for: 1).map(\.nick), ["a", "b", "c"])
        XCTAssertEqual(marked.bot(networkId: 1, nick: "c")?.pattern, "{nick}: {message}")

        let cleared = marked.applying(networkId: 1, nick: "A", marked: false, pattern: "")
        XCTAssertEqual(cleared.listing(for: 1).map(\.nick), ["b", "c"])
        // And the original is untouched — these are replaced, never mutated, which is what makes
        // `===` a valid "did the marks change" test for the screens.
        XCTAssertEqual(set.listing(for: 1).map(\.nick), ["a", "b"])
    }

    func testRemarkingReplacesThePatternRatherThanAddingASecondRow() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bot", pattern: "old")]])
            .applying(networkId: 1, nick: "BOT", marked: true, pattern: "{nick}> {message}")
        XCTAssertEqual(set.listing(for: 1).count, 1)
        XCTAssertEqual(set.bot(networkId: 1, nick: "bot")?.pattern, "{nick}> {message}")
        // The server's canonical casing wins, because that's what the echo carries.
        XCTAssertEqual(set.listing(for: 1).first?.nick, "BOT")
    }

    // MARK: - Re-attribution

    func testReattributesAMarkedBotsLines() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]])
        let rows = set.reattributing(
            [
                message(1, nick: "bridge", text: "[Discord] <alice> hello"),
                message(2, nick: "carol", text: "not from the bridge"),
            ],
            networkId: 1
        )
        XCTAssertEqual(rows[0].nick, "alice")
        XCTAssertEqual(rows[0].text, "hello")
        XCTAssertEqual(rows[0].relayBot, "bridge")
        XCTAssertEqual(rows[0].relaySource, "Discord")
        // Same line, shown differently: the id survives, so a bookmark or a jump still finds it.
        XCTAssertEqual(rows[0].id, 1)
        XCTAssertEqual(rows[1].nick, "carol")
        XCTAssertNil(rows[1].relayBot)
    }

    func testLeavesALineWhoseEnvelopeDoesNotParse() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]])
        let rows = set.reattributing(
            [message(1, nick: "bridge", text: "connected to the bridge network")],
            networkId: 1
        )
        XCTAssertEqual(rows[0].nick, "bridge")
        XCTAssertEqual(rows[0].text, "connected to the bridge network")
        XCTAssertNil(rows[0].relayBot)
    }

    /// Relays bridge speech as PRIVMSG. Re-attributing an action or a notice would tangle with the
    /// special body rendering those get, and your own lines aren't a bridge whatever they look
    /// like.
    func testOnlyPlainMessagesFromSomeoneElseAreReattributed() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]])
        let rows = set.reattributing(
            [
                message(1, nick: "bridge", text: "[X] <alice> hi", type: .action),
                message(2, nick: "bridge", text: "[X] <alice> hi", type: .notice),
                message(3, nick: "bridge", text: "[X] <alice> hi", isSelf: true),
            ],
            networkId: 1
        )
        XCTAssertEqual(rows.map(\.nick), ["bridge", "bridge", "bridge"])
        XCTAssertTrue(rows.allSatisfy { $0.relayBot == nil })
    }

    func testAnUnmarkedNetworkOrAnEmptySetIsAPassthrough() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]])
        let line = [message(1, nick: "bridge", text: "[X] <alice> hi")]
        XCTAssertNil(set.reattributing(line, networkId: 2)[0].relayBot)
        XCTAssertNil(set.reattributing(line, networkId: nil)[0].relayBot)
        XCTAssertNil(RelayBotSet.empty.reattributing(line, networkId: 1)[0].relayBot)
    }

    func testEachBotUsesItsOwnPattern() {
        let set = RelayBotSet(byNetwork: [
            1: [RelayBot(nick: "a"), RelayBot(nick: "b", pattern: "{nick} :: {message}")],
        ])
        let rows = set.reattributing(
            [
                message(1, nick: "a", text: "<alice> one"),
                message(2, nick: "b", text: "bob :: two"),
                // `b`'s custom pattern REPLACES the defaults rather than adding to them, so the
                // default shape no longer parses for it.
                message(3, nick: "b", text: "<carol> three"),
            ],
            networkId: 1
        )
        XCTAssertEqual(rows.map(\.nick), ["alice", "bob", "b"])
    }

    // MARK: - Chained bridges (#801)

    /// The reported line, verbatim from a real corpus: `nR` bridges the IRC-nERDs network, where
    /// a bot nicked `|` is itself bridging Matrix/OFTC.
    private static let nested =
        "\u{2}[IRC-nERDs]\u{2} <~\u{3}06|\u{3}> \u{3}13<yrdsb3222[m]/OFTC> \u{f}Is their a discord"

    func testStopsAtTheIntermediateBridgeWhenOnlyTheOuterBotIsMarked() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "nR")]])
        let rows = set.reattributing([message(1, nick: "nR", text: Self.nested)], networkId: 1)
        XCTAssertEqual(rows[0].nick, "|")
        XCTAssertEqual(rows[0].relaySource, "IRC-nERDs")
        XCTAssertEqual(rows[0].text, "\u{3}13<yrdsb3222[m]/OFTC> \u{f}Is their a discord")
    }

    func testReachesTheRealSpeakerOnceTheIntermediateBridgeIsMarkedToo() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "nR"), RelayBot(nick: "|")]])
        let rows = set.reattributing([message(1, nick: "nR", text: Self.nested)], networkId: 1)
        XCTAssertEqual(rows[0].nick, "yrdsb3222[m]/OFTC")
        XCTAssertEqual(rows[0].text, "\u{f}Is their a discord")
        // The outer tag survives the hops inside it, and `via` stays the real IRC entity.
        XCTAssertEqual(rows[0].relaySource, "IRC-nERDs")
        XCTAssertEqual(rows[0].relayBot, "nR")
    }

    /// Quoting looks exactly like an envelope, which is why every hop needs a mark of its own.
    /// Real line: raah, on efnet, quoting ultros.
    func testLeavesAQuotedNickAlone() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "nR"), RelayBot(nick: "|")]])
        let quote = "\u{2}[efnet]\u{2} <+\u{3}03raah\u{3}> <\u{3}10ultros\u{3}> blasphemer! and a heretic!"
        let rows = set.reattributing([message(1, nick: "nR", text: quote)], networkId: 1)
        XCTAssertEqual(rows[0].nick, "raah")
    }

    func testFollowsAThreeDeepChainAndPrefersTheInnermostSourceTag() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "DeltaCharlie"), RelayBot(nick: "nR")]])
        let rows = set.reattributing(
            [message(1, nick: "DeltaCharlie", text: "<nR> [rizon] <Nsane> Looks like the sequel bombed")],
            networkId: 1
        )
        XCTAssertEqual(rows[0].nick, "Nsane")
        XCTAssertEqual(rows[0].relaySource, "rizon")
        XCTAssertEqual(rows[0].text, "Looks like the sequel bombed")
    }

    func testAnInnerHopUsesItsOwnCustomTemplate() {
        let set = RelayBotSet(byNetwork: [1: [
            RelayBot(nick: "outer"),
            RelayBot(nick: "bridge", pattern: "{source} » {nick} » {message}"),
        ]])
        let rows = set.reattributing(
            [message(1, nick: "outer", text: "[net] <bridge> matrix » alice » hey")],
            networkId: 1
        )
        XCTAssertEqual(rows[0].nick, "alice")
        XCTAssertEqual(rows[0].relaySource, "matrix")
        XCTAssertEqual(rows[0].text, "hey")
    }

    /// A marked hop speaking in its own voice ends the chain where it stands, still attributed.
    func testEndsTheChainWhenAMarkedHopSaysSomethingOfItsOwn() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "outer"), RelayBot(nick: "bridge")]])
        let rows = set.reattributing(
            [message(1, nick: "outer", text: "[net] <bridge> reconnected to matrix")],
            networkId: 1
        )
        XCTAssertEqual(rows[0].nick, "bridge")
        XCTAssertEqual(rows[0].relaySource, "net")
        XCTAssertEqual(rows[0].text, "reconnected to matrix")
    }

    func testTerminatesOnABotWhoseEnvelopeNamesItself() {
        let set = RelayBotSet(byNetwork: [1: [RelayBot(nick: "loop")]])
        let rows = set.reattributing(
            [message(1, nick: "loop", text: "<loop> <loop> <loop> <loop> <loop> <loop> <loop> done")],
            networkId: 1
        )
        // Depth-capped rather than looping — it stops mid-chain, still attributed.
        XCTAssertEqual(rows[0].nick, "loop")
        XCTAssertEqual(rows[0].text, "<loop> <loop> <loop> done")
    }

    // MARK: - The wire

    func testTheSnapshotSeedsMarksAndReplacesThemWholesale() {
        let store = LurkerStore()
        store.apply(.snapshot(
            [NetworkSnapshot(
                id: 1, state: .connected, nick: "me", channels: [],
                relayBots: [RelayBot(nick: "bridge", pattern: "{nick}: {message}")]
            )],
            globalIgnores: []
        ))
        XCTAssertEqual(store.state.relayBots.listing(for: 1).map(\.nick), ["bridge"])

        // A bot unmarked while this device was away has to disappear, not survive as a leftover
        // that keeps rewriting its lines' authors.
        store.apply(.snapshot(
            [NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])],
            globalIgnores: []
        ))
        XCTAssertTrue(store.state.relayBots.listing(for: 1).isEmpty)
    }

    func testTheUpdateFramePatchesOneNick() {
        let store = LurkerStore()
        store.apply(.relayBotUpdated(networkId: 1, nick: "bridge", marked: true, pattern: ""))
        store.apply(.relayBotUpdated(networkId: 1, nick: "other", marked: true, pattern: "p"))
        XCTAssertEqual(store.state.relayBots.listing(for: 1).map(\.nick), ["bridge", "other"])

        store.apply(.relayBotUpdated(networkId: 1, nick: "bridge", marked: false, pattern: ""))
        XCTAssertEqual(store.state.relayBots.listing(for: 1).map(\.nick), ["other"])
    }

    func testParsesTheSnapshotAndUpdateFrames() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"snapshot","networks":[{"networkId":7,"state":"connected","nick":"me","channels":[],
         "relayBots":[{"nick":"bridge","pattern":"{nick}: {message}"},{"nick":"","pattern":"x"}]}]}
        """##)
        guard case let .snapshot(networks, _) = frame else { return XCTFail("expected a snapshot") }
        // The nick-less row is dropped rather than becoming a mark keyed on the empty string,
        // which would then "match" every nick-less line the client renders.
        XCTAssertEqual(networks.first?.relayBots, [RelayBot(nick: "bridge", pattern: "{nick}: {message}")])

        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"relay-bot-updated","networkId":7,"nick":"Bridge","marked":true,"pattern":"p"}"##),
            .relayBotUpdated(networkId: 7, nick: "Bridge", marked: true, pattern: "p")
        )
        // A mark with no network or no nick addresses nothing, so it's refused rather than folded
        // onto network 0 or the empty nick.
        for bad in [
            ##"{"kind":"relay-bot-updated","nick":"bridge","marked":true}"##,
            ##"{"kind":"relay-bot-updated","networkId":null,"nick":"bridge","marked":true}"##,
            ##"{"kind":"relay-bot-updated","networkId":7,"marked":true}"##,
            ##"{"kind":"relay-bot-updated","networkId":7,"nick":"","marked":true}"##,
        ] {
            XCTAssertEqual(FrameParser.parseWs(bad), .ignored, bad)
        }
    }

    // MARK: - /relay

    private func effects(_ input: String, relayBots: RelayBotSet? = .empty) -> [CommandEffect] {
        guard case let .command(effects) = CommandParser.parse(
            input, networkId: 1, target: "#chan", relayBots: relayBots
        ) else {
            XCTFail("expected a command for \(input)")
            return []
        }
        return effects
    }

    func testRelayAddAndRemoveAskTheServer() {
        XCTAssertEqual(
            effects("/relay add bridge"),
            [.setRelayBot(
                networkId: 1, nick: "bridge", marked: true, pattern: "",
                receipt: "marked bridge as a relay bot."
            )]
        )
        XCTAssertEqual(
            effects("/relay remove bridge"),
            [.setRelayBot(
                networkId: 1, nick: "bridge", marked: false, pattern: "",
                receipt: "unmarked bridge as a relay bot."
            )]
        )
    }

    /// ⚠ The pattern is the raw remainder of the line, spaces and all — running it through a
    /// tokenizer would hand the server a template that no longer matches anything.
    func testACustomPatternSurvivesWithItsSpacing() {
        XCTAssertEqual(
            effects(#"/relay add bridge <{nick}>  [{source}] {message}"#),
            [.setRelayBot(
                networkId: 1, nick: "bridge", marked: true,
                pattern: #"<{nick}>  [{source}] {message}"#,
                receipt: #"marked bridge as a relay bot (pattern: <{nick}>  [{source}] {message})."#
            )]
        )
        // Quoting isn't required, but one surrounding pair is peeled if it's there.
        guard case let .setRelayBot(_, _, _, pattern, _) = effects(#"/relay add b "{nick}: {message}""#).first else {
            return XCTFail("expected a mark")
        }
        XCTAssertEqual(pattern, "{nick}: {message}")
    }

    func testRelayListsTheMarksOnThisNetwork() {
        let set = RelayBotSet(byNetwork: [
            1: [RelayBot(nick: "zbot"), RelayBot(nick: "abot", pattern: "{nick}: {message}")],
            2: [RelayBot(nick: "elsewhere")],
        ])
        guard case let .info(text) = effects("/relay", relayBots: set).first else {
            return XCTFail("expected a listing")
        }
        XCTAssertEqual(
            text,
            """
            relay bots (2):
              abot  — {nick}: {message}
              zbot
            """
        )
    }

    /// An empty listing has to carry the way out of it: someone typing `/relay` into a channel a
    /// bridge is talking in is asking how to fix what they're looking at.
    func testAnEmptyListingSaysHowToMarkOne() {
        guard case let .info(text) = effects("/relay").first else { return XCTFail("expected a listing") }
        XCTAssertTrue(text.contains("/relay add <nick>"), text)
    }

    /// A listing built before the connect burst finished would be a confident "none" for an
    /// account that has several — the same trap `/ignore` avoids the same way.
    func testAListingIsWithheldUntilTheMarksHaveArrived() {
        guard case let .info(text) = effects("/relay", relayBots: nil).first else {
            return XCTFail("expected a note")
        }
        XCTAssertTrue(text.contains("haven't arrived yet"), text)
        // Marking is NOT gated on the same thing: the mark is fine, it's only our ability to
        // describe the list that's missing.
        XCTAssertEqual(effects("/relay add bridge", relayBots: nil).count, 1)
    }

    /// ⚠ A pattern that can't compile marks the bot and then re-attributes nothing, forever —
    /// `templates(for:)` deliberately won't fall back to the built-ins for one. Nothing downstream
    /// reports that, and `/relay list` shows the mark as if it were working, so the refusal has to
    /// happen at the only moment anyone is looking.
    func testAPatternThatCannotCompileIsRefusedRatherThanMarked() {
        // The realistic way to get one: forgetting the braces.
        guard case let .info(text) = effects("/relay add bot [Discord] <nick> message").first else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(text.contains("{nick} and {message}"), text)
        XCTAssertEqual(effects("/relay add bot [Discord] <nick> message").count, 1, "nothing may reach the wire")
        // A pattern that DOES compile still goes through, and so does no pattern at all.
        XCTAssertEqual(effects(#"/relay add bot <{nick}> {message}"#).count, 1)
        if case .info = effects(#"/relay add bot <{nick}> {message}"#).first {
            XCTFail("a valid pattern must not be refused")
        }
    }

    func testUnusableRelayInputNeverReachesTheWire() {
        for input in ["/relay add", "/relay remove", "/relay wat"] {
            guard case let .info(text) = effects(input).first else {
                return XCTFail("expected a note for \(input)")
            }
            XCTAssertTrue(text.hasPrefix("/relay:"), text)
        }
    }

    /// One surrounding pair of quotes is peeled; a pair that isn't one is left alone. Peeling it
    /// would produce a template that still compiles — so it would be stored and marked with a
    /// confident receipt — while matching something the user never wrote.
    func testUnquoteOnlyPeelsAnActualQuotedRun() {
        func pattern(_ input: String) -> String? {
            guard case let .setRelayBot(_, _, _, pattern, _) = effects(input).first else { return nil }
            return pattern
        }
        XCTAssertEqual(pattern(#"/relay add b "{nick}: {message}""#), "{nick}: {message}")
        XCTAssertEqual(
            pattern(##"/relay add b "{nick}" said "{message}""##),
            ##""{nick}" said "{message}""##
        )
    }

    // MARK: - A bridged speaker is not the local one with the same name

    /// ⚠ Anyone on a bridged platform can pick a nick that matches an IRC regular. Grouping on
    /// nick alone folded the bridged line into the local speaker's run, which renders it headerless
    /// under their name and drops the very tag that would have said otherwise.
    func testARelayedSpeakerDoesNotJoinALocalNamesakesRun() {
        let local = message(1, nick: "alice", text: "from the channel")
        let bridged = message(2, nick: "bridge", text: "[Discord] <alice> from discord")
        let rows = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]])
            .reattributing([local, bridged], networkId: 1)
        XCTAssertEqual(rows[1].nick, "alice", "precondition: both rows read as alice")
        XCTAssertFalse(MessageGrouping.continuesRun(rows[1], after: rows[0]))
    }

    func testTwoLinesFromTheSameBridgedSpeakerDoGroup() {
        let rows = RelayBotSet(byNetwork: [1: [RelayBot(nick: "bridge")]]).reattributing(
            [
                message(1, nick: "bridge", text: "[Discord] <alice> one"),
                message(2, nick: "bridge", text: "[Discord] <alice> two"),
                // Same name, same bot, DIFFERENT platform — a different person.
                message(3, nick: "bridge", text: "[Telegram] <alice> three"),
            ],
            networkId: 1
        )
        XCTAssertTrue(MessageGrouping.continuesRun(rows[1], after: rows[0]))
        XCTAssertFalse(MessageGrouping.continuesRun(rows[2], after: rows[1]))
    }

    /// A mark is per-(network, nick), so there is no answer to `/relay` in the system buffer — and
    /// the generic network gate is what has to say so, rather than the command writing a mark on
    /// some network it picked.
    func testRelayNeedsANetwork() {
        guard case let .command(effects) = CommandParser.parse("/relay", networkId: nil, target: ""),
              case let .info(text) = effects.first
        else { return XCTFail("expected a note") }
        XCTAssertTrue(text.contains("needs an active network"), text)
    }
}

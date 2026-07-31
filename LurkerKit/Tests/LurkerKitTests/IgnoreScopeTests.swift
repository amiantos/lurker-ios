// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Ignore rules from the wire to the answer: how the two scopes union, how the frames seed and
/// replace them, and the two surfaces that read them through the store.
///
/// The scope half is derived from the web client's `stores/ignores.test.ts` (lurker #350) —
/// the bug it exists to prevent is a global rule, which is what a bare `/ignore` creates, being
/// stored somewhere the per-network read never looks.
@MainActor
final class IgnoreScopeTests: XCTestCase {

    private func rule(mask: String, levels: [String] = ["ALL"]) -> IgnoreRule {
        IgnoreRule(mask: mask, levels: levels)
    }

    private func input(nick: String, target: String = "#chan") -> IgnoreInput {
        IgnoreInput(
            nick: nick, userhost: "\(nick)!u@h", target: target,
            text: "hello", type: .message, isDm: false
        )
    }

    // MARK: - Scope

    func testAGlobalRuleAppliesOnEveryNetworkAndANetworkRuleOnlyOnItsOwn() {
        let set = IgnoreSet(global: [rule(mask: "spammer")], byNetwork: [1: [rule(mask: "local")]])
        XCTAssertTrue(set.isHidden(networkId: 1, input(nick: "spammer")))
        XCTAssertTrue(set.isHidden(networkId: 2, input(nick: "spammer")))
        XCTAssertTrue(set.isHidden(networkId: 1, input(nick: "local")))
        XCTAssertFalse(
            set.isHidden(networkId: 2, input(nick: "local")),
            "a network-scoped rule must not leak to a sibling network"
        )
    }

    /// The system buffer has no network and its lines have no IRC sender, so the whole feature
    /// sits out — matching the web, whose render filter is gated on a truthy `networkId`.
    func testANilNetworkIsNeverFiltered() {
        let set = IgnoreSet(global: [rule(mask: "*")])
        XCTAssertTrue(set.isEmpty(for: nil))
        XCTAssertFalse(set.isHidden(networkId: nil, input(nick: "anyone")))
    }

    func testAnAccountWithNoRulesReadsEmptyForEveryNetwork() {
        XCTAssertTrue(IgnoreSet.empty.isEmpty(for: 1))
        // Globals alone still count as rules for every network, including one we've never
        // heard of — that's what makes the fast path safe to take.
        XCTAssertFalse(IgnoreSet(global: [rule(mask: "x")]).isEmpty(for: 99))
    }

    func testReplacingOneBucketLeavesTheOtherStanding() {
        let set = IgnoreSet(global: [rule(mask: "spammer")], byNetwork: [1: [rule(mask: "local")]])

        let globalsReplaced = set.replacing(networkId: nil, with: [])
        XCTAssertFalse(globalsReplaced.isHidden(networkId: 1, input(nick: "spammer")))
        XCTAssertTrue(
            globalsReplaced.isHidden(networkId: 1, input(nick: "local")),
            "clearing globals must not clear the network bucket"
        )

        let networkReplaced = set.replacing(networkId: 1, with: [])
        XCTAssertTrue(networkReplaced.isHidden(networkId: 1, input(nick: "spammer")))
        XCTAssertFalse(networkReplaced.isHidden(networkId: 1, input(nick: "local")))
    }

    /// An `-except` in one bucket has to beat a hide in the other, which only holds if the two
    /// are evaluated as one set rather than consulted in turn.
    func testAnExceptInOneBucketVetoesAHideInTheOther() {
        let set = IgnoreSet(
            global: [IgnoreRule(mask: "*!*@spam", levels: ["ALL"])],
            byNetwork: [1: [IgnoreRule(mask: "bob!*@spam", levels: ["ALL"], isExcept: true)]]
        )
        XCTAssertFalse(
            set.isHidden(
                networkId: 1,
                IgnoreInput(
                    nick: "bob", userhost: "bob!u@spam", target: "#chan",
                    text: "hi", type: .message, isDm: false
                )
            )
        )
    }

    // MARK: - Frames

    func testTheSnapshotSeedsBothBucketsAndReplacesThemWholesale() {
        let store = LurkerStore()
        store.apply(
            .snapshot(
                [
                    NetworkSnapshot(
                        id: 1, state: .connected, nick: "me", channels: [],
                        ignoredMasks: [rule(mask: "local")]
                    ),
                ],
                globalIgnores: [rule(mask: "spammer")]
            )
        )
        XCTAssertTrue(store.state.ignores.isHidden(networkId: 1, input(nick: "spammer")))
        XCTAssertTrue(store.state.ignores.isHidden(networkId: 1, input(nick: "local")))

        // A reconnect re-sends the account's whole rule set, so a rule deleted while this
        // device was away has to disappear rather than survive as a leftover.
        store.apply(
            .snapshot(
                [NetworkSnapshot(id: 1, state: .connected, nick: "me", channels: [])],
                globalIgnores: []
            )
        )
        XCTAssertTrue(store.state.ignores.isEmpty(for: 1))
    }

    func testIgnoreListUpdatedReplacesOnlyTheScopeItNames() {
        let store = LurkerStore()
        store.apply(
            .snapshot(
                [
                    NetworkSnapshot(
                        id: 1, state: .connected, nick: "me", channels: [],
                        ignoredMasks: [rule(mask: "local")]
                    ),
                ],
                globalIgnores: [rule(mask: "spammer")]
            )
        )
        // networkId nil is the GLOBAL bucket here — not the system buffer, which is what a nil
        // networkId means on every other frame.
        store.apply(.ignoreListUpdated(networkId: nil, rules: []))
        XCTAssertFalse(store.state.ignores.isHidden(networkId: 1, input(nick: "spammer")))
        XCTAssertTrue(store.state.ignores.isHidden(networkId: 1, input(nick: "local")))

        store.apply(.ignoreListUpdated(networkId: 1, rules: [rule(mask: "someone-else")]))
        XCTAssertFalse(store.state.ignores.isHidden(networkId: 1, input(nick: "local")))
        XCTAssertTrue(store.state.ignores.isHidden(networkId: 1, input(nick: "someone-else")))
    }

    func testTheWireShapeParsesIntoARule() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"ignore-list-updated","networkId":7,"masks":[
          {"id":3,"mask":"bob!*@spam","channels":["#chan"],"pattern":"word",
           "patternKind":"full","levels":["PUBLIC","NOHIGHLIGHT"],"isExcept":true,
           "expiresAt":"2999-01-01T00:00:00.000Z","createdAt":"2026-01-01T00:00:00.000Z"}
        ]}
        """##)
        guard case let .ignoreListUpdated(networkId, rules) = frame else {
            return XCTFail("expected ignoreListUpdated, got \(frame)")
        }
        XCTAssertEqual(networkId, 7)
        XCTAssertEqual(rules.count, 1)
        let rule = rules[0]
        XCTAssertEqual(rule.id, 3)
        XCTAssertEqual(rule.mask, "bob!*@spam")
        XCTAssertEqual(rule.channels, ["#chan"])
        XCTAssertEqual(rule.pattern, "word")
        XCTAssertEqual(rule.patternKind, .full)
        XCTAssertEqual(rule.levels, ["PUBLIC", "NOHIGHLIGHT"])
        XCTAssertTrue(rule.isExcept)
        XCTAssertEqual(rule.expiresAt, ISOTime.parse("2999-01-01T00:00:00.000Z"))
    }

    /// A global-scope update carries `networkId: null`, which must not read as network 0.
    func testANullNetworkIdParsesAsTheGlobalScope() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"ignore-list-updated","networkId":null,"masks":[]}"##
        )
        guard case let .ignoreListUpdated(networkId, _) = frame else {
            return XCTFail("expected ignoreListUpdated, got \(frame)")
        }
        XCTAssertNil(networkId)
    }

    /// Every optional field absent is a legal rule — the shape a bare `/ignore nick` produces.
    func testAMinimalRuleParsesWithEverythingUnconstrained() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"snapshot","networks":[],"globalIgnores":[
          {"id":1,"mask":"bob","channels":null,"pattern":null,"patternKind":"substr",
           "levels":["ALL"],"isExcept":false,"expiresAt":null}
        ]}
        """##)
        guard case let .snapshot(_, globalIgnores) = frame else {
            return XCTFail("expected snapshot, got \(frame)")
        }
        XCTAssertEqual(globalIgnores.count, 1)
        XCTAssertNil(globalIgnores[0].channels)
        XCTAssertNil(globalIgnores[0].pattern)
        XCTAssertNil(globalIgnores[0].expiresAt)
    }

    // MARK: - Store-level readers

    /// The typing filter lives in `typists(in:)` so every surface that shows composing peers
    /// gets it without asking. Only a whole-identity rule counts — a tag carries no body.
    func testAnIgnoredPeerIsNotReportedAsTyping() {
        var state = ChatState()
        let key = BufferKey(networkId: 1, target: "#chan")
        state.buffers[key.id] = Buffer(networkId: 1, target: "#chan", kind: .channel)
        let now = Date(timeIntervalSince1970: 1_000_000)
        state.typing[key.id] = [
            "bob": TypingEntry(
                nick: "bob", activity: .active, startedAt: now,
                expiresAt: now.addingTimeInterval(6), userhost: "bob!u@h"
            ),
            "alice": TypingEntry(
                nick: "alice", activity: .active, startedAt: now.addingTimeInterval(1),
                expiresAt: now.addingTimeInterval(7), userhost: "alice!u@h"
            ),
        ]
        XCTAssertEqual(state.typists(in: key, now: now), ["bob", "alice"])

        state.ignores = IgnoreSet(global: [rule(mask: "bob")])
        XCTAssertEqual(state.typists(in: key, now: now), ["alice"])

        // A level-scoped rule says nothing about a typing tag, so it leaves them showing.
        state.ignores = IgnoreSet(global: [rule(mask: "bob", levels: ["JOINS"])])
        XCTAssertEqual(state.typists(in: key, now: now), ["bob", "alice"])
    }

    func testAMutedBufferIsReportedByTheSetTheBufferListReads() {
        let set = IgnoreSet(
            byNetwork: [1: [IgnoreRule(channels: ["#loud"], levels: ["NOUNREAD", "NONOTIFY"])]]
        )
        XCTAssertTrue(set.mutesUnread(networkId: 1, target: "#loud"))
        XCTAssertFalse(set.mutesUnread(networkId: 1, target: "#quiet"))
        XCTAssertFalse(set.mutesUnread(networkId: 2, target: "#loud"))
        XCTAssertFalse(set.mutesUnread(networkId: nil, target: "#loud"))
    }

    /// The feeds' reader. A self-authored or sender-less row is never hidden, and level rules
    /// apply here too — the whole reason it isn't just `isIgnored`.
    func testIsMessageHiddenJudgesAFeedRowInItsOwnBuffer() {
        let set = IgnoreSet(global: [rule(mask: "bob", levels: ["PUBLIC"])])
        func message(nick: String?, isSelf: Bool = false) -> Message {
            Message(
                id: 1, type: .message, nick: nick, text: "hi", isSelf: isSelf,
                userhost: nick.map { "\($0)!u@h" }
            )
        }
        XCTAssertTrue(
            set.isMessageHidden(networkId: 1, message: message(nick: "bob"), target: "#chan")
        )
        XCTAssertFalse(
            set.isMessageHidden(networkId: 1, message: message(nick: "bob"), target: "alice"),
            "PUBLIC covers channel messages; a DM row is MSGS"
        )
        XCTAssertFalse(
            set.isMessageHidden(networkId: 1, message: message(nick: nil), target: "#chan")
        )
        XCTAssertFalse(
            set.isMessageHidden(
                networkId: 1, message: message(nick: "bob", isSelf: true), target: "#chan"
            ),
            "your own line is never hidden by a rule that happens to cover your nick"
        )
    }

    // MARK: - Completion

    func testNickCompletionDropsAnIgnoredCandidate() {
        let members = [
            Member(nick: "bobby", user: "u", host: "h"),
            Member(nick: "bonnie", user: "u", host: "h"),
        ]
        let messages = [Message(id: 1, type: .message, nick: "bobby", text: "hi")]
        let set = IgnoreSet(global: [rule(mask: "bobby")])
        let candidates = NickCompletion.candidates(
            messages: messages, members: members, selfNick: "me", query: "bo", isChannel: true,
            isIgnored: { set.isIgnored(networkId: 1, nick: $0, userhost: $1) }
        )
        XCTAssertEqual(candidates, ["bonnie"])
    }

    /// A hostmask-only rule reaches a member (whose user/host the server sent) and not a
    /// speaker who has since left the channel and carries no mask — the same information the
    /// web has at the same point, so the same answer.
    func testACompletionCandidateIsJudgedOnItsReconstructedHostmask() {
        let members = [Member(nick: "bobby", user: "spam", host: "evil.example")]
        let set = IgnoreSet(global: [rule(mask: "*!spam@evil.example")])
        XCTAssertEqual(
            NickCompletion.candidates(
                messages: [], members: members, selfNick: "me", query: "bo", isChannel: true,
                isIgnored: { set.isIgnored(networkId: 1, nick: $0, userhost: $1) }
            ),
            []
        )
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// IRCv3 replies (iOS #184): the wire, the display rules, the Reply gate, the send.
final class RepliesTests: XCTestCase {

    private func line(
        _ id: Int = 1, nick: String = "bob", text: String = "hi", type: EventType = .message,
        isSelf: Bool = false, msgid: String? = "m1", e2e: Bool = false, replyTo: ReplyContext? = nil
    ) -> Message {
        Message(id: id, type: type, nick: nick, text: text, isSelf: isSelf, msgid: msgid, isE2E: e2e, replyTo: replyTo)
    }

    private let alice = ReplyParent(id: 7, nick: "alice", type: .message, text: "has anyone tried it?", userhost: "alice!a@host")

    // MARK: - Wire

    func testRowsCarryReplyToAndTheStamp() {
        let frame = FrameParser.parseWs(##"""
        {"kind":"backlog","networkId":1,"target":"#c","hasMoreOlder":false,"events":[
          {"id":2,"type":"message","nick":"bob","text":"alice: yes","replyTo":{"msgid":"p1","parent":{"id":7,"nick":"alice","type":"action","text":"waves","userhost":"alice!a@h","self":true}},"replyToSelf":true,"matched":true},
          {"id":3,"type":"message","nick":"bob","text":"x","replyTo":{"msgid":"gone","parent":null}},
          {"id":4,"type":"message","nick":"bob","text":"plain"}
        ]}
        """##)
        guard case let .backlog(_, messages, _, _, _) = frame else { return XCTFail("\(frame)") }
        XCTAssertEqual(messages[0].replyTo, ReplyContext(
            msgid: "p1",
            parent: ReplyParent(id: 7, nick: "alice", type: .action, text: "waves", userhost: "alice!a@h", isSelf: true)
        ))
        XCTAssertTrue(messages[0].replyToSelf)
        XCTAssertEqual(messages[1].replyTo, ReplyContext(msgid: "gone", parent: nil), "a reply with nothing to quote is still a reply")
        XCTAssertNil(messages[2].replyTo)
        XCTAssertFalse(messages[2].replyToSelf)
    }

    // MARK: - Text

    func testStripAddressNeedsPunctuationAfterTheNick() {
        XCTAssertEqual(Replies.stripAddress("alice: yes", nick: "alice"), "yes")
        XCTAssertEqual(Replies.stripAddress("ALICE, yes", nick: "alice"), "yes", "case-folded")
        XCTAssertEqual(Replies.stripAddress("will you come?", nick: "will"), "will you come?", "a word, not an address")
        XCTAssertEqual(Replies.stripAddress("bob_: hi", nick: "bob"), "bob_: hi", "bob_ is somebody else")
        XCTAssertEqual(Replies.stripAddress("alice: ", nick: "alice"), "alice: ", "never strips to nothing")
        XCTAssertEqual(Replies.stripAddress("a.b: x", nick: "a.b"), "x", "the nick is matched literally")
    }

    func testExcerptIsOnePlainLine() {
        XCTAssertEqual(Replies.excerpt("\u{02}bold\u{02} and\n\n  more\n"), "bold and more")
    }

    func testConsumes() {
        XCTAssertTrue(Replies.consumes("hello"))
        XCTAssertTrue(Replies.consumes("//not a command"))
        XCTAssertTrue(Replies.consumes("/me waves"))
        XCTAssertTrue(Replies.consumes("/ME waves"))
        XCTAssertFalse(Replies.consumes("/me "))
        XCTAssertFalse(Replies.consumes("/mean"))
        XCTAssertFalse(Replies.consumes("/whois bob"))
        XCTAssertFalse(Replies.consumes("/slap bob"))
        XCTAssertFalse(Replies.consumes(""))
    }

    // MARK: - Shown

    private func shown(
        _ reply: Message, ignores: IgnoreSet = .empty, relayBots: RelayBotSet = .empty, ownNick: String? = "me"
    ) -> (quote: ReplyQuote?, text: String?) {
        Replies.shown(reply.replyTo!, line: reply, networkId: 1, target: "#c",
                      ignores: ignores, relayBots: relayBots, ownNick: ownNick)
    }

    func testQuoteAndStrippedText() {
        let reply = line(text: "alice: yes", replyTo: ReplyContext(msgid: "p", parent: alice))
        let result = shown(reply)
        XCTAssertEqual(result.quote?.nick, "alice")
        XCTAssertEqual(result.quote?.id, 7)
        XCTAssertEqual(result.text, "yes")
    }

    func testNoQuoteKeepsTheAddressItIsTheOnlySignOfWhoItsTo() {
        let result = shown(line(text: "alice: yes", replyTo: ReplyContext(msgid: "p", parent: nil)))
        XCTAssertNil(result.quote)
        XCTAssertEqual(result.text, "alice: yes")
    }

    func testAnActionKeepsItsText() {
        let result = shown(line(text: "alice: waves", type: .action, replyTo: ReplyContext(msgid: "p", parent: alice)))
        XCTAssertEqual(result.text, "alice: waves")
    }

    func testIgnoredSinceHidesTheQuoteButNotYourOwnLine() {
        let ignores = IgnoreSet(global: [IgnoreRule(id: 1, mask: "alice!*@*")], byNetwork: [:])
        let result = shown(line(text: "alice: yes", replyTo: ReplyContext(msgid: "p", parent: alice)), ignores: ignores)
        XCTAssertNil(result.quote, "ignored after the reply arrived")
        XCTAssertEqual(result.text, "alice: yes")

        let mine = ReplyParent(id: 7, nick: "alice", type: .message, text: "x", userhost: "alice!a@host", isSelf: true)
        XCTAssertNotNil(shown(line(replyTo: ReplyContext(msgid: "p", parent: mine)), ignores: ignores).quote)
    }

    func testARelayedParentQuotesThePersonInside() {
        let bots = RelayBotSet.empty.applying(networkId: 1, nick: "bridge", marked: true, pattern: "")
        let parent = ReplyParent(id: 7, nick: "bridge", type: .message, text: "<carol> hello there")
        let viaSpeaker = shown(line(text: "carol: hi", replyTo: ReplyContext(msgid: "p", parent: parent)), relayBots: bots)
        XCTAssertEqual(viaSpeaker.quote?.nick, "carol")
        XCTAssertEqual(viaSpeaker.quote?.text, "hello there")
        XCTAssertEqual(viaSpeaker.quote?.relayBot, "bridge")
        XCTAssertEqual(viaSpeaker.text, "hi")
        // halloy addresses the bot, which knows nothing of relay marks.
        let viaBot = shown(line(text: "bridge: hi", replyTo: ReplyContext(msgid: "p", parent: parent)), relayBots: bots)
        XCTAssertEqual(viaBot.text, "hi")
        // The person inside is you when they carry your nick.
        let echo = ReplyParent(id: 7, nick: "bridge", type: .message, text: "<me> mine")
        XCTAssertEqual(shown(line(replyTo: ReplyContext(msgid: "p", parent: echo)), relayBots: bots).quote?.isSelf, true)
    }

    func testASplitReplyIsQuotedOnce() {
        let context = ReplyContext(msgid: "p", parent: alice)
        let first = line(1, replyTo: context)
        XCTAssertTrue(Replies.continues(line(2, replyTo: context), after: first))
        XCTAssertFalse(Replies.continues(line(2, nick: "carol", replyTo: context), after: first))
        XCTAssertFalse(Replies.continues(line(2, replyTo: ReplyContext(msgid: "q", parent: nil)), after: first))
        XCTAssertFalse(Replies.continues(line(2, type: .action, replyTo: context), after: first))
        XCTAssertFalse(Replies.continues(line(2, replyTo: context), after: line(1)))
        XCTAssertFalse(Replies.continues(line(2, replyTo: context), after: nil))
    }

    // MARK: - Reply gate

    private func replyTitle(_ message: Message, target: String, canReact: Bool) -> String? {
        MessageActions.build(
            for: message,
            scope: MessageActionScope(networkId: 1, isBookmarked: false, target: target, canReact: canReact)
        ).first { $0.key == .reply }?.title
    }

    func testChannelReplyIsAlwaysOffered() {
        XCTAssertEqual(replyTitle(line(), target: "#c", canReact: false), "Reply to bob")
        XCTAssertEqual(replyTitle(line(msgid: nil), target: "#c", canReact: false), "Reply to bob", "it still addresses them")
    }

    func testYourOwnLineIsTagOnly() {
        XCTAssertEqual(replyTitle(line(isSelf: true), target: "#c", canReact: true), "Reply to yourself")
        XCTAssertNil(replyTitle(line(isSelf: true), target: "#c", canReact: false))
        XCTAssertNil(replyTitle(line(isSelf: true, msgid: nil), target: "#c", canReact: true))
    }

    func testADmIsTagOnly() {
        XCTAssertEqual(replyTitle(line(), target: "bob", canReact: true), "Reply to bob")
        XCTAssertNil(replyTitle(line(), target: "bob", canReact: false))
        XCTAssertNil(replyTitle(line(e2e: true), target: "bob", canReact: true))
        XCTAssertNil(replyTitle(line(), target: "=bob", canReact: true), "a DCC chat carries no tags")
    }

    func testReplyableNeedsAStampedConversationLine() {
        XCTAssertTrue(Replies.replyable(line(type: .notice), target: "#c"))
        XCTAssertFalse(Replies.replyable(line(0), target: "#c"))
        XCTAssertFalse(Replies.replyable(line(msgid: nil), target: "#c"))
        XCTAssertFalse(Replies.replyable(line(e2e: true), target: "#c"))
        XCTAssertFalse(Replies.replyable(line(type: .join), target: "#c"))
        XCTAssertFalse(Replies.replyable(line(), target: ":server:1"))
    }

    // MARK: - Refusals give the reply back

    @MainActor
    func testARefusedLineComesHomeWithItsReply() {
        var correlator = UnsentCorrelator()
        let key = BufferKey(networkId: 1, target: "#c")
        let pending = PendingReply(messageId: 7, nick: "alice", type: .message, text: "x", isSelf: false, addressed: true)
        let id = correlator.track(key, line: "alice: yes", reply: pending)
        let origin = correlator.resolve(clientId: id, ok: false)
        XCTAssertEqual(origin?.reply, pending)

        let store = LurkerStore()
        store.holdUnsent(key, text: "alice: yes", reply: pending)
        XCTAssertEqual(store.takeUnsentLine(key), UnsentLine(text: "alice: yes", reply: pending))
    }
}

final class ReplyPresentingTests: XCTestCase {
    func testPresentingSetsTheQuoteAndTextAndPassesOthersThrough() {
        let parent = ReplyParent(id: 7, nick: "alice", type: .message, text: "q")
        let reply = Message(id: 2, type: .message, nick: "bob", text: "alice: yes", replyTo: ReplyContext(msgid: "p", parent: parent))
        let plain = Message(id: 3, type: .message, nick: "bob", text: "alice: plain")
        let out = Replies.presenting([reply, plain], networkId: 1, target: "#c", ignores: .empty, relayBots: .empty, ownNick: "me")
        XCTAssertEqual(out[0].replyQuote?.nick, "alice")
        XCTAssertEqual(out[0].text, "yes")
        XCTAssertEqual(out[0].id, 2)
        XCTAssertEqual(out[1], plain)
    }
}

/// Cancelling a pending reply takes back only the address its Reply put there (iOS #184).
final class RemovingAddressTests: XCTestCase {
    func testTakesBackTheAddressAndNothingElse() {
        XCTAssertEqual(NickCompletion.removingAddress("alice: hi there", to: "alice", punctuation: ":"), "hi there")
        XCTAssertEqual(NickCompletion.removingAddress("alice: ", to: "alice", punctuation: ":"), "")
        XCTAssertEqual(NickCompletion.removingAddress("Alice, hi", to: "alice", punctuation: ":"), "hi", "any mark, folded")
        XCTAssertEqual(NickCompletion.removingAddress("alice-> hi", to: "alice", punctuation: "->"), "hi", "the configured mark verbatim")
    }

    func testLeavesADraftThatNoLongerOpensWithIt() {
        XCTAssertEqual(NickCompletion.removingAddress("hey alice: hi", to: "alice", punctuation: ":"), "hey alice: hi")
        XCTAssertEqual(NickCompletion.removingAddress("alice_: hi", to: "alice", punctuation: ":"), "alice_: hi")
        XCTAssertEqual(NickCompletion.removingAddress("will you come", to: "will", punctuation: ":"), "will you come")
    }

    func testIsAddressedStillAgrees() {
        XCTAssertTrue(NickCompletion.isAddressed("alice: hi", to: "alice", punctuation: ":"))
        XCTAssertFalse(NickCompletion.isAddressed("alice hi", to: "alice", punctuation: ":"))
        XCTAssertTrue(NickCompletion.isAddressed("alice hi", to: "alice", punctuation: ""))
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the @‑mention logic to the web client's `nickCompletion.ts`: speakers before
/// members, recency order, self excluded, departed speakers dropped in channels — plus
/// the token scanner and the addressing suffix the composer inserts.
final class NickCompletionTests: XCTestCase {

    private func speech(_ id: Int, _ nick: String, isSelf: Bool = false) -> Message {
        Message(id: id, type: .message, nick: nick, text: "hi", isSelf: isSelf)
    }

    // MARK: - Candidates

    func testRecentSpeakersLeadNewestFirstThenMembersAlphabetically() {
        let candidates = NickCompletion.candidates(
            messages: [speech(1, "alice"), speech(2, "bob")],
            members: [Member(nick: "zoe"), Member(nick: "alice"), Member(nick: "bob"), Member(nick: "carol")],
            selfNick: "me",
            query: "",
            isChannel: true
        )
        XCTAssertEqual(candidates, ["bob", "alice", "carol", "zoe"],
                       "bob spoke last → first; then alice; members fill the rest A→Z")
    }

    func testFilteringIsCaseInsensitiveAndKeepsRecencyOrder() {
        let candidates = NickCompletion.candidates(
            messages: [speech(1, "Anna"), speech(2, "arthur")],
            members: [Member(nick: "Anna"), Member(nick: "arthur"), Member(nick: "AXEL"), Member(nick: "bob")],
            selfNick: nil,
            query: "a",
            isChannel: true
        )
        XCTAssertEqual(candidates, ["arthur", "Anna", "AXEL"])
    }

    func testYouAreNeverACandidate() {
        let candidates = NickCompletion.candidates(
            messages: [speech(1, "ME", isSelf: true), speech(2, "alice")],
            members: [Member(nick: "me"), Member(nick: "alice")],
            selfNick: "me",
            query: "",
            isChannel: true
        )
        XCTAssertEqual(candidates, ["alice"], "self is excluded as speaker and as member, case-folded")
    }

    /// The web filters channel speakers by current membership: completing someone who
    /// left addresses nobody. A DM has no member list, so its speakers pass unfiltered.
    func testADepartedSpeakerIsDroppedInChannelsButNotDMs() {
        let history = [speech(1, "ghost"), speech(2, "alice")]
        let inChannel = NickCompletion.candidates(
            messages: history, members: [Member(nick: "alice")],
            selfNick: nil, query: "", isChannel: true
        )
        XCTAssertEqual(inChannel, ["alice"])

        let inDM = NickCompletion.candidates(
            messages: history, members: [],
            selfNick: nil, query: "", isChannel: false
        )
        XCTAssertEqual(inDM, ["alice", "ghost"])
    }

    func testOnlySpeechCountsAsSpeakingAndTheCapHolds() {
        let noisy: [Message] = [
            speech(1, "alice"),
            Message(id: 2, type: .join, nick: "joiner", text: nil),
            Message(id: 3, type: .notice, nick: "noticebot", text: "psa"),
            Message(id: 4, type: .action, nick: "bob", text: "waves"),
        ]
        let members = ["alice", "bob", "joiner", "noticebot", "carol", "dave"].map { Member(nick: $0) }
        let candidates = NickCompletion.candidates(
            messages: noisy, members: members, selfNick: nil, query: "", isChannel: true
        )
        XCTAssertEqual(candidates.count, 4, "capped at four")
        XCTAssertEqual(Array(candidates.prefix(2)), ["bob", "alice"],
                       "an action speaks; a join or notice does not")
    }

    // MARK: - Token scanning

    func testAnAtTokenUnderTheCaretIsActive() {
        let token = NickCompletion.activeMention(in: "hey @al", caret: 7)
        XCTAssertEqual(token, NickCompletion.MentionToken(start: 4, query: "al"))
    }

    func testABareAtOpensAnEmptyQuery() {
        XCTAssertEqual(NickCompletion.activeMention(in: "@", caret: 1)?.query, "")
    }

    func testAnEmailShapedWordIsNotAMention() {
        XCTAssertNil(NickCompletion.activeMention(in: "mail user@host", caret: 14),
                     "the @ must open the word — matching the web's startsWith('@')")
    }

    func testACaretOutsideTheTokenDeactivatesIt() {
        XCTAssertNil(NickCompletion.activeMention(in: "@al done", caret: 8),
                     "past the token's word there is no active mention")
        XCTAssertNil(NickCompletion.activeMention(in: "plain text", caret: 5))
    }

    // MARK: - Addressing suffix

    func testLineStartAddressesWithColonMidSentenceWithSpace() {
        XCTAssertEqual(NickCompletion.addressingSuffix(beforeTokenAt: 0, in: "@al"), ": ")
        // Only spaces before the token still counts as line start…
        XCTAssertEqual(NickCompletion.addressingSuffix(beforeTokenAt: 2, in: "  @al"), ": ")
        // …and so does the start of a wrapped line.
        XCTAssertEqual(NickCompletion.addressingSuffix(beforeTokenAt: 6, in: "hello\n@al"), ": ")
        XCTAssertEqual(NickCompletion.addressingSuffix(beforeTokenAt: 4, in: "cc: @al"), " ")
    }
}

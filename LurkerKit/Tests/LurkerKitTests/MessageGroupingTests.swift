// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Run grouping — the part of bubble rendering that keeps a channel readable.
final class MessageGroupingTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(
        _ nick: String,
        _ text: String = "hi",
        type: EventType = .message,
        isSelf: Bool = false,
        at offset: TimeInterval = 0
    ) -> Message {
        Message(
            id: Int(offset) + 1, type: type, nick: nick, text: text,
            isSelf: isSelf, date: base.addingTimeInterval(offset)
        )
    }

    // MARK: - The basics

    func testTheFirstMessageStartsARun() {
        XCTAssertFalse(MessageGrouping.continuesRun(message("alice"), after: nil))
    }

    func testSameNickBackToBackContinuesTheRun() {
        let first = message("alice", at: 0)
        XCTAssertTrue(MessageGrouping.continuesRun(message("alice", at: 10), after: first))
    }

    func testADifferentNickBreaksTheRun() {
        let first = message("alice", at: 0)
        XCTAssertFalse(MessageGrouping.continuesRun(message("bob", at: 10), after: first))
    }

    // MARK: - Case folding

    func testNickCaseDoesNotBreakARun() {
        // IRC nicks are case-insensitive and servers send them inconsistently cased, so
        // `Alice` following `alice` is the same person mid-sentence, not a new speaker.
        let first = message("alice", at: 0)
        XCTAssertTrue(MessageGrouping.continuesRun(message("Alice", at: 5), after: first))
    }

    // MARK: - Time

    func testALongGapBreaksTheRunEvenForTheSameNick() {
        let first = message("alice", at: 0)
        let later = message("alice", at: MessageGrouping.runGap + 1)
        XCTAssertFalse(
            MessageGrouping.continuesRun(later, after: first),
            "two messages hours apart are not one conversation"
        )
    }

    func testExactlyTheGapStillGroups() {
        let first = message("alice", at: 0)
        XCTAssertTrue(MessageGrouping.continuesRun(message("alice", at: MessageGrouping.runGap), after: first))
    }

    func testAMissingTimestampFallsBackToTheAuthorRatherThanSplitting() {
        let undated = Message(id: 2, type: .message, nick: "alice", text: "hi", date: nil)
        XCTAssertTrue(MessageGrouping.continuesRun(undated, after: message("alice", at: 0)))
    }

    // MARK: - Self

    func testOurOwnMessagesDoNotJoinSomeoneElsesRun() {
        // Same nick, opposite sides of the screen — a run that spanned them would have to
        // render in two places at once.
        let theirs = message("alice", isSelf: false, at: 0)
        let ours = message("alice", isSelf: true, at: 1)
        XCTAssertFalse(MessageGrouping.continuesRun(ours, after: theirs))
    }

    // MARK: - Only bubbles group

    func testActionsAndNoticesBreakRuns() {
        // They render as full-width lines, so they can't be inside a bubble run — and an
        // action between two of alice's messages is a real interruption anyway.
        let first = message("alice", at: 0)
        XCTAssertFalse(
            MessageGrouping.continuesRun(message("alice", type: .action, at: 1), after: first),
            "an action is not a bubble"
        )
        XCTAssertFalse(
            MessageGrouping.continuesRun(message("alice", type: .notice, at: 1), after: first),
            "a notice is not a bubble"
        )
        XCTAssertFalse(
            MessageGrouping.continuesRun(message("alice", at: 2), after: message("alice", type: .action, at: 1)),
            "and a message cannot continue a run an action started"
        )
    }

    /// Everything is a bubble except narration. Sorting lines into bubbles vs. log output
    /// by how "conversational" they seemed kept drawing plain conversations as logs — your
    /// DM to NickServ bubbling while its reply didn't. An action stays a line because the
    /// actor is inside the sentence, so a captioned bubble would name them twice.
    func testEverythingBubblesExceptNarration() {
        XCTAssertTrue(EventType.message.isBubble)
        XCTAssertTrue(EventType.notice.isBubble)
        XCTAssertTrue(EventType.system.isBubble)
        XCTAssertTrue(EventType.motd.isBubble)
        XCTAssertFalse(EventType.action.isBubble)
    }

    /// Both are bubbles now, so "both are bubbles" is no longer enough to group them: a bot
    /// uses NOTICE precisely to mark a line as not-a-reply, and a run captions once, so
    /// grouping a message with a notice would render the rest of them identically and erase
    /// the distinction the sender chose.
    func testAMessageAndANoticeFromTheSameNickDoNotGroup() {
        XCTAssertFalse(
            MessageGrouping.continuesRun(
                message("nickserv", type: .notice, at: 2),
                after: message("nickserv", at: 1)
            ),
            "a notice must not continue a message's run"
        )
        XCTAssertTrue(
            MessageGrouping.continuesRun(
                message("nickserv", type: .notice, at: 2),
                after: message("nickserv", type: .notice, at: 1)
            ),
            "but notices group with each other"
        )
    }
}

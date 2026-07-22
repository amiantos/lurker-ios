// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the command-completion classifier: what the caret is sitting in (a verb, a channel
/// argument, a nick argument, or nothing the app can suggest for) and the token range a pick
/// replaces. UTF-16 offsets throughout, like `NickCompletion`.
final class CommandCompletionTests: XCTestCase {

    // MARK: - Command name

    func testBareSlashOffersEveryCommand() {
        XCTAssertEqual(
            CommandCompletion.context(in: "/", caret: 1),
            .command(query: "", range: NSRange(location: 0, length: 1))
        )
    }

    func testTypingTheVerbFiltersCommands() {
        XCTAssertEqual(
            CommandCompletion.context(in: "/jo", caret: 3),
            .command(query: "jo", range: NSRange(location: 0, length: 3))
        )
    }

    func testCaretMidVerbSwallowsTheWholeVerbToken() {
        // Caret after "/jo" inside "/join": the range still covers the whole verb, so
        // completing replaces "/join" rather than welding onto "in".
        XCTAssertEqual(
            CommandCompletion.context(in: "/join", caret: 3),
            .command(query: "jo", range: NSRange(location: 0, length: 5))
        )
    }

    // MARK: - Channel arguments

    func testChannelArgumentUnderCaret() {
        XCTAssertEqual(
            CommandCompletion.context(in: "/join #li", caret: 9),
            .argument(verb: "join", index: 0, kind: .channel, query: "#li",
                      range: NSRange(location: 6, length: 3))
        )
    }

    func testEmptyChannelSlotAfterTheSpace() {
        XCTAssertEqual(
            CommandCompletion.context(in: "/join ", caret: 6),
            .argument(verb: "join", index: 0, kind: .channel, query: "",
                      range: NSRange(location: 6, length: 0))
        )
    }

    func testChannelArgumentMidWordSwallowsTheTail() {
        XCTAssertEqual(
            CommandCompletion.context(in: "/join #linux", caret: 9),
            .argument(verb: "join", index: 0, kind: .channel, query: "#li",
                      range: NSRange(location: 6, length: 6))
        )
    }

    // MARK: - Nick arguments

    func testNickArgumentUnderCaret() {
        XCTAssertEqual(
            CommandCompletion.context(in: "/msg al", caret: 7),
            .argument(verb: "msg", index: 0, kind: .nick, query: "al",
                      range: NSRange(location: 5, length: 2))
        )
    }

    func testInviteSecondArgumentIsAChannel() {
        XCTAssertEqual(
            CommandCompletion.context(in: "/invite bob #", caret: 13),
            .argument(verb: "invite", index: 1, kind: .channel, query: "#",
                      range: NSRange(location: 12, length: 1))
        )
    }

    // MARK: - No completion

    func testFreeTextSlotYieldsNothing() {
        // `/me`'s argument is free text — no chips here (the composer falls through to
        // @-mention detection).
        XCTAssertNil(CommandCompletion.context(in: "/me hello", caret: 9))
    }

    func testChannelKeySlotYieldsNothing() {
        // The second `/join` argument is an opaque key.
        XCTAssertNil(CommandCompletion.context(in: "/join #x k", caret: 10))
    }

    func testNewNickSlotYieldsNothing() {
        XCTAssertNil(CommandCompletion.context(in: "/nick bo", caret: 8))
    }

    func testUnknownVerbYieldsNothing() {
        XCTAssertNil(CommandCompletion.context(in: "/frob x", caret: 7))
    }

    func testEscapeYieldsNothing() {
        XCTAssertNil(CommandCompletion.context(in: "//slap", caret: 6))
    }

    func testPlainTextYieldsNothing() {
        XCTAssertNil(CommandCompletion.context(in: "hello", caret: 5))
    }

    // MARK: - Registry

    func testMatchingIsPrefixOnCanonicalNames() {
        XCTAssertEqual(CommandRegistry.matching("j").map(\.name), ["join"])
    }

    func testMatchingEmptyReturnsCappedList() {
        XCTAssertEqual(CommandRegistry.matching("").count, 6)
    }

    func testAliasesResolveToOneSpec() {
        // `/query` is an alias of `/msg`; the chips shouldn't offer both.
        XCTAssertEqual(CommandRegistry.spec(for: "query")?.name, "msg")
        XCTAssertFalse(CommandRegistry.matching("q").contains { $0.name == "query" })
    }
}

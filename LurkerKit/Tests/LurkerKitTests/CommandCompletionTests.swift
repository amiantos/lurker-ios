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

    func testMatchingEmptyReturnsTheFeaturedStarterSet() {
        // A bare `/` shows a cross-category starter set, not just the first table block.
        let names = CommandRegistry.matching("").map(\.name)
        XCTAssertEqual(names, CommandRegistry.featured)
        XCTAssertTrue(names.contains("join"), "discovery must surface /join, not only Messaging")
    }

    func testAliasesResolveToOneSpec() {
        // `/query` is an alias of `/msg`; the chips shouldn't offer both.
        XCTAssertEqual(CommandRegistry.spec(for: "query")?.name, "msg")
        XCTAssertFalse(CommandRegistry.matching("q").contains { $0.name == "query" })
    }

    // MARK: - ChannelName

    func testChannelFoldMatchesRegardlessOfSigil() {
        // The `#` a user hasn't typed yet shouldn't hide a channel: `li` and `#li` both fold
        // to the same needle that prefix-matches `#linux`.
        XCTAssertEqual(ChannelName.fold("#Linux"), "linux")
        XCTAssertTrue(ChannelName.fold("#linux").hasPrefix(ChannelName.fold("li")))
        XCTAssertTrue(ChannelName.fold("#linux").hasPrefix(ChannelName.fold("#li")))
    }

    func testChannelEnsurePrefix() {
        XCTAssertEqual(ChannelName.ensurePrefix("linux"), "#linux")
        XCTAssertEqual(ChannelName.ensurePrefix("&local"), "&local")
        XCTAssertEqual(ChannelName.ensurePrefix("+nomodes"), "+nomodes")
        XCTAssertEqual(ChannelName.ensurePrefix("!12345safe"), "!12345safe")
    }

    /// The one classification both tiers mirror (`shared/channels.ts:isChannelTarget`).
    /// Asserted directly, not only through its callers, because a `#`-only twin of it is the
    /// bug that keeps recurring (lurker#724, lurker-ios#98).
    func testChannelTargetCountsAllFourSigils() {
        for target in ["#chan", "&local", "+nomodes", "!12345safe"] {
            XCTAssertTrue(ChannelName.isChannelTarget(target), target)
            XCTAssertEqual(BufferKind.of(networkId: 1, target: target), .channel, target)
        }
        for target in ["", "alice", ":server:1", "chan#notleading"] {
            XCTAssertFalse(ChannelName.isChannelTarget(target), target)
        }
    }

    /// The sort/display strip, the web's `stripChannelPrefix`. The buffer list's sort key
    /// hand-wrote half the set (`#&`), so `+`/`!` channels sorted under their sigil — above
    /// every named channel — while the web sorted them by name (lurker-ios#98).
    func testStripSigilsTakesEveryLeadingSigil() {
        XCTAssertEqual(ChannelName.stripSigils("#linux"), "linux")
        XCTAssertEqual(ChannelName.stripSigils("&local"), "local")
        XCTAssertEqual(ChannelName.stripSigils("+nomodes"), "nomodes")
        XCTAssertEqual(ChannelName.stripSigils("!12345safe"), "12345safe")
        // Every LEADING one — `##anime` sorts as "anime", not "#anime".
        XCTAssertEqual(ChannelName.stripSigils("##anime"), "anime")
        // Interior sigils are part of the name; a bare nick is untouched.
        XCTAssertEqual(ChannelName.stripSigils("chan#notleading"), "chan#notleading")
        XCTAssertEqual(ChannelName.stripSigils("alice"), "alice")
        XCTAssertEqual(ChannelName.stripSigils(""), "")
    }
}

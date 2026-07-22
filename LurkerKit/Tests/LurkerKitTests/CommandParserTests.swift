// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the slash-command parser to the web client's `handleCommand` dispatcher: the same
/// verbs translate to the same wire effects, the `//` escape sends a literal slash, the
/// system buffer gates network commands, and an unknown verb falls through to `raw`.
final class CommandParserTests: XCTestCase {

    /// A command issued from a channel buffer on network 1.
    private func parse(_ input: String, networkId: Int? = 1, target: String = "#chan") -> ParsedInput {
        CommandParser.parse(input, networkId: networkId, target: target)
    }

    /// The effects of a command (fails the test if the input parsed as a message/notCommand).
    private func effects(_ input: String, networkId: Int? = 1, target: String = "#chan") -> [CommandEffect] {
        guard case .command(let effects) = parse(input, networkId: networkId, target: target) else {
            XCTFail("expected a command from \(input)")
            return []
        }
        return effects
    }

    // MARK: - Plain text vs commands

    func testPlainTextIsAMessage() {
        XCTAssertEqual(parse("hello there"), .message("hello there"))
    }

    func testDoubleSlashEscapesToALiteralMessage() {
        // `//foo` sends the literal `/foo` — one slash stripped — so you can start a line with
        // a slash without invoking a command.
        XCTAssertEqual(parse("//slap me"), .message("/slap me"))
    }

    func testNonCommandInSystemBufferIsFlagged() {
        XCTAssertEqual(parse("hello", networkId: nil, target: ":system:"), .notCommand)
    }

    func testEscapedMessageInSystemBufferHasNowhereToGo() {
        // `//x` in the system buffer nudges rather than silently dropping (no network to send to).
        XCTAssertEqual(parse("//hello", networkId: nil, target: ":system:"), .notCommand)
        // But in a real buffer it's a literal message with the slash stripped.
        XCTAssertEqual(parse("//hello"), .message("/hello"))
    }

    // MARK: - Messaging

    func testMeIsAnAction() {
        XCTAssertEqual(effects("/me waves"), [.action(target: "#chan", text: "waves")])
    }

    func testMePreservesInteriorSpacing() {
        XCTAssertEqual(effects("/me waves   slowly"), [.action(target: "#chan", text: "waves   slowly")])
    }

    func testEmptyMeIsANoOp() {
        XCTAssertEqual(effects("/me"), [])
    }

    func testSlapFillsTheTroutLine() {
        XCTAssertEqual(effects("/slap bob"),
                       [.action(target: "#chan", text: "slaps bob around a bit with a large trout")])
    }

    func testMsgSendsThenActivates() {
        XCTAssertEqual(effects("/msg bob hey there"),
                       [.send(target: "bob", text: "hey there"), .activate(target: "bob")])
    }

    func testMsgWithNoBodyOnlyActivates() {
        XCTAssertEqual(effects("/msg bob"), [.activate(target: "bob")])
    }

    func testQueryIsAnAliasOfMsg() {
        XCTAssertEqual(effects("/query bob hi"),
                       [.send(target: "bob", text: "hi"), .activate(target: "bob")])
    }

    func testNoticeNeedsATargetAndBody() {
        XCTAssertEqual(effects("/notice bob heads up"), [.notice(target: "bob", text: "heads up")])
        guard case .info = effects("/notice bob").first else { return XCTFail("expected usage info") }
    }

    func testNoticePreservesInteriorSpacing() {
        // The body is sliced past the target, not re-joined from split tokens (mirrors /me).
        XCTAssertEqual(effects("/notice bob heads   up"), [.notice(target: "bob", text: "heads   up")])
    }

    // MARK: - Channels

    func testJoinPrefixesABareChannel() {
        XCTAssertEqual(effects("/join linux"), [.join(channel: "#linux", key: nil)])
    }

    func testJoinKeepsAnExistingPrefixAndTakesAKey() {
        XCTAssertEqual(effects("/join #secret hunter2"), [.join(channel: "#secret", key: "hunter2")])
    }

    func testBareJoinIsANoOp() {
        XCTAssertEqual(effects("/join"), [])
    }

    func testPartDefaultsToCurrentBufferAndRetargetsWithALeadingChannel() {
        XCTAssertEqual(effects("/part"), [.part(channel: "#chan", reason: nil)])
        XCTAssertEqual(effects("/part #other so long"), [.part(channel: "#other", reason: "so long")])
    }

    func testPartReasonOnlyLeavesTheCurrentChannel() {
        // A non-channel first word is a parting reason, not a channel named "heading".
        XCTAssertEqual(effects("/part heading out"), [.part(channel: "#chan", reason: "heading out")])
    }

    func testPartOutsideAChannelIsRefused() {
        guard case .info = effects("/part", target: "bob").first else {
            return XCTFail("expected a channel-context note when parting from a DM")
        }
    }

    func testLeaveIsAnAliasOfPart() {
        XCTAssertEqual(effects("/leave"), [.part(channel: "#chan", reason: nil)])
    }

    func testCycleIsPartThenJoinOfTheCurrentChannel() {
        XCTAssertEqual(effects("/cycle"),
                       [.part(channel: "#chan", reason: nil), .join(channel: "#chan", key: nil)])
    }

    func testCycleArgumentIsAReasonNotAChannel() {
        // Both legs stay on the current channel; the arg line is the part reason.
        XCTAssertEqual(effects("/cycle back soon"),
                       [.part(channel: "#chan", reason: "back soon"), .join(channel: "#chan", key: nil)])
    }

    func testCycleOutsideAChannelIsRefused() {
        guard case .info = effects("/cycle", target: "bob").first else {
            return XCTFail("expected a channel-context note")
        }
    }

    func testCloseTargetsTheCurrentBuffer() {
        XCTAssertEqual(effects("/close"), [.close(target: "#chan")])
    }

    func testTopicQueriesWhenEmptyAndSetsOtherwise() {
        XCTAssertEqual(effects("/topic"), [.raw(line: "TOPIC #chan")])
        XCTAssertEqual(effects("/topic hello world"), [.raw(line: "TOPIC #chan :hello world")])
    }

    func testTopicRetargetsWithALeadingChannel() {
        XCTAssertEqual(effects("/topic #other new topic"), [.raw(line: "TOPIC #other :new topic")])
    }

    func testModeShortcutRefusedInADm() {
        guard case .info = effects("/op alice", target: "bob").first else {
            return XCTFail("expected a channel-context note for a mode shortcut in a DM")
        }
    }

    func testModeShortcutUsageNamesTheActualCommand() {
        // The usage hint must say /deop, not a letter-derived "/deo".
        guard case .info(let text) = effects("/deop").first else { return XCTFail("expected usage") }
        XCTAssertTrue(text.contains("/deop"), "usage should name the command, got: \(text)")
    }

    func testNickIsARawLine() {
        XCTAssertEqual(effects("/nick newname"), [.raw(line: "NICK newname")])
    }

    func testWhoisRawsTheNick() {
        XCTAssertEqual(effects("/whois bob"), [.raw(line: "WHOIS bob")])
    }

    func testBareWhoisInADmTargetsThePeer() {
        XCTAssertEqual(effects("/whois", target: "bob"), [.raw(line: "WHOIS bob")])
    }

    func testInviteDefaultsChannelToCurrentBuffer() {
        XCTAssertEqual(effects("/invite bob"), [.raw(line: "INVITE bob #chan")])
        XCTAssertEqual(effects("/invite bob #other"), [.raw(line: "INVITE bob #other")])
    }

    // MARK: - Moderation

    func testKickBuildsARawLineWithReason() {
        XCTAssertEqual(effects("/kick bob be nice"), [.raw(line: "KICK #chan bob :be nice")])
        XCTAssertEqual(effects("/kick bob"), [.raw(line: "KICK #chan bob")])
    }

    func testKickTakesAnExplicitLeadingChannel() {
        XCTAssertEqual(effects("/kick #other bob spam"), [.raw(line: "KICK #other bob :spam")])
    }

    func testKickOutsideAChannelWithoutAChannelArgIsRefused() {
        guard case .info = effects("/kick bob", target: "alice").first else {
            return XCTFail("expected a channel-context note")
        }
    }

    func testOpRepeatsTheModeLetterPerNick() {
        XCTAssertEqual(effects("/op alice bob"), [.raw(line: "MODE #chan +oo alice bob")])
    }

    func testDeopIsTheMinusForm() {
        XCTAssertEqual(effects("/deop alice"), [.raw(line: "MODE #chan -o alice")])
    }

    func testBanTakesAnExplicitLeadingChannel() {
        XCTAssertEqual(effects("/ban #other *!*@spam.host"),
                       [.raw(line: "MODE #other +b *!*@spam.host")])
    }

    func testModeExplicitTargetPassesThrough() {
        XCTAssertEqual(effects("/mode #chan +m"), [.raw(line: "MODE #chan +m")])
    }

    func testModeFlagsOnlyPrependsTheCurrentChannel() {
        // `/mode +m` in a channel targets that channel, not a bogus target "+m".
        XCTAssertEqual(effects("/mode +m"), [.raw(line: "MODE #chan +m")])
        XCTAssertEqual(effects("/mode +b *!*@x"), [.raw(line: "MODE #chan +b *!*@x")])
    }

    // MARK: - Server / services

    func testRawAndQuoteSendTheLineVerbatim() {
        XCTAssertEqual(effects("/raw PING :x"), [.raw(line: "PING :x")])
        XCTAssertEqual(effects("/quote PING :x"), [.raw(line: "PING :x")])
    }

    func testNickServAndChanServ() {
        XCTAssertEqual(effects("/ns identify hunter2"), [.raw(line: "PRIVMSG NickServ :identify hunter2")])
        XCTAssertEqual(effects("/cs op #chan"), [.raw(line: "PRIVMSG ChanServ :op #chan")])
    }

    func testServerQueryVerbsGoRawUppercased() {
        XCTAssertEqual(effects("/motd"), [.raw(line: "MOTD")])
        XCTAssertEqual(effects("/who #chan"), [.raw(line: "WHO #chan")])
        XCTAssertEqual(effects("/names #chan"), [.raw(line: "NAMES #chan")])
    }

    func testUnknownCommandFallsThroughToRaw() {
        XCTAssertEqual(effects("/frobnicate a b"), [.raw(line: "frobnicate a b")])
    }

    // MARK: - Status (network-agnostic)

    func testAwayCarriesItsMessageAndRunsFromSystemBuffer() {
        XCTAssertEqual(
            effects("/away lunch", networkId: nil, target: ":system:"),
            [.away(message: "lunch")]
        )
    }

    func testBackRunsFromSystemBuffer() {
        XCTAssertEqual(effects("/back", networkId: nil, target: ":system:"), [.back])
    }

    func testCommandsPrintsLocalHelpFromSystemBuffer() {
        guard case .info(let text) = effects("/commands", networkId: nil, target: ":system:").first else {
            return XCTFail("expected help info")
        }
        XCTAssertTrue(text.contains("/join"), "the cheatsheet should list the vocabulary")
    }

    // MARK: - Network gate

    func testNetworkCommandInSystemBufferIsGated() {
        guard case .info(let text) = effects("/join #x", networkId: nil, target: ":system:").first else {
            return XCTFail("expected a gate message")
        }
        XCTAssertTrue(text.contains("needs an active network"))
    }

    func testQuitIsInterceptedRatherThanRawed() {
        // A bare /quit must NOT reach the raw fallback, where it would fire a real IRC QUIT.
        guard case .info = effects("/quit").first else {
            return XCTFail("expected /quit to be intercepted with a note")
        }
    }
}

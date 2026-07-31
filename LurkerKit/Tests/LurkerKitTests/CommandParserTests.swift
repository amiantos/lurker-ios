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

    func testBareSlashNudgesRatherThanEmittingAnEmptyRawLine() {
        // A lone `/` must not reach the raw fallback and put "" on the wire.
        guard case .info = effects("/").first else { return XCTFail("expected a nudge") }
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

    func testInviteOutsideAChannelIsRefused() {
        // A bare /invite from a DM would otherwise emit "INVITE bob <peer-nick>".
        guard case .info = effects("/invite bob", target: "alice").first else {
            return XCTFail("expected a channel-context note")
        }
    }

    func testCommandsRecognizeAmpersandChannels() {
        // `&` is a valid channel sigil (BufferKind.of), so it must be honored as an explicit
        // channel argument, not folded into a nick/reason/topic.
        XCTAssertEqual(effects("/kick &local bob"), [.raw(line: "KICK &local bob")])
        XCTAssertEqual(effects("/topic &local hi"), [.raw(line: "TOPIC &local :hi")])
        XCTAssertEqual(effects("/op &local alice"), [.raw(line: "MODE &local +o alice")])
        XCTAssertEqual(effects("/part &local bye"), [.part(channel: "&local", reason: "bye")])
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

    // MARK: - Ignore rules (#86)

    /// Two rules the tests can list: one global, one on network 1 — the two buckets, in the
    /// order `IgnoreSet.listing(for:)` hands them over.
    private var listedRules: [ScopedIgnoreRule] {
        [
            ScopedIgnoreRule(rule: IgnoreRule(id: 7, mask: "spammer"), scope: nil),
            ScopedIgnoreRule(rule: IgnoreRule(id: 9, mask: "bob", levels: ["JOINS"]), scope: 1),
        ]
    }

    private func effects(
        _ input: String,
        ignores: [ScopedIgnoreRule],
        networkId: Int? = 1,
        target: String = "#chan"
    ) -> [CommandEffect] {
        guard case .command(let effects) = CommandParser.parse(
            input, networkId: networkId, target: target, ignores: ignores
        ) else {
            XCTFail("expected a command from \(input)")
            return []
        }
        return effects
    }

    func testIgnoreNoLongerPutsARawIgnoreLineOnTheWire() {
        // The bug #86 exists to fix: the unknown-verb fallback sent a literal `IGNORE bob` to
        // a server that has no such command, so the user got a numeric back and no rule.
        for effect in effects("/ignore bob") + effects("/unignore bob", ignores: listedRules) {
            if case .raw = effect { XCTFail("an ignore verb must never reach the raw fallback") }
        }
    }

    func testIgnoreDefaultsToAGlobalRule() {
        // The default scope is global (#350) — nil, not the issuing network.
        XCTAssertEqual(
            effects("/ignore bob").first,
            .addIgnore(scope: nil, rule: IgnoreRule(mask: "bob", levels: ["ALL"]))
        )
    }

    func testIgnoreNetworkScopesToTheIssuingConnection() {
        XCTAssertEqual(
            effects("/ignore -network bob NOHIGHLIGHT").first,
            .addIgnore(scope: 1, rule: IgnoreRule(mask: "bob", levels: ["NOHIGHLIGHT"]))
        )
    }

    func testIgnoreConfirmsWhatItSent() {
        guard case .info(let text) = effects("/ignore bob").last else {
            return XCTFail("expected a confirmation")
        }
        XCTAssertTrue(text.contains("bob"), text)
        XCTAssertTrue(text.contains("[global]"), text)
    }

    func testIgnoreRunsFromTheSystemBufferBecauseRulesAreGlobal() {
        XCTAssertEqual(
            effects("/ignore bob", networkId: nil, target: ":system:").first,
            .addIgnore(scope: nil, rule: IgnoreRule(mask: "bob", levels: ["ALL"]))
        )
    }

    func testIgnoreNetworkInTheSystemBufferIsRefusedRatherThanMadeGlobal() {
        // Writing the global rule they didn't ask for would be a wider ignore than intended.
        let effects = effects("/ignore -network bob", networkId: nil, target: ":system:")
        guard case .info(let text) = effects.first, effects.count == 1 else {
            return XCTFail("expected a refusal and nothing else")
        }
        XCTAssertTrue(text.contains("needs an active network"), text)
    }

    func testIgnoreReportsAParseErrorRatherThanStoringSomethingElse() {
        let effects = effects("/ignore -bogus bob")
        guard case .info(let text) = effects.first, effects.count == 1 else {
            return XCTFail("expected an error and no rule")
        }
        XCTAssertTrue(text.contains("unknown flag"), text)
    }

    func testBareIgnoreListsTheRulesNumberedGlobalsFirst() {
        guard case .info(let text) = effects("/ignore", ignores: listedRules).first else {
            return XCTFail("expected a listing")
        }
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, text)
        XCTAssertTrue(lines[0].contains("(2)"), lines[0])
        XCTAssertTrue(lines[1].contains("1. spammer"), lines[1])
        XCTAssertTrue(lines[1].contains("[global]"), lines[1])
        XCTAssertTrue(lines[2].contains("2. bob"), lines[2])
        XCTAssertFalse(lines[2].contains("[global]"), lines[2])
    }

    func testBareIgnoreWithNoRulesSaysSoAndPointsAtTheVerb() {
        guard case .info(let text) = effects("/ignore").first else {
            return XCTFail("expected a listing")
        }
        XCTAssertTrue(text.contains("empty"), text)
    }

    func testUnignoreByIndexRemovesThatRuleByIdInItsOwnScope() {
        // #2 is the network-scoped rule: both the id and the scope come from the listing, which
        // is the whole reason `IgnoreRule.id` is carried.
        XCTAssertEqual(
            effects("/unignore 2", ignores: listedRules).first,
            .removeIgnore(scope: 1, id: 9, mask: nil)
        )
        XCTAssertEqual(
            effects("/unignore 1", ignores: listedRules).first,
            .removeIgnore(scope: nil, id: 7, mask: nil)
        )
    }

    func testUnignoreByIndexOutOfRangeRemovesNothing() {
        for input in ["/unignore 0", "/unignore 3", "/unignore 99999999999999999999"] {
            let effects = effects(input, ignores: listedRules)
            guard case .info(let text) = effects.first, effects.count == 1 else {
                return XCTFail("expected a complaint and no removal from \(input)")
            }
            XCTAssertTrue(text.contains("see /ignore"), text)
        }
    }

    func testUnignoreByMaskClearsEveryRuleCarryingIt() {
        // Scoped to the issuing network: the server's by-mask delete spans the globals plus
        // that one network, which is the set the count describes.
        XCTAssertEqual(
            effects("/unignore BOB", ignores: listedRules).first,
            .removeIgnore(scope: 1, id: nil, mask: "BOB")
        )
    }

    func testUnignoreByMaskWithNoMatchRemovesNothing() {
        let effects = effects("/unignore nobody", ignores: listedRules)
        guard case .info(let text) = effects.first, effects.count == 1 else {
            return XCTFail("expected a complaint and no removal")
        }
        XCTAssertTrue(text.contains("no ignore with mask"), text)
    }

    func testBareUnignoreExplainsItself() {
        guard case .info(let text) = effects("/unignore").first else {
            return XCTFail("expected usage")
        }
        XCTAssertTrue(text.contains("index|mask"), text)
    }
}

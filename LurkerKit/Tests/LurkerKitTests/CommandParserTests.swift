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

    /// `/whois` opens the profile rather than sending the line itself (#12).
    ///
    /// ⚠ No `.raw` beside it, deliberately. The profile asks on open through `requestWhois`,
    /// which owns the in-flight bookkeeping; a second WHOIS here would be dropped by that very
    /// bookkeeping, and the server buffer gets the raw numerics either way.
    func testWhoisOpensTheProfile() {
        XCTAssertEqual(effects("/whois bob"), [.showProfile(nick: "bob")])
    }

    func testBareWhoisInADmTargetsThePeer() {
        XCTAssertEqual(effects("/whois", target: "bob"), [.showProfile(nick: "bob")])
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

    /// Three rules across both buckets: one global and two on network 1, the second pair
    /// sharing a mask so a by-mask removal has something to count. Listed order is globals
    /// first, so the indices are 1: spammer, 2: bob, 3: BOB.
    private var listedRules: IgnoreSet {
        IgnoreSet(
            global: [IgnoreRule(id: 7, mask: "spammer")],
            byNetwork: [1: [
                IgnoreRule(id: 9, mask: "bob", levels: ["JOINS"]),
                IgnoreRule(id: 11, mask: "BOB", levels: ["PARTS"]),
            ]]
        )
    }

    private func effects(
        _ input: String,
        ignores: IgnoreSet,
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
            .addIgnore(
                scope: nil,
                rule: IgnoreRule(mask: "bob", levels: ["ALL"]),
                receipt: "ignore added: bob  [global]  ALL"
            )
        )
    }

    func testIgnoreNetworkScopesToTheIssuingConnection() {
        XCTAssertEqual(
            effects("/ignore -network bob NOHIGHLIGHT").first,
            .addIgnore(
                scope: 1,
                rule: IgnoreRule(mask: "bob", levels: ["NOHIGHLIGHT"]),
                receipt: "ignore added: bob  NOHIGHLIGHT"
            )
        )
    }

    func testTheReceiptRidesOnTheEffectSoAFailedSendCanWithholdIt() {
        // Not a separate `.info`: whether the line may be printed isn't known until the verb
        // has been handed to a socket, and nothing queues these. See `ChatViewModel.report`.
        let effects = effects("/ignore bob")
        XCTAssertEqual(effects.count, 1, "the confirmation must not be a second, unconditional effect")
        for effect in effects {
            if case .info = effect { XCTFail("an ignore add must not print unconditionally") }
        }
    }

    func testIgnoreRunsFromTheSystemBufferBecauseRulesAreGlobal() {
        XCTAssertEqual(
            effects("/ignore bob", networkId: nil, target: ":system:").first,
            .addIgnore(
                scope: nil,
                rule: IgnoreRule(mask: "bob", levels: ["ALL"]),
                receipt: "ignore added: bob  [global]  ALL"
            )
        )
    }

    func testEveryNetworkAgnosticSpecIsActuallyReachableFromTheSystemBuffer() {
        // `networkAgnostic` is documentation — the real gate is where the verb's case sits in
        // `resolve`. This is what keeps the two from drifting apart.
        for spec in CommandRegistry.all where spec.networkAgnostic {
            let effects = effects("/\(spec.name)", networkId: nil, target: ":system:")
            if case .info(let text) = effects.first {
                XCTAssertFalse(
                    text.contains("needs an active network"),
                    "/\(spec.name) claims to be network-agnostic but is gated"
                )
            }
        }
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
        XCTAssertTrue(lines[0].contains("(3)"), lines[0])
        XCTAssertTrue(lines[1].contains("1. spammer"), lines[1])
        XCTAssertTrue(lines[1].contains("[global]"), lines[1])
        XCTAssertTrue(lines[2].contains("2. bob"), lines[2])
        XCTAssertFalse(lines[2].contains("[global]"), lines[2])
    }

    func testTheListingCarriesTheGrammarBecauseNothingElseDoes() {
        // `/commands` can only print the positional form, so the flags are unreachable without
        // this — including `-network`, the only way to scope a rule to one connection.
        guard case .info(let text) = effects("/ignore").first else {
            return XCTFail("expected a listing")
        }
        XCTAssertTrue(text.contains("empty"), text)
        XCTAssertTrue(text.contains("-network"), text)
        XCTAssertTrue(text.contains("-pattern"), text)
        XCTAssertTrue(text.contains("NOHIGHLIGHT"), text)
    }

    func testALapsedRuleKeepsItsPlaceInTheListingAndIsMarkedExpired() {
        // Filtering it out would renumber everything below it the moment it lapsed — so an
        // index read off one `/ignore` and spent on the next `/unignore` would delete a
        // different, still-live rule. Its row is also still on the server until the sweeper
        // gets to it, and a by-mask DELETE takes it with the rest.
        let now = Date()
        let set = IgnoreSet(global: [
            IgnoreRule(id: 1, mask: "gone", expiresAt: now.addingTimeInterval(-60)),
            IgnoreRule(id: 2, mask: "live", expiresAt: now.addingTimeInterval(60)),
        ])
        guard case .command(let effects) = CommandParser.parse(
            "/ignore", networkId: 1, target: "#chan", ignores: set, now: now
        ), case .info(let text) = effects.first else {
            return XCTFail("expected a listing")
        }
        XCTAssertTrue(text.contains("(2)"), text)
        XCTAssertTrue(text.contains("1. gone"), text)
        XCTAssertTrue(text.contains("(expired "), text)
        XCTAssertTrue(text.contains("2. live"), text)
        // And the index still means what it said.
        guard case .command(let removal) = CommandParser.parse(
            "/unignore 2", networkId: 1, target: "#chan", ignores: set, now: now
        ) else { return XCTFail("expected a removal") }
        XCTAssertEqual(removal.first.map { effect -> Int? in
            if case .removeIgnore(_, let id, _, _) = effect { return id }
            return nil
        } ?? nil, 2)
    }

    func testBothVerbsRefuseToAnswerBeforeTheRulesHaveArrived() {
        // `nil` is "not synced yet", which an empty set cannot express — and both verbs would
        // otherwise deny out loud that rules the account really has exist.
        for input in ["/ignore", "/unignore bob", "/unignore 1"] {
            guard case .command(let effects) = CommandParser.parse(
                input, networkId: 1, target: "#chan", ignores: nil
            ), case .info(let text) = effects.first, effects.count == 1 else {
                return XCTFail("expected one explanation from \(input)")
            }
            XCTAssertTrue(text.contains("haven't arrived yet"), text)
        }
        // Authoring doesn't need the listing, so it isn't gated — the send path reports
        // whether it landed. But the receipt can't say whether the server will add or upsert
        // without the rules, so it claims neither.
        guard case .command(let effects) = CommandParser.parse(
            "/ignore bob", networkId: 1, target: "#chan", ignores: nil
        ), case .addIgnore(_, _, let receipt) = effects.first else {
            return XCTFail("expected /ignore <nick> to still author a rule")
        }
        XCTAssertTrue(receipt.hasPrefix("ignore sent:"), receipt)
    }

    func testUnignoreByIndexRemovesThatRuleByIdInItsOwnScope() {
        // #2 is the network-scoped rule: both the id and the scope come from the listing, which
        // is the whole reason `IgnoreRule.id` is carried.
        XCTAssertEqual(
            effects("/unignore 2", ignores: listedRules).first,
            .removeIgnore(scope: 1, id: 9, mask: nil, receipt: "removed ignore #2: bob  JOINS")
        )
        XCTAssertEqual(
            effects("/unignore 1", ignores: listedRules).first,
            .removeIgnore(
                scope: nil, id: 7, mask: nil,
                receipt: "removed ignore #1: spammer  [global]  ALL"
            )
        )
    }

    func testUnignoreByIndexOutOfRangeRemovesNothing() {
        for input in ["/unignore 0", "/unignore 4", "/unignore 99999999999999999999"] {
            let effects = effects(input, ignores: listedRules)
            guard case .info(let text) = effects.first, effects.count == 1 else {
                return XCTFail("expected a complaint and no removal from \(input)")
            }
            XCTAssertTrue(text.contains("see /ignore"), text)
        }
    }

    func testAnAllDigitMaskIsStillRemovableByMask() {
        // The index branch wins when the number names a rule that exists; otherwise the digits
        // are tried as a mask, so a numeric nick (bots, `*!*@1234`) isn't create-only.
        let set = IgnoreSet(byNetwork: [1: [IgnoreRule(id: 3, mask: "12345")]])
        XCTAssertEqual(
            effects("/unignore 12345", ignores: set).first,
            .removeIgnore(
                scope: 1, id: nil, mask: "12345",
                receipt: "removed 1 ignore matching \"12345\"."
            )
        )
        // An in-range index still means the index.
        XCTAssertEqual(
            effects("/unignore 1", ignores: set).first,
            .removeIgnore(scope: 1, id: 3, mask: nil, receipt: "removed ignore #1: 12345  ALL")
        )
    }

    func testUnignoreByMaskClearsEveryRuleCarryingIt() {
        // Scoped to the issuing network: the server's by-mask delete spans the globals plus
        // that one network, which is the set the count describes. Two rules share this mask up
        // to case, and SQLite's NOCASE folds them the same way.
        XCTAssertEqual(
            effects("/unignore BOB", ignores: listedRules).first,
            .removeIgnore(
                scope: 1, id: nil, mask: "BOB",
                receipt: "removed 2 ignores matching \"BOB\"."
            )
        )
    }

    func testTheByMaskCountFoldsCaseTheWayTheServersDeleteDoes() {
        // `caseInsensitiveCompare` would count these as matches; SQLite's `COLLATE NOCASE`
        // (ASCII-only, byte-exact otherwise) does not — so counting them would report a
        // removal the DELETE never makes.
        let set = IgnoreSet(byNetwork: [1: [
            IgnoreRule(id: 1, mask: "caf\u{00E9}"),   // composed
            IgnoreRule(id: 2, mask: "stra\u{00DF}e"),
        ]])
        for input in ["/unignore cafe\u{0301}", "/unignore STRASSE"] {
            let effects = effects(input, ignores: set)
            guard case .info(let text) = effects.first, effects.count == 1 else {
                return XCTFail("expected no removal from \(input)")
            }
            XCTAssertTrue(text.contains("no ignore with mask"), text)
        }
        // ASCII case still folds, because NOCASE folds it — and it has to fold per BYTE, not
        // per grapheme: `A` + combining acute is one non-ASCII `Character` whose `A` byte
        // SQLite still lowers. Folding by character left it alone and reported no match for a
        // rule the DELETE would have removed.
        let ascii = IgnoreSet(byNetwork: [1: [
            IgnoreRule(id: 3, mask: "Bob"),
            IgnoreRule(id: 4, mask: "A\u{0301}bc"),
        ]])
        XCTAssertEqual(
            effects("/unignore BOB", ignores: ascii).first,
            .removeIgnore(scope: 1, id: nil, mask: "BOB", receipt: "removed 1 ignore matching \"BOB\".")
        )
        XCTAssertEqual(
            effects("/unignore a\u{0301}BC", ignores: ascii).first,
            .removeIgnore(
                scope: 1, id: nil, mask: "a\u{0301}BC",
                receipt: "removed 1 ignore matching \"a\u{0301}BC\"."
            )
        )
    }

    func testAQuotedMaskIsRemovableInTheSpellingThatCreatedIt() {
        // `/ignore "bob smith"` stores `bob smith`; comparing the raw arg would have matched
        // only the unquoted spelling, which isn't the one that made the rule.
        let set = IgnoreSet(byNetwork: [1: [IgnoreRule(id: 5, mask: "bob smith")]])
        XCTAssertEqual(
            effects("/unignore \"bob smith\"", ignores: set).first,
            .removeIgnore(
                scope: 1, id: nil, mask: "bob smith",
                receipt: "removed 1 ignore matching \"bob smith\"."
            )
        )
    }

    func testReIssuingAnIdenticalRuleReportsAnUpdateBecauseTheServerUpserts() {
        // `add-ignore` matches on every dimension but expiry and rewrites that row's
        // `expires_at` in place — so `/ignore -time 1h bob` then `/ignore bob` doesn't add a
        // second rule, it makes the hour-long mute permanent. "added" would hide that.
        let set = IgnoreSet(global: [
            IgnoreRule(id: 1, mask: "bob", levels: ["ALL"], expiresAt: Date().addingTimeInterval(3600)),
        ])
        guard case .addIgnore(_, _, let receipt) = effects("/ignore bob", ignores: set).first else {
            return XCTFail("expected an add")
        }
        XCTAssertTrue(receipt.hasPrefix("ignore updated:"), receipt)
        // A rule that differs in any compared dimension is genuinely new.
        guard case .addIgnore(_, _, let fresh) = effects("/ignore bob JOINS", ignores: set).first else {
            return XCTFail("expected an add")
        }
        XCTAssertTrue(fresh.hasPrefix("ignore added:"), fresh)
    }

    func testAnInteriorNewlineDoesNotBecomePartOfTheMask() {
        // The composer is multi-line and Return inserts a newline, so `/unignore \nbob` is
        // reachable; `.whitespaces` (which excludes newlines) left it glued to the mask.
        let set = IgnoreSet(byNetwork: [1: [IgnoreRule(id: 6, mask: "bob")]])
        XCTAssertEqual(
            effects("/unignore \nbob", ignores: set).first,
            .removeIgnore(scope: 1, id: nil, mask: "bob", receipt: "removed 1 ignore matching \"bob\".")
        )
        // And a newline-only argument lists rather than authoring a rule that names nobody.
        guard case .info(let text) = effects("/ignore \n", ignores: set).first else {
            return XCTFail("expected a listing")
        }
        XCTAssertTrue(text.contains("ignore list"), text)
    }

    func testUnignoreStarSaysWhyItCannotMatch() {
        // The listing prints a maskless rule as `*`, so typing it back is the obvious move —
        // but `*` normalizes to no mask at all, and the server's delete matches on a string.
        let set = IgnoreSet(global: [IgnoreRule(id: 1, mask: nil, levels: ["JOINS"])])
        let effects = effects("/unignore *", ignores: set)
        guard case .info(let text) = effects.first, effects.count == 1 else {
            return XCTFail("expected an explanation and no removal")
        }
        XCTAssertTrue(text.contains("by number"), text)
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

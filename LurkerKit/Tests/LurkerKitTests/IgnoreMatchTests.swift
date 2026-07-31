// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The matcher's behavior, derived from the lurker repo's `server/services/ignoreMatch.test.ts`
/// so the two implementations are held to the same cases.
///
/// Divergences from that suite are deliberate and marked where they occur; everything else is
/// the same rule with the same expected answer. The point isn't coverage for its own sake —
/// it's that the server stamps `from_ignored` from its copy of this logic while the client
/// filters from this one, so any disagreement between them shows up as a line that's hidden in
/// one place and counted in another.
final class IgnoreMatchTests: XCTestCase {

    // MARK: - Fixtures

    private func rule(
        id: Int = 1,
        mask: String? = nil,
        channels: [String]? = nil,
        pattern: String? = nil,
        patternKind: IgnorePatternKind = .substr,
        levels: [String] = ["ALL"],
        isExcept: Bool = false,
        expiresAt: Date? = nil
    ) -> IgnoreRule {
        IgnoreRule(
            id: id, mask: mask, channels: channels, pattern: pattern, patternKind: patternKind,
            levels: levels, isExcept: isExcept, expiresAt: expiresAt
        )
    }

    private func input(
        nick: String? = "bob",
        userhost: String? = "bob!u@h",
        target: String = "#chan",
        text: String = "hello",
        type: EventType = .message,
        isDm: Bool = false
    ) -> IgnoreInput {
        IgnoreInput(
            nick: nick, userhost: userhost, target: target, text: text, type: type, isDm: isDm
        )
    }

    private func evaluate(_ rules: [IgnoreRule], _ input: IgnoreInput) -> IgnoreVerdict {
        IgnoreMatch.evaluate(IgnoreMatch.compile(rules), input)
    }

    // MARK: - NOHIGHLIGHT

    func testNohighlightKeepsTheMessageVisibleButSuppressesTheHighlight() {
        let rules = [rule(mask: "bob", levels: ["NOHIGHLIGHT"])]
        XCTAssertEqual(
            evaluate(rules, input(nick: "bob")),
            IgnoreVerdict(hide: false, nohilight: true, nonotify: false)
        )
    }

    func testNohighlightDoesNotAffectADifferentSender() {
        let rules = [rule(mask: "bob", levels: ["NOHIGHLIGHT"])]
        XCTAssertEqual(evaluate(rules, input(nick: "alice")), .visible)
    }

    func testNohighlightOnlyAppliesToHighlightableTypes() {
        let rules = [rule(mask: "bob", levels: ["NOHIGHLIGHT"])]
        XCTAssertTrue(evaluate(rules, input(text: "waves", type: .action)).nohilight)
        XCTAssertFalse(evaluate(rules, input(text: "", type: .join)).nohilight)
    }

    // MARK: - Content patterns

    func testAContentRegexScopedToAChannel() {
        let rules = [
            rule(channels: ["#chan"], pattern: "(word1|word2)", patternKind: .regex, levels: ["PUBLIC"]),
        ]
        XCTAssertTrue(
            evaluate(rules, input(nick: "anyone", target: "#chan", text: "has word2 in it")).hide,
            "a channel-scoped content rule hides a matching line from anyone"
        )
        XCTAssertFalse(evaluate(rules, input(target: "#other", text: "has word1 in it")).hide)
        XCTAssertFalse(evaluate(rules, input(target: "#chan", text: "nothing here")).hide)
    }

    /// Not in the server suite: `full` is the third stored `patternKind`, and its whole-word
    /// anchoring is the one that can silently misfire — a substring match would hide both of
    /// these lines rather than one.
    func testAFullPatternMatchesWholeWordsOnly() {
        let rules = [rule(pattern: "spam", patternKind: .full, levels: ["PUBLIC"])]
        XCTAssertTrue(evaluate(rules, input(text: "this is Spam!")).hide)
        XCTAssertFalse(evaluate(rules, input(text: "spamalot is fine")).hide)
    }

    /// Also not in the server suite, and the reason the word class is spelled out rather than
    /// left to `\w`: an accented letter is a word character, so a keyword must not match
    /// inside a longer non-ASCII word.
    func testWholeWordMatchingTreatsNonAsciiLettersAsWordCharacters() {
        let rules = [rule(pattern: "em", patternKind: .full, levels: ["PUBLIC"])]
        XCTAssertFalse(evaluate(rules, input(text: "zrozumiałem")).hide)
        XCTAssertTrue(evaluate(rules, input(text: "ale em jest")).hide)
    }

    /// A rule whose regex doesn't compile goes inert instead of taking the rest of the set
    /// down with it — the whole reason `TextMatcher` has a `never` case.
    func testAnUncompilableRegexDisablesOnlyItsOwnRule() {
        let rules = [
            rule(id: 1, pattern: "([unclosed", patternKind: .regex, levels: ["PUBLIC"]),
            rule(id: 2, mask: "bob", levels: ["ALL"]),
        ]
        XCTAssertTrue(evaluate(rules, input(nick: "bob")).hide, "the second rule still applies")
        XCTAssertFalse(evaluate([rules[0]], input(nick: "bob")).hide)
    }

    // MARK: - Masks

    func testAnUnmaskedJoinsRuleHidesJoinsFromAnyoneButNotMessages() {
        let rules = [rule(levels: ["JOINS"])]
        XCTAssertTrue(evaluate(rules, input(text: "", type: .join)).hide)
        XCTAssertFalse(evaluate(rules, input()).hide)
    }

    func testAGlobMaskMatchesInsideTheNick() {
        let rules = [rule(mask: "*zzz*", levels: ["NICKS"])]
        XCTAssertTrue(evaluate(rules, input(nick: "fooZZZbar", text: "", type: .nick)).hide)
        XCTAssertFalse(evaluate(rules, input(nick: "foo", text: "", type: .nick)).hide)
    }

    func testABareNickMaskIsAnchoredAndCaseInsensitive() {
        let rules = [rule(mask: "bozo", levels: ["ALL"])]
        XCTAssertTrue(evaluate(rules, input(nick: "Bozo")).hide)
        XCTAssertFalse(evaluate(rules, input(nick: "bozoXYZ")).hide, "anchored, not a substring")
    }

    /// A hostmask rule needs a hostmask to judge. The server doesn't stamp one on every event
    /// (synthesized lines carry none), and a rule that constrains the host must not fire on a
    /// sender whose host is simply unknown — while one that constrains only the nick still can.
    func testAHostmaskRuleNeedsAHostmaskButANickOnlyOneDoesNot() {
        XCTAssertFalse(
            evaluate([rule(mask: "*!*@spam", levels: ["ALL"])], input(userhost: nil)).hide
        )
        XCTAssertTrue(
            evaluate([rule(mask: "bob!*@*", levels: ["ALL"])], input(userhost: nil)).hide
        )
    }

    /// The user and host halves are case-SENSITIVE while the nick half isn't — the split the
    /// shared matcher makes, and easy to get wrong in a port by folding all three.
    func testTheNickHalfFoldsCaseAndTheHostHalfDoesNot() {
        let rules = [rule(mask: "Bob!*@Host", levels: ["ALL"])]
        XCTAssertTrue(evaluate(rules, input(nick: "bob", userhost: "bob!u@Host")).hide)
        XCTAssertFalse(evaluate(rules, input(nick: "bob", userhost: "bob!u@host")).hide)
    }

    /// A mask with no `!` but an `@` names the *user*, not the nick — the third shape
    /// `splitMask` has to get right.
    func testAUserAtHostMaskConstrainsTheUserHalf() {
        let rules = [rule(mask: "spammer@evil.example", levels: ["ALL"])]
        XCTAssertTrue(evaluate(rules, input(userhost: "anynick!spammer@evil.example")).hide)
        XCTAssertFalse(evaluate(rules, input(userhost: "anynick!other@evil.example")).hide)
    }

    /// A channel scope with a wildcard takes the regex path while a plain name takes the
    /// literal one, and the two have to agree — the literal case exists purely to keep ICU off
    /// the render path, so it must not also change what matches.
    func testAChannelScopeMatchesLiterallyAndByGlobAlike() {
        let literal = [rule(channels: ["#chan"], levels: ["PUBLIC"])]
        XCTAssertTrue(evaluate(literal, input(target: "#chan")).hide)
        XCTAssertTrue(evaluate(literal, input(target: "#CHAN")).hide, "targets fold case")
        XCTAssertFalse(evaluate(literal, input(target: "#chan2")).hide, "anchored, not a prefix")

        let glob = [rule(channels: ["#chan*"], levels: ["PUBLIC"])]
        XCTAssertTrue(evaluate(glob, input(target: "#chan")).hide)
        XCTAssertTrue(evaluate(glob, input(target: "#chan2")).hide)
        XCTAssertFalse(evaluate(glob, input(target: "#other")).hide)
    }

    /// A literal mask that happens to contain regex metacharacters must stay a literal —
    /// `[` and `.` are legal in some networks' nicks, and the fast path must not treat them
    /// as syntax where the regex path escapes them.
    func testAMaskWithRegexMetacharactersIsMatchedLiterally() {
        let rules = [rule(mask: "a.b[c]", levels: ["ALL"])]
        XCTAssertTrue(evaluate(rules, input(nick: "a.b[c]")).hide)
        XCTAssertFalse(evaluate(rules, input(nick: "axbc")).hide)
    }

    // MARK: - Levels

    func testPublicMatchesChannelMessagesOnlyAndMsgsDmsOnly() {
        let publicRule = [rule(mask: "bob", levels: ["PUBLIC"])]
        XCTAssertTrue(evaluate(publicRule, input(isDm: false)).hide)
        XCTAssertFalse(evaluate(publicRule, input(target: "bob", isDm: true)).hide)

        let msgsRule = [rule(mask: "bob", levels: ["MSGS"])]
        XCTAssertTrue(evaluate(msgsRule, input(target: "bob", isDm: true)).hide)
        XCTAssertFalse(evaluate(msgsRule, input(isDm: false)).hide)
    }

    func testAllHidesEveryIgnorableTypeAndNoOthers() {
        let rules = [rule(mask: "bob", levels: ["ALL"])]
        let ignorable: [EventType] = [
            .message, .action, .notice, .join, .part, .quit, .nick, .kick, .mode, .topic, .chghost,
        ]
        for type in ignorable {
            XCTAssertTrue(evaluate(rules, input(text: "x", type: type)).hide, "\(type) should hide")
        }
        // System and self-scoped rows have no sender to ignore. `.other` stands in for the
        // unmodeled state events (usermode, names, lag) this client folds together.
        for type in [EventType.motd, .error, .system, .other] {
            XCTAssertFalse(evaluate(rules, input(type: type)).hide, "\(type) must stay visible")
        }
    }

    /// A chghost rides the QUITS level rather than having one of its own (lurker #591).
    func testQuitsAlsoCoversChghost() {
        let rules = [rule(mask: "bob", levels: ["QUITS"])]
        XCTAssertTrue(evaluate(rules, input(text: "", type: .quit)).hide)
        XCTAssertTrue(evaluate(rules, input(text: "", type: .chghost)).hide)
        XCTAssertFalse(evaluate(rules, input(text: "", type: .part)).hide)
    }

    /// A level token this client doesn't know is dropped rather than matching everything —
    /// the compile-time equivalent of the server's `if (!def) continue`.
    func testAnUnknownLevelTokenHidesNothing() {
        XCTAssertFalse(evaluate([rule(mask: "bob", levels: ["INVENTED"])], input()).hide)
    }

    // MARK: - Except

    func testTheLongerExceptMaskWins() {
        let rules = [
            rule(id: 1, mask: "*!*@spam", levels: ["ALL"]),
            rule(id: 2, mask: "bob!*@spam", levels: ["ALL"], isExcept: true),
        ]
        XCTAssertFalse(evaluate(rules, input(nick: "bob", userhost: "bob!u@spam")).hide)
        XCTAssertTrue(
            evaluate(rules, input(nick: "eve", userhost: "eve!u@spam")).hide,
            "others on the host are still hidden"
        )
    }

    // MARK: - Expiry

    func testALapsedRuleNeverMatchesAndAFutureOneStillDoes() {
        let past = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01
        let future = Date(timeIntervalSince1970: 32_503_680_000) // 2999-01-01
        XCTAssertFalse(evaluate([rule(mask: "bob", expiresAt: past)], input()).hide)
        XCTAssertTrue(evaluate([rule(mask: "bob", expiresAt: future)], input()).hide)
    }

    // MARK: - Text normalization

    func testAPatternDoesNotMatchAWordThatAppearsOnlyInsideAURL() {
        let rules = [rule(pattern: "spam", levels: ["PUBLIC"])]
        XCTAssertFalse(evaluate(rules, input(text: "see https://spam.example here")).hide)
        XCTAssertTrue(evaluate(rules, input(text: "this is spam")).hide)
    }

    /// mIRC color codes have to come off before matching, or the digits fuse to the front of
    /// the word and a whole-word rule misses the line it was written for.
    func testFormattingCodesAreStrippedBeforeMatching() {
        let rules = [rule(pattern: "QUACK", patternKind: .full, levels: ["PUBLIC"])]
        XCTAssertTrue(evaluate(rules, input(text: "\u{03}04QUACK\u{03}")).hide)
    }

    // MARK: - Member visibility

    func testOnlyAWholeIdentityAllRuleHidesAMember() {
        func hidden(_ rules: [IgnoreRule], channel: String = "#chan") -> Bool {
            IgnoreMatch.isMemberHidden(
                IgnoreMatch.compile(rules), nick: "bob", userhost: "bob!u@h", channel: channel
            )
        }
        XCTAssertTrue(hidden([rule(mask: "bob", levels: ["ALL"])]))
        XCTAssertTrue(hidden([rule(mask: "bob", channels: ["#chan"], levels: ["ALL"])]))
        XCTAssertFalse(
            hidden([rule(mask: "bob", channels: ["#other"], levels: ["ALL"])]),
            "a rule scoped to another channel doesn't reach this nicklist"
        )
        XCTAssertFalse(
            hidden([rule(mask: "bob", levels: ["PUBLIC"])]),
            "a level-scoped rule leaves them listed — they're still in the room"
        )
        XCTAssertFalse(hidden([rule(mask: "bob", levels: ["NOHIGHLIGHT"])]))
        XCTAssertFalse(
            hidden([rule(mask: "bob", pattern: "x", levels: ["ALL"])]),
            "a content rule can't be judged without a message"
        )
        XCTAssertFalse(hidden([rule(mask: "bob", levels: ["ALL"], isExcept: true)]))
    }

    // MARK: - Mute modifiers (#359)

    func testANonotifyRuleMutesNotificationsButKeepsTheMessageVisible() {
        let verdict = evaluate(
            [rule(channels: ["#chan"], levels: ["NOUNREAD", "NONOTIFY"])], input(target: "#chan")
        )
        XCTAssertEqual(verdict, IgnoreVerdict(hide: false, nohilight: false, nonotify: true))
    }

    func testNounreadAloneProducesNoPerMessageVerdict() {
        // Its only effect is the whole-buffer badge downgrade, tested below.
        XCTAssertEqual(
            evaluate([rule(channels: ["#chan"], levels: ["NOUNREAD"])], input(target: "#chan")),
            .visible
        )
    }

    func testNonotifyVetoesNonHighlightableTypesToo() {
        let rules = [rule(channels: ["#chan"], levels: ["NONOTIFY"])]
        XCTAssertTrue(evaluate(rules, input(target: "#chan", type: .notice)).nonotify)
        XCTAssertTrue(evaluate(rules, input(target: "#chan", text: "", type: .join)).nonotify)
        XCTAssertTrue(evaluate(rules, input(target: "#chan", text: "waves", type: .action)).nonotify)
        XCTAssertFalse(evaluate(rules, input(target: "#other")).nonotify, "channel scope holds")
    }

    func testAScopeMuteVetoesANicklessEventButASenderMuteDoesNot() {
        XCTAssertTrue(
            evaluate(
                [rule(channels: ["#chan"], levels: ["NONOTIFY"])],
                input(nick: nil, userhost: nil, target: "#chan", type: .notice)
            ).nonotify
        )
        XCTAssertFalse(
            evaluate([rule(mask: "bob", levels: ["NONOTIFY"])], input(nick: nil, userhost: nil))
                .nonotify
        )
    }

    func testNonotifyHonorsExcept() {
        let rules = [
            rule(id: 1, channels: ["#chan"], levels: ["NONOTIFY"]),
            rule(id: 2, mask: "boss", channels: ["#chan"], levels: ["NONOTIFY"], isExcept: true),
        ]
        XCTAssertTrue(evaluate(rules, input(nick: "rando", target: "#chan")).nonotify)
        XCTAssertFalse(evaluate(rules, input(nick: "boss", target: "#chan")).nonotify)
    }

    // MARK: - channelMutesUnread (#359)

    func testChannelMutesUnread() {
        func mutes(_ rules: [IgnoreRule], _ channel: String) -> Bool {
            IgnoreMatch.channelMutesUnread(IgnoreMatch.compile(rules), channel: channel)
        }
        XCTAssertTrue(mutes([rule(channels: ["#chan"], levels: ["NOUNREAD"])], "#chan"))
        XCTAssertFalse(mutes([rule(channels: ["#chan"], levels: ["NOUNREAD"])], "#other"))

        // A network-wide rule (no channel scope) covers every buffer under it, DMs included.
        let networkWide = [rule(levels: ["NOUNREAD"])]
        XCTAssertTrue(mutes(networkWide, "#anything"))
        XCTAssertTrue(mutes(networkWide, "somenick"))

        XCTAssertFalse(
            mutes([rule(mask: "bob", channels: ["#chan"], levels: ["NOUNREAD"])], "#chan"),
            "a per-sender mute can't speak for the whole buffer's badge"
        )
        XCTAssertFalse(mutes([rule(channels: ["#chan"], levels: ["NONOTIFY"])], "#chan"))
        XCTAssertFalse(
            mutes([rule(channels: ["#chan"], levels: ["NOUNREAD"], isExcept: true)], "#chan")
        )
    }
}

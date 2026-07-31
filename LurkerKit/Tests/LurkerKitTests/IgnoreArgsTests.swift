// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Derived from the reference suite for the same grammar (`server/services/parseIgnore.test.ts`),
/// case for case, because the two parsers write rows into the same table: a level spelled
/// `nohilight` here and dropped there would store a rule that means something different
/// depending on which client typed it.
///
/// Two deliberate divergences from the reference file:
///  - `durationToExpiry` isn't ported. It exists on the web for the ignore settings pane's
///    duration field; this client has no such pane (#86 is slash commands only), and the
///    duration grammar it shares with `-time` is covered through `-time` below.
///  - The reference compares `expiresAt` as an ISO string; here it's a `Date`, parsed at the
///    wire boundary. The instants asserted are the same ones.
final class IgnoreArgsTests: XCTestCase {

    private let now = ISOTime.parse("2026-06-18T00:00:00.000Z")!

    /// The rule a command line names, or nil (failing the test) if it named none.
    private func parse(_ line: String, file: StaticString = #filePath, line lineNumber: UInt = #line) -> IgnoreArgs.Parsed? {
        switch IgnoreArgs.parse(line, now: now) {
        case .success(let parsed):
            return parsed
        case .failure(let failure):
            XCTFail("expected a rule from \(line), got: \(failure.message)", file: file, line: lineNumber)
            return nil
        }
    }

    /// The reason a command line named no rule, or nil (failing the test) if it named one.
    private func error(_ line: String, file: StaticString = #filePath, line lineNumber: UInt = #line) -> String? {
        switch IgnoreArgs.parse(line, now: now) {
        case .success:
            XCTFail("expected \(line) to fail", file: file, line: lineNumber)
            return nil
        case .failure(let failure):
            return failure.message
        }
    }

    // MARK: - Masks & levels

    func testBareNickDefaultsToAll() {
        let rule = parse("bob")?.rule
        XCTAssertEqual(rule?.mask, "bob")
        XCTAssertEqual(rule?.levels, ["ALL"])
        XCTAssertNil(rule?.channels)
        XCTAssertNil(rule?.pattern)
    }

    func testNohighlightAcceptsLurkerAndIrssiSpellings() {
        XCTAssertEqual(parse("bob NOHIGHLIGHT")?.rule.levels, ["NOHIGHLIGHT"])
        XCTAssertEqual(parse("bob NOHIGHLIGHTS")?.rule.levels, ["NOHIGHLIGHT"])
        XCTAssertEqual(parse("bob NOHILIGHT")?.rule.levels, ["NOHIGHLIGHT"])
    }

    func testStarMaskNormalizesToAnyone() {
        let parsed = parse("* JOINS")
        XCTAssertNil(parsed?.rule.mask)
        XCTAssertEqual(parsed?.rule.levels, ["JOINS"])
    }

    func testKeepsAGlobMaskVerbatim() {
        let parsed = parse("*zzz* NICKS")
        XCTAssertEqual(parsed?.rule.mask, "*zzz*")
        XCTAssertEqual(parsed?.rule.levels, ["NICKS"])
    }

    func testAcceptsSingularAndPluralLevelAliases() {
        XCTAssertEqual(parse("bob publics")?.rule.levels, ["PUBLIC"])
        XCTAssertEqual(parse("bob join part")?.rule.levels, ["JOINS", "PARTS"])
    }

    func testMuteModifiersAndTheirIrssiAliases() {
        // A channel-scoped mute carries no mask — the whole channel is muted.
        let parsed = parse("#idlerpg NOUNREAD")
        XCTAssertNil(parsed?.rule.mask)
        XCTAssertEqual(parsed?.rule.channels, ["#idlerpg"])
        XCTAssertEqual(parsed?.rule.levels, ["NOUNREAD"])
        // Canonical order, not the order they were typed.
        XCTAssertEqual(parse("#idlerpg NONOTIFY NOUNREAD")?.rule.levels, ["NOUNREAD", "NONOTIFY"])
        XCTAssertEqual(parse("#idlerpg no_act")?.rule.levels, ["NOUNREAD"])
        XCTAssertEqual(parse("#idlerpg noact")?.rule.levels, ["NOUNREAD"])
    }

    func testABareTokenStaysASenderMaskRatherThanAChannel() {
        let parsed = parse("spambot NONOTIFY")
        XCTAssertEqual(parsed?.rule.mask, "spambot")
        XCTAssertNil(parsed?.rule.channels)
        XCTAssertEqual(parsed?.rule.levels, ["NONOTIFY"])
    }

    func testAllDoesNotExpandToIncludeTheModifierLevels() {
        // The modifiers aren't in `defs`, so expanding ALL can't pull them in — a rule that
        // hid everything would otherwise also silence the badge and the notification.
        let levels = parse("bob ALL -PUBLIC")?.rule.levels ?? []
        XCTAssertFalse(levels.contains("NOUNREAD"))
        XCTAssertFalse(levels.contains("NONOTIFY"))
        XCTAssertFalse(levels.contains("NOHIGHLIGHT"))
    }

    // MARK: - Content patterns & channels

    func testRegexpPatternGroupAndChannel() {
        let parsed = parse("-regexp -pattern (word1|word2) #channel")
        XCTAssertNil(parsed?.rule.mask)
        XCTAssertEqual(parsed?.rule.channels, ["#channel"])
        XCTAssertEqual(parsed?.rule.pattern, "(word1|word2)")
        XCTAssertEqual(parsed?.rule.patternKind, .regex)
        XCTAssertEqual(parsed?.rule.levels, ["ALL"])
    }

    func testFullWithAQuotedMultiWordPattern() {
        let parsed = parse("-full -pattern \"two words\" PUBLIC")
        XCTAssertEqual(parsed?.rule.pattern, "two words")
        XCTAssertEqual(parsed?.rule.patternKind, .full)
        XCTAssertEqual(parsed?.rule.levels, ["PUBLIC"])
    }

    func testDefaultPatternKindIsSubstring() {
        XCTAssertEqual(parse("-pattern spam")?.rule.patternKind, .substr)
    }

    func testChannelScopeIsLowercased() {
        // Channel names are case-insensitive on the wire and the matcher compares them that
        // way, but the stored value is what the settings pane and the listing show.
        XCTAssertEqual(parse("bob #LoudChannel")?.rule.channels, ["#loudchannel"])
    }

    // MARK: - Subtractive levels

    func testAllMinusLevelsExpandsThenRemoves() {
        let rule = parse("#irssi ALL -PUBLIC -ACTIONS")?.rule
        XCTAssertEqual(rule?.channels, ["#irssi"])
        let levels = rule?.levels ?? []
        XCTAssertFalse(levels.contains("PUBLIC"))
        XCTAssertFalse(levels.contains("ACTIONS"))
        XCTAssertTrue(levels.contains("JOINS"))
        XCTAssertTrue(levels.contains("MSGS"))
    }

    func testSubtractingEveryLevelIsAnError() {
        // Not a rule with no levels — that would store something that matches nothing and sit
        // in the listing looking like it works.
        XCTAssertEqual(error("bob PUBLIC -PUBLIC"), "no levels remain")
    }

    // MARK: - Flags & errors

    func testExceptSetsTheWhitelistFlag() {
        let parsed = parse("-except *!*@*.irssi.org CTCPS")
        XCTAssertEqual(parsed?.rule.mask, "*!*@*.irssi.org")
        XCTAssertEqual(parsed?.rule.isExcept, true)
        XCTAssertEqual(parsed?.rule.levels, ["CTCPS"])
    }

    func testTimeComputesExpiryFromNow() {
        let parsed = parse("-time 5days christmas PUBLICS")
        XCTAssertEqual(parsed?.rule.mask, "christmas")
        XCTAssertEqual(parsed?.rule.levels, ["PUBLIC"])
        XCTAssertEqual(parsed?.rule.expiresAt, ISOTime.parse("2026-06-23T00:00:00.000Z"))
        // A bare number is seconds.
        XCTAssertEqual(parse("-time 300 mike")?.rule.expiresAt, ISOTime.parse("2026-06-18T00:05:00.000Z"))
        XCTAssertEqual(parse("-time 30m bob")?.rule.expiresAt, ISOTime.parse("2026-06-18T00:30:00.000Z"))
        // A space between the count and the unit needs quoting: `-time` reads ONE token, so
        // `-time 7 days bob` makes a 7-second rule and then chokes on a second mask. The
        // duration grammar allows the space for exactly this quoted form.
        XCTAssertEqual(parse("-time \"7 days\" bob")?.rule.expiresAt, ISOTime.parse("2026-06-25T00:00:00.000Z"))
        XCTAssertEqual(error("-time 7 days bob")?.contains("unexpected argument"), true)
    }

    func testRejectsAnAbsurdTimeRatherThanOverflowingTheDate() {
        XCTAssertEqual(error("-time 99999999999999999999 bob")?.contains("time"), true)
    }

    func testRejectsATimeThatIsNotADuration() {
        XCTAssertEqual(error("-time soon bob")?.contains("soon"), true)
        XCTAssertEqual(error("-time")?.contains("(missing)"), true)
    }

    func testRejectsRepliesAsUnsupported() {
        XCTAssertEqual(error("-replies *!*@*.irssi.org ALL")?.contains("replies"), true)
    }

    func testRejectsAnUnknownFlagAndAMissingPatternValue() {
        XCTAssertEqual(error("-bogus bob")?.contains("unknown flag"), true)
        XCTAssertEqual(error("bob -pattern")?.contains("pattern"), true)
    }

    func testRejectsASecondMask() {
        // Two bare tokens can't both be the sender; saying so beats silently ignoring one.
        XCTAssertEqual(error("bob alice")?.contains("unexpected argument"), true)
    }

    // MARK: - Scope (lurker #350)

    func testDefaultsToGlobal() {
        XCTAssertEqual(parse("bob")?.scopeNetwork, false)
    }

    func testNetworkFlagsScopeToTheCurrentNetwork() {
        XCTAssertEqual(parse("-network bob")?.scopeNetwork, true)
        XCTAssertEqual(parse("-net bob NOHIGHLIGHT")?.scopeNetwork, true)
    }

    func testGlobalFlagIsTheExplicitDefault() {
        XCTAssertEqual(parse("-global bob")?.scopeNetwork, false)
    }

    func testScopeFlagsDoNotLeakIntoTheOtherDimensions() {
        let parsed = parse("-network bob JOINS")
        XCTAssertEqual(parsed?.rule.mask, "bob")
        XCTAssertEqual(parsed?.rule.levels, ["JOINS"])
        XCTAssertEqual(parsed?.scopeNetwork, true)
    }

    // MARK: - Tokenizer

    func testTokenizerKeepsGroupsAndQuotedStringsWhole() {
        XCTAssertEqual(IgnoreArgs.tokenize("-pattern (a|b c) bob"), ["-pattern", "(a|b c)", "bob"])
        XCTAssertEqual(IgnoreArgs.tokenize("-pattern \"two words\" bob"), ["-pattern", "two words", "bob"])
        XCTAssertEqual(IgnoreArgs.tokenize("-pattern 'two words'"), ["-pattern", "two words"])
        // Nested groups close at the matching paren, not the first one.
        XCTAssertEqual(IgnoreArgs.tokenize("-pattern ((a|b)|c) x"), ["-pattern", "((a|b)|c)", "x"])
        // An unbalanced group runs to the end of the line rather than eating the parser.
        XCTAssertEqual(IgnoreArgs.tokenize("-pattern (a|b"), ["-pattern", "(a|b"])
        XCTAssertEqual(IgnoreArgs.tokenize("   "), [])
    }

    func testDurationRejectsNonAsciiDigits() {
        // The reference's `\d` is ASCII-only. ICU's is not, so a regex here would have
        // accepted `٧days` and stored an expiry the server's parser would have refused.
        XCTAssertNil(IgnoreArgs.duration("٧days"))
        XCTAssertNil(IgnoreArgs.duration("days"))
        XCTAssertNil(IgnoreArgs.duration("5 fortnights"))
        XCTAssertEqual(IgnoreArgs.duration("5"), 5000)
    }

    // MARK: - The rule as the listing shows it

    func testSummaryNamesEveryDimensionTheRuleConstrains() {
        let rule = parse("-except -regexp -pattern (spam|ham) *zzz* #chan NICKS")?.rule
        let summary = rule?.summary(global: true) ?? ""
        XCTAssertTrue(summary.contains("*zzz*"), summary)
        XCTAssertTrue(summary.contains("[global]"), summary)
        XCTAssertTrue(summary.contains("NICKS"), summary)
        XCTAssertTrue(summary.contains("#chan"), summary)
        XCTAssertTrue(summary.contains("/(spam|ham)/"), summary)
        XCTAssertTrue(summary.contains("[except]"), summary)
        // A network-scoped rule doesn't claim to be global.
        XCTAssertFalse(rule?.summary(global: false).contains("[global]") ?? true)
    }

    func testSummaryQuotesANonRegexPatternAndNotesAnExpiry() {
        let rule = parse("-pattern spam -time 1day bob")?.rule
        let summary = rule?.summary(global: false) ?? ""
        XCTAssertTrue(summary.contains("\"spam\""), summary)
        XCTAssertTrue(summary.contains("expires"), summary)
    }

    func testSummaryOfAMasklessRuleSaysAnyone() {
        XCTAssertTrue(parse("#idlerpg NOUNREAD")?.rule.summary(global: false).hasPrefix("*") ?? false)
    }
}

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The envelope parser (#277), ported alongside `shared/parseRelay.ts` — and with that file's
/// tests ported too, so the two clients are held to the same reading of the same bot output. Cases
/// beyond the web's are marked where they appear; they cover the two things this port does
/// differently (`NSRegularExpression` instead of a JS `RegExp`, and UTF-16 index mapping instead
/// of JS string slicing).
final class RelayEnvelopeTests: XCTestCase {

    // MARK: - Default formats

    func testParsesTheBracketedSourceForm() {
        XCTAssertEqual(
            RelayEnvelope.parse("[Discord] <alice> hello there"),
            RelayParse(source: "Discord", nick: "alice", text: "hello there")
        )
    }

    func testParsesTheBareNickForm() {
        XCTAssertEqual(
            RelayEnvelope.parse("<bob> hey everyone"),
            RelayParse(source: nil, nick: "bob", text: "hey everyone")
        )
    }

    func testKeepsBracketsAndAnglesInsideTheBody() {
        XCTAssertEqual(
            RelayEnvelope.parse("[Telegram] <carol> 2 < 3 and [maybe] > nope"),
            RelayParse(source: "Telegram", nick: "carol", text: "2 < 3 and [maybe] > nope")
        )
    }

    func testPreservesAnEmptyRelayedMessage() {
        XCTAssertEqual(
            RelayEnvelope.parse("[IRC] <dave> "),
            RelayParse(source: "IRC", nick: "dave", text: "")
        )
    }

    func testDoesNotMatchAPlainLine() {
        XCTAssertNil(RelayEnvelope.parse("just a normal line from the bot"))
        XCTAssertNil(RelayEnvelope.parse("lunch < later"))
    }

    func testReturnsNilForEmptyBodies() {
        XCTAssertNil(RelayEnvelope.parse(""))
        XCTAssertNil(RelayEnvelope.parse(nil))
    }

    func testHandlesASourceTagContainingSpaces() {
        XCTAssertEqual(
            RelayEnvelope.parse("[Game Chat] <eve> gg"),
            RelayParse(source: "Game Chat", nick: "eve", text: "gg")
        )
    }

    // MARK: - Membership prefixes

    func testDropsMembershipPrefixesFromTheNick() {
        XCTAssertEqual(
            RelayEnvelope.parse("<+bob> hi"),
            RelayParse(source: nil, nick: "bob", text: "hi")
        )
        XCTAssertEqual(
            RelayEnvelope.parse("[net] <@+carol> yo"),
            RelayParse(source: "net", nick: "carol", text: "yo")
        )
        XCTAssertEqual(
            RelayEnvelope.parse("<dave> hey"),
            RelayParse(source: nil, nick: "dave", text: "hey")
        )
    }

    /// Beyond the web's suite. A nick that is *only* prefix glyphs strips to nothing, and an
    /// envelope with no speaker in it isn't a re-attribution — it has to fall through to the next
    /// template (and here, to no match at all) rather than produce a nameless author.
    func testANickOfNothingButPrefixesDoesNotMatch() {
        XCTAssertNil(RelayEnvelope.parse("<@@> hi"))
    }

    // MARK: - Custom templates

    func testHonorsACustomTemplate() {
        XCTAssertEqual(
            RelayEnvelope.parse("frank: yo", pattern: "{nick}: {message}"),
            RelayParse(source: nil, nick: "frank", text: "yo")
        )
        XCTAssertEqual(
            RelayEnvelope.parse("(Matrix) grace » hi", pattern: "({source}) {nick} » {message}"),
            RelayParse(source: "Matrix", nick: "grace", text: "hi")
        )
    }

    func testFallsBackToTheDefaultsWhenTheCustomPatternIsBlank() {
        XCTAssertEqual(
            RelayEnvelope.parse("[Slack] <heidi> ok", pattern: "   "),
            RelayParse(source: "Slack", nick: "heidi", text: "ok")
        )
    }

    func testReturnsNilWhenTheTemplateLacksRequiredPlaceholders() {
        XCTAssertNil(RelayEnvelope.parse("whatever", pattern: "no placeholders here"))
        XCTAssertNil(RelayEnvelope.parse("<x> y", pattern: "<{nick}> no-message-placeholder"))
    }

    // MARK: - Reversed layout (nick before source)

    /// A real ##videogames bot that posts `<nick> [source] message` — the reverse of the default —
    /// plus a stray colour code and fancy unicode/emoji in the body.
    private let reversed = "\u{03}03<EyeSeeYou> [Discord] Present: 𝔅𝔢𝔩𝔦𝔞𝔩 ChatGAYTB 🌈🏳️‍🌈 syrius"

    func testAMatchingCustomTemplateExtractsTheReversedLayout() {
        XCTAssertEqual(
            RelayEnvelope.parse(reversed, pattern: "<{nick}> [{source}] {message}"),
            RelayParse(
                source: "Discord", nick: "EyeSeeYou",
                text: "Present: 𝔅𝔢𝔩𝔦𝔞𝔩 ChatGAYTB 🌈🏳️‍🌈 syrius"
            )
        )
    }

    func testTheDefaultsStillAttributeTheReversedLayoutButLeaveTheSourceInline() {
        // The bare `<nick> message` default catches it, so re-attribution works, but the reversed
        // [source] tag isn't recognized — it stays in the body. This is the behavior that
        // motivates the custom template above.
        XCTAssertEqual(
            RelayEnvelope.parse(reversed),
            RelayParse(
                source: nil, nick: "EyeSeeYou",
                text: "[Discord] Present: 𝔅𝔢𝔩𝔦𝔞𝔩 ChatGAYTB 🌈🏳️‍🌈 syrius"
            )
        )
    }

    // MARK: - mIRC formatting

    func testStripsColourCodesAndTheVoicePrefixOffTheNick() {
        // The bot colours `+FAST` (voiced on efnet) with mIRC colour 13 and resets before `>`. We
        // want a clean `FAST` so colouring, Reply and Copy all target the nick.
        XCTAssertEqual(
            RelayEnvelope.parse("[efnet] <\u{03}13+FAST\u{03}> ultros: bet"),
            RelayParse(source: "efnet", nick: "FAST", text: "ultros: bet")
        )
    }

    func testStripsColourCodesWrappingTheSourceTag() {
        XCTAssertEqual(
            RelayEnvelope.parse("\u{03}04[efnet]\u{03} <\u{03}13FAST\u{03}> hey there"),
            RelayParse(source: "efnet", nick: "FAST", text: "hey there")
        )
    }

    func testStripsBoldAndUnderlineTogglesAroundTheEnvelope() {
        XCTAssertEqual(
            RelayEnvelope.parse("[\u{02}Discord\u{02}] <\u{1f}underlined\u{1f}> hello"),
            RelayParse(source: "Discord", nick: "underlined", text: "hello")
        )
    }

    func testPreservesTheMessagesOwnFormatting() {
        // The nick is coloured (stripped for matching), but the message is bold — and that bold
        // has to survive into the re-attributed line.
        XCTAssertEqual(
            RelayEnvelope.parse("[efnet] <\u{03}13FAST\u{03}> \u{02}bold msg\u{02}"),
            RelayParse(source: "efnet", nick: "FAST", text: "\u{02}bold msg\u{02}")
        )
        XCTAssertEqual(
            RelayEnvelope.parse("<\u{03}07relaybot\u{03}> \u{03}04red\u{03} and \u{03}09green\u{03}"),
            RelayParse(
                source: nil, nick: "relaybot",
                text: "\u{03}04red\u{03} and \u{03}09green\u{03}"
            )
        )
    }

    /// Beyond the web's suite, and the reason `rawIndex` counts UTF-16 units rather than
    /// characters: an astral-plane glyph *before* the message is two units and one Character, so a
    /// character-counting map would slice two units short and behead the body.
    func testRecoversFormattingPastAnAstralGlyphInTheEnvelope() {
        XCTAssertEqual(
            RelayEnvelope.parse("[🌈net] <\u{03}13FAST\u{03}> \u{02}bold\u{02}"),
            RelayParse(source: "🌈net", nick: "FAST", text: "\u{02}bold\u{02}")
        )
    }

    // MARK: - Template compilation

    func testCompilesTheBuiltInDefaults() {
        for pattern in RelayEnvelope.defaultPatterns {
            XCTAssertNotNil(RelayEnvelope.compile(pattern), pattern)
        }
    }

    func testRecordsSlotOrder() {
        XCTAssertEqual(
            RelayEnvelope.compile("[{source}] <{nick}> {message}")?.slots,
            [.source, .nick, .message]
        )
    }

    /// ⚠ `{message}` being the last *placeholder* is not the same as it being the end of the
    /// template. Slicing the raw body to its end on a template with a trailing literal put that
    /// literal back into what the person said.
    func testATrailingLiteralIsNotPartOfTheMessage() {
        XCTAssertEqual(
            RelayEnvelope.parse("<alice> hi there (via bridge)", pattern: "<{nick}> {message} (via bridge)"),
            RelayParse(source: nil, nick: "alice", text: "hi there")
        )
        // The message's own formatting still survives the bounded slice — but a control code
        // sitting exactly ON the end boundary falls to the envelope's side, because `rawIndex`
        // answers where the next VISIBLE character begins and a code contributes none. So the
        // closing `\u{02}` here is dropped and the run is left open.
        //
        // Deliberately not chased. A toggle at the end of a string closes nothing: the renderer
        // parses each message on its own, so `\u{02}bold` and `\u{02}bold\u{02}` draw identically,
        // and no formatting can leak past a row. Buying the byte back would mean a third scanner
        // over the same control codes — the thing `testRawIndexAgreesWithStrip` exists to keep
        // this file from accumulating.
        XCTAssertEqual(
            RelayEnvelope.parse(
                "<alice> \u{02}bold\u{02} -- end", pattern: "<{nick}> {message} -- end"
            ),
            RelayParse(source: nil, nick: "alice", text: "\u{02}bold")
        )
    }

    /// The counterpart: with nothing after `{message}`, the slice runs to the end of the body so a
    /// closing code stays attached to the run it closes. (Covered above too, but stated here as
    /// the invariant `endsWithMessage` exists to keep.)
    func testATemplateEndingInMessageKeepsTrailingFormatCodes() {
        XCTAssertEqual(RelayEnvelope.parse("<alice> \u{02}bold\u{02}")?.text, "\u{02}bold\u{02}")
        XCTAssertTrue(RelayEnvelope.compile("<{nick}> {message}")?.endsWithMessage == true)
        XCTAssertTrue(RelayEnvelope.compile("<{nick}> {message} x")?.endsWithMessage == false)
    }

    func testRejectsATemplateMissingNickOrMessage() {
        XCTAssertNil(RelayEnvelope.compile("<{nick}> static"))
        XCTAssertNil(RelayEnvelope.compile("{message} only"))
    }

    func testTreatsRegexMetacharactersInTheTemplateAsLiterals() {
        // The `.` and `*` are literal here, so a real `.*` in the body must match them verbatim
        // rather than acting as a wildcard.
        XCTAssertEqual(
            RelayEnvelope.parse("a.*b ivan done", pattern: "{source}.*b {nick} {message}"),
            RelayParse(source: "a", nick: "ivan", text: "done")
        )
        XCTAssertNil(RelayEnvelope.parse("aXXb ivan done", pattern: "{source}.*b {nick} {message}"))
    }

    /// ⚠ The property the escaping exists for, stated as a test rather than left to the comment on
    /// `RelayEnvelope`. A template is user input; reaching `NSRegularExpression` unescaped it would
    /// be a live regex running against every line a marked bot ever said. An unbalanced `(` is the
    /// cheapest proof: as a pattern it doesn't compile at all, so a template that still parses a
    /// body containing a literal `(` can only have been escaped.
    func testAUserTemplateCannotInjectRegex() {
        XCTAssertEqual(
            RelayEnvelope.parse("( jan hi", pattern: "( {nick} {message}"),
            RelayParse(source: nil, nick: "jan", text: "hi")
        )
        // And an alternation in a template is text, not a choice: `a|b` matches only `a|b`.
        XCTAssertNil(RelayEnvelope.parse("a kim hi", pattern: "a|b {nick} {message}"))
        XCTAssertEqual(
            RelayEnvelope.parse("a|b kim hi", pattern: "a|b {nick} {message}"),
            RelayParse(source: nil, nick: "kim", text: "hi")
        )
    }

    /// A body with a trailing newline must not match, which is where ICU's `$` and JavaScript's
    /// disagree — hence the `\A`/`\z` anchors. Without them the two clients would attribute the
    /// same line differently.
    func testATrailingNewlineDoesNotSatisfyTheAnchor() {
        XCTAssertNil(RelayEnvelope.parse("<bob> hi\n"))
    }

    // MARK: - The two scanners agree

    /// ⚠ `IRCFormatting.rawIndex` walks control codes in a second scanner, separate from the one
    /// `parse` uses. This is what pins them together: for every visible offset in a corpus of
    /// awkward bodies, slicing the raw text at the mapped index and stripping it must equal
    /// stripping first and slicing the result. A disagreement lands a slice mid-code, and the
    /// symptom in the app is a relayed message that opens with stray colour digits.
    func testRawIndexAgreesWithStrip() {
        let corpus = [
            "plain text with no codes at all",
            "\u{03}13+FAST\u{03} ultros: bet",
            "\u{03}04,12both halves\u{03} then \u{03}9 one",
            "\u{03}04,not-a-background — the comma is text",
            "\u{03} bare reset, \u{03}99 out of palette, \u{0f} full reset",
            "\u{04}ff8800truecolor\u{04}00ff00,0000ff pair\u{04}nothex",
            "\u{02}bold\u{02} \u{1d}italic\u{1d} \u{1f}under\u{1f} \u{1e}strike\u{1e} \u{11}mono\u{16}rev",
            "🌈🏳️‍🌈 astral \u{03}03and colour\u{03} 𝔅𝔢𝔩𝔦𝔞𝔩",
            "trailing code at the very end\u{03}",
            "\u{03}1",
        ]
        for raw in corpus {
            let stripped = IRCFormatting.strip(raw)
            let strippedUnits = (stripped as NSString).length
            for offset in 0...strippedUnits {
                let rawStart = IRCFormatting.rawIndex(in: raw, visibleOffset: offset)
                XCTAssertEqual(
                    IRCFormatting.strip((raw as NSString).substring(from: rawStart)),
                    (stripped as NSString).substring(from: offset),
                    "offset \(offset) of \(raw.debugDescription)"
                )
            }
        }
    }

    func testRawIndexClampsOutOfRangeOffsets() {
        XCTAssertEqual(IRCFormatting.rawIndex(in: "abc", visibleOffset: -1), 0)
        XCTAssertEqual(IRCFormatting.rawIndex(in: "abc", visibleOffset: 99), 3)
        XCTAssertEqual(IRCFormatting.rawIndex(in: "", visibleOffset: 3), 0)
    }
}

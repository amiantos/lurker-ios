// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Ported case-for-case from the web client's `spoilerMarkup.test.ts`. The two implementations
/// have to turn the same typed text into the same bytes, so they get the same tests — a
/// divergence here is a message that reads differently depending on which client sent it.
final class SpoilerMarkupTests: XCTestCase {
    private let open = "\u{3}14,14"
    private let close = "\u{3}"

    func testLeavesTextWithNoDoublePipesUntouched() {
        XCTAssertEqual(SpoilerMarkup.apply(to: "hello world"), "hello world")
        XCTAssertEqual(SpoilerMarkup.apply(to: ""), "")
        XCTAssertEqual(SpoilerMarkup.apply(to: "a | b"), "a | b")
    }

    func testRewritesABasicSpoiler() {
        XCTAssertEqual(SpoilerMarkup.apply(to: "||secret||"), "\(open)secret\(close)")
    }

    func testPreservesTextAroundASpoiler() {
        XCTAssertEqual(
            SpoilerMarkup.apply(to: "the answer is ||42|| ok?"),
            "the answer is \(open)42\(close) ok?"
        )
    }

    func testRewritesMultipleSpoilers() {
        XCTAssertEqual(
            SpoilerMarkup.apply(to: "||a|| and ||b||"),
            "\(open)a\(close) and \(open)b\(close)"
        )
    }

    /// `||a||b||c||` is a spoiler, a literal `b`, then another spoiler — the nearest closing `||`
    /// wins, matching Discord, which is where the expectation comes from.
    func testPairsNonGreedily() {
        XCTAssertEqual(
            SpoilerMarkup.apply(to: "||a||b||c||"),
            "\(open)a\(close)b\(open)c\(close)"
        )
    }

    func testLeavesAnUnmatchedDelimiterLiteral() {
        XCTAssertEqual(SpoilerMarkup.apply(to: "||unclosed"), "||unclosed")
        XCTAssertEqual(SpoilerMarkup.apply(to: "trailing||"), "trailing||")
    }

    func testLeavesAnEmptyPairLiteral() {
        XCTAssertEqual(SpoilerMarkup.apply(to: "||||"), "||||")
    }

    func testTreatsBackslashPipePipeAsAnEscape() {
        XCTAssertEqual(SpoilerMarkup.apply(to: #"exit code \|| 1"#), "exit code || 1")
        XCTAssertEqual(SpoilerMarkup.apply(to: #"\||not a spoiler\||"#), "||not a spoiler||")
    }

    func testAllowsAnEscapedDelimiterInsideARealSpoiler() {
        XCTAssertEqual(
            SpoilerMarkup.apply(to: #"||has \|| inside||"#),
            "\(open)has || inside\(close)"
        )
    }

    func testLeavesALoneBackslashLiteral() {
        XCTAssertEqual(SpoilerMarkup.apply(to: #"a \ b"#), #"a \ b"#)
        XCTAssertEqual(SpoilerMarkup.apply(to: #"path\to\file"#), #"path\to\file"#)
    }

    /// A trailing `\|` must not read as the start of an escape and eat past the end of the string.
    /// Swift indexes an Array<Character> rather than JS's forgiving string subscript, so this is
    /// the case where a missing bounds check would trap rather than quietly return undefined.
    func testHandlesATruncatedEscapeAtTheEnd() {
        XCTAssertEqual(SpoilerMarkup.apply(to: #"trailing \|"#), #"trailing \|"#)
        XCTAssertEqual(SpoilerMarkup.apply(to: #"\|"#), #"\|"#)
        XCTAssertEqual(SpoilerMarkup.apply(to: "|"), "|")
    }
}

/// Which commands rewrite `||` and which must not. The exclusions are the point: `/ns` and `/cs`
/// carry `identify <password>`, and a password containing `||` that arrives at NickServ as
/// control codes fails a login for reasons nobody will diagnose. The web left this to a comment
/// and a convention; here it's asserted.
final class SpoilerCommandCoverageTests: XCTestCase {
    private let open = "\u{3}14,14"

    private func parse(_ input: String) -> ParsedInput {
        CommandParser.parse(input, networkId: 1, target: "#chan")
    }

    /// Text bodies the user authored: these DO get rewritten.
    func testRewritesUserAuthoredChatBodies() {
        guard case .message(let plain) = parse("say ||secret||") else {
            return XCTFail("plain text should be a message")
        }
        XCTAssertTrue(plain.contains(open), "plain send")

        guard case .message(let escaped) = parse("//not a command ||secret||") else {
            return XCTFail("//-escaped should be a message")
        }
        XCTAssertTrue(escaped.contains(open), "//-escaped send")

        guard case .command(let me) = parse("/me hides ||something||"),
              case .action(_, let meText)? = me.first
        else { return XCTFail("/me should produce an action") }
        XCTAssertTrue(meText.contains(open), "/me")

        guard case .command(let msg) = parse("/msg bob ||secret||"),
              case .send(_, let msgText)? = msg.first
        else { return XCTFail("/msg should produce a send") }
        XCTAssertTrue(msgText.contains(open), "/msg")

        guard case .command(let notice) = parse("/notice bob ||secret||"),
              case .notice(_, let noticeText)? = notice.first
        else { return XCTFail("/notice should produce a notice") }
        XCTAssertTrue(noticeText.contains(open), "/notice")
    }

    /// ⚠⚠ Service and raw verbs must reach the wire byte-for-byte as typed. A password is the
    /// realistic case, and `||` is a plausible character in one.
    ///
    /// ⚠ Every fixture holds a MATCHED pair. An earlier version used `hunter||2` — a single
    /// unmatched `||`, which `SpoilerMarkup` leaves alone regardless — so the test passed with
    /// the exclusion deliberately broken. Verified by mutation: routing `/ns` through `chatBody`
    /// now fails this, and did not before.
    func testLeavesServiceAndRawVerbsUntouched() {
        for input in [
            "/ns identify ||hunter2||",
            "/cs identify #chan ||hunter2||",
            "/raw PRIVMSG bob :||literal||",
            "/quote PRIVMSG bob :||literal||",
        ] {
            guard case .command(let effects) = parse(input),
                  case .raw(let line)? = effects.first
            else {
                XCTFail("\(input) should produce a raw line")
                continue
            }
            XCTAssertTrue(line.contains("||"), "\(input) must keep its literal pipes")
            XCTAssertFalse(line.contains("\u{3}"), "\(input) must carry no colour codes")
        }
    }

    /// `/slap`'s body is generated rather than typed, so there is nothing in it to spoiler — and
    /// a nick is not a place a `||` should be interpreted.
    func testDoesNotRewriteGeneratedBodies() {
        guard case .command(let effects) = parse("/slap bo||b"),
              case .action(_, let text)? = effects.first
        else { return XCTFail("/slap should produce an action") }
        XCTAssertFalse(text.contains("\u{3}"))
    }
}

/// The half that matters at runtime: what we emit has to come back through our own parser as a
/// spoiler. The two live in different files and are free to drift — a pair the parser didn't
/// recognise would ship as visible plaintext, which for a spoiler is the entire failure.
final class SpoilerRoundTripTests: XCTestCase {
    private func runs(_ text: String) -> [FormattingRun] {
        IRCFormatting.parse(text)
    }

    func testEmittedSpoilerParsesBackAsAMatchingColourPair() {
        let parsed = runs(SpoilerMarkup.apply(to: "||secret||"))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.text, "secret")
        XCTAssertEqual(parsed.first?.fg, 14)
        XCTAssertEqual(parsed.first?.bg, 14)
    }

    /// The colour code is two digits and so is the hidden text here: `\u{3}14,14` followed by
    /// `42` must read as grey-on-grey plus the text "42", not as colour 14 on 1442.
    func testDoesNotSwallowLeadingDigitsOfTheHiddenText() {
        let parsed = runs(SpoilerMarkup.apply(to: "the answer is ||42||"))
        XCTAssertEqual(parsed.map(\.text), ["the answer is ", "42"])
        XCTAssertEqual(parsed.last?.fg, 14)
        XCTAssertEqual(parsed.last?.bg, 14)
    }

    /// Spoilers from clients that use the older black-on-black convention still have to read as
    /// spoilers — the rule is "fg == bg", not "fg == 14".
    func testRecognisesAnIncomingBlackOnBlackSpoiler() {
        let parsed = runs("\u{3}01,01secret\u{3}")
        XCTAssertEqual(parsed.first?.fg, 1)
        XCTAssertEqual(parsed.first?.bg, 1)
    }

    /// ⚠⚠ The close is the dangerous end. A bare `\u{3}` followed by a digit is a COLOUR CODE,
    /// so the digit is eaten: `||spoiler||5 stars` used to reach the channel as " stars" in
    /// colour 5, the "5" simply deleted, and `||code||1234` lost two characters. Silent, on the
    /// wire, unrecoverable.
    ///
    /// These assert the round trip rather than the bytes: what matters is that every character
    /// the user typed after the spoiler survives to the other side, and that the spoiler's
    /// background doesn't bleed onto it.
    func testTextAfterASpoilerSurvivesEvenWhenItStartsWithADigit() {
        for (input, hidden, after) in [
            ("||spoiler||5 stars", "spoiler", "5 stars"),
            ("||secret||42 is the code", "secret", "42 is the code"),
            ("||a||0", "a", "0"),
            ("the code is ||1234||5678", "1234", "5678"),
        ] {
            let parsed = runs(SpoilerMarkup.apply(to: input))
            let spoiler = parsed.first { $0.fg == 14 && $0.bg == 14 }
            XCTAssertEqual(spoiler?.text, hidden, "hidden half of \(input)")

            // Everything after the hidden run, concatenated, must equal what was typed after it.
            guard let index = parsed.firstIndex(where: { $0.fg == 14 && $0.bg == 14 }) else {
                XCTFail("no spoiler run in \(input)"); continue
            }
            let tail = parsed[(index + 1)...]
            XCTAssertEqual(tail.map(\.text).joined(), after, "text after \(input)")
            // …and it must not still be sitting on the spoiler's grey box.
            for run in tail {
                XCTAssertNotEqual(run.bg, 14, "background leaked past the spoiler in \(input)")
            }
        }
    }

    /// The common cases keep the cheap one-byte close; only the collision pays for the long one.
    func testKeepsTheBareCloseWhenNothingCollides() {
        XCTAssertTrue(SpoilerMarkup.apply(to: "||a|| ok").hasSuffix("\u{3} ok"))
        XCTAssertTrue(SpoilerMarkup.apply(to: "||a||").hasSuffix("a\u{3}"))
        // A comma is safe: `\u{3},` is not a colour code, only a digit can start one.
        XCTAssertTrue(SpoilerMarkup.apply(to: "||a||,b").hasSuffix("\u{3},b"))
    }
}

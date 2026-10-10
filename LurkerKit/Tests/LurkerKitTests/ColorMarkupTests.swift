// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

final class ColorMarkupTests: XCTestCase {

    /// What the line reads as to any client: the parser's runs, adjacent equal runs merged, and
    /// slot 99 read as no colour — the same normalization `decode` applies.
    private func reads(_ line: String) -> [ColorSpan] {
        ColorMarkup.decode(line) ?? []
    }

    private func assertRoundTrips(_ spans: [ColorSpan], file: StaticString = #filePath, line: UInt = #line) {
        let wire = ColorMarkup.encode(spans)
        let expected = spans.filter { !$0.text.isEmpty }
        XCTAssertEqual(reads(wire), expected, "wire: \(wire.debugDescription)", file: file, line: line)
        XCTAssertEqual(IRCFormatting.strip(wire), spans.map(\.text).joined(), file: file, line: line)
    }

    func testPlainTextIsUntouched() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("hello")]), "hello")
        XCTAssertEqual(ColorMarkup.encode([]), "")
    }

    func testWritesTwoDigitSlots() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("hi", fg: 4)]), "\u{3}04hi")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("hi", fg: 4, bg: 1)]), "\u{3}04,01hi")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("hi", bg: 12)]), "\u{3}99,12hi")
    }

    func testClosesBackToPlain() {
        XCTAssertEqual(
            ColorMarkup.encode([ColorSpan("red", fg: 4), ColorSpan(" plain")]),
            "\u{3}04red\u{3} plain")
    }

    /// The digit trap: a bare close or a one-digit slot followed by a digit swallows it.
    func testDigitsAfterACodeSurvive() {
        assertRoundTrips([ColorSpan("x", fg: 4), ColorSpan("5 stars")])
        assertRoundTrips([ColorSpan("2 cats", fg: 4)])
        assertRoundTrips([ColorSpan("12", fg: 3, bg: 1), ColorSpan("34")])
    }

    /// `\x0304` then `,5` is red on blue.
    func testACommaDigitAfterAForegroundSurvives() {
        assertRoundTrips([ColorSpan(",5 cats", fg: 4)])
        assertRoundTrips([ColorSpan("a"), ColorSpan(",9", fg: 7)])
    }

    /// A bare foreground keeps the background in effect, so dropping one must be said.
    func testDroppingTheBackgroundIsWritten() {
        assertRoundTrips([ColorSpan("box", fg: 0, bg: 1), ColorSpan(" red", fg: 4)])
    }

    func testMixedRoundTrips() {
        assertRoundTrips([
            ColorSpan("plain "), ColorSpan("red", fg: 4), ColorSpan(" on blue", fg: 4, bg: 2),
            ColorSpan(" hilite", bg: 8), ColorSpan(" done"),
        ])
    }

    func testCommandVerbStaysBare() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/me waves", fg: 4)]), "/me \u{3}04waves")
        XCTAssertEqual(
            ColorMarkup.encode([ColorSpan("/me ", fg: 4), ColorSpan("waves", fg: 2)]),
            "/me \u{3}02waves")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/SHRUG idk", fg: 4)]), "/SHRUG \u{3}04idk")
        // The escape: both slashes stay bare, and the text after them keeps its colour.
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("//hi", fg: 4)]), "//\u{3}04hi")
    }

    /// The target is a word of the command, not of the message.
    func testMessageTargetsStayBare() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/msg bob hi there", fg: 4)]), "/msg bob \u{3}04hi there")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/notice #c  psst", fg: 4)]), "/notice #c  \u{3}04psst")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/query bob", fg: 4)]), "/query bob")
    }

    /// Any other command has no chat body, so it goes out exactly as typed.
    func testOtherCommandsTakeNoColour() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/join #chan", fg: 4)]), "/join #chan")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/ns identify ", fg: 4), ColorSpan("pw", bg: 2)]), "/ns identify pw")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/away", fg: 4)]), "/away")
    }

    /// The colour stops at the box and resumes after it; the box hides what's inside whatever
    /// colour it was; and `apply`, which still runs on the sent line, leaves it all alone.
    func testBuildsSpoilersInsideColour() {
        let wire = ColorMarkup.encode([ColorSpan("red ||secret|| more", fg: 4)])
        let sent = SpoilerMarkup.apply(to: wire)
        XCTAssertEqual(sent, wire)
        XCTAssertEqual(reads(sent), [
            ColorSpan("red ", fg: 4), ColorSpan("secret", fg: 14, bg: 14), ColorSpan(" more", fg: 4),
        ])
        let inner = ColorMarkup.encode([ColorSpan("a ||"), ColorSpan("x", fg: 4), ColorSpan("|| 5")])
        XCTAssertEqual(reads(SpoilerMarkup.apply(to: inner)), [
            ColorSpan("a "), ColorSpan("x", fg: 14, bg: 14), ColorSpan(" 5"),
        ])
    }

    /// `||` that stays text must still be text after `apply` runs on the sent line — including
    /// one that only became pairable once the spoiler between them was taken out.
    func testLiteralDelimitersSurviveTheRewrite() {
        let wire = ColorMarkup.encode([ColorSpan("||||a||||", fg: 4)])
        let sent = SpoilerMarkup.apply(to: wire)
        XCTAssertEqual(IRCFormatting.strip(sent), "||a||")
        XCTAssertEqual(reads(sent), [
            ColorSpan("||", fg: 4), ColorSpan("a", fg: 14, bg: 14), ColorSpan("||", fg: 4),
        ])
        let escaped = ColorMarkup.encode([ColorSpan("a \\||b|| c", fg: 4)])
        XCTAssertEqual(IRCFormatting.strip(SpoilerMarkup.apply(to: escaped)), "a ||b|| c")
    }

    func testRecolorsEachLine() {
        let wire = ColorMarkup.encode([ColorSpan("one\ntwo", fg: 2)])
        XCTAssertEqual(wire, "\u{3}02one\n\u{3}02two")
        for line in wire.split(separator: "\n") {
            XCTAssertEqual(reads(String(line)).first?.fg, 2)
        }
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("red", fg: 4), ColorSpan("\nplain")]), "\u{3}04red\nplain")
    }

    /// A draft keeps what was typed: no spoilers made, every command keeps its colour — but the
    /// verb stays bare, so it reads back as the command it is.
    func testDraftKeepsWhatWasTyped() {
        XCTAssertEqual(ColorMarkup.encodeDraft([ColorSpan("a ||b||", fg: 4)]), "\u{3}04a ||b||")
        XCTAssertEqual(ColorMarkup.encodeDraft([ColorSpan("/join #x", fg: 4)]), "/join \u{3}04#x")
        let spans = [ColorSpan("/me "), ColorSpan("waves", fg: 4)]
        XCTAssertEqual(ColorMarkup.decode(ColorMarkup.encodeDraft(spans)), spans)
    }

    /// A code in front of the slash makes the line text; the field can't show that, so it's raw.
    func testDeclinesAColouredLeadingSlash() {
        XCTAssertNil(ColorMarkup.decode("\u{3}04/me waves"))
        XCTAssertNotNil(ColorMarkup.decode("/me \u{3}04waves"))
    }

    func testDecodesPaletteColors() {
        XCTAssertEqual(
            ColorMarkup.decode("a\u{3}4red\u{3} b"),
            [ColorSpan("a"), ColorSpan("red", fg: 4), ColorSpan(" b")])
        XCTAssertEqual(ColorMarkup.decode("\u{3}99,05x"), [ColorSpan("x", bg: 5)])
        XCTAssertEqual(ColorMarkup.decode("plain"), [ColorSpan("plain")])
        XCTAssertEqual(ColorMarkup.decode(""), [])
    }

    /// A spoiler is grey on grey, which this model holds — and writes back the same.
    func testDecodesASpoiler() {
        let line = SpoilerMarkup.apply(to: "a ||b|| c")
        XCTAssertEqual(ColorMarkup.decode(line), [ColorSpan("a "), ColorSpan("b", fg: 14, bg: 14), ColorSpan(" c")])
    }

    /// Anything beyond palette colour stays raw, so nothing is lost.
    func testDeclinesWhatItCannotHold() {
        XCTAssertNil(ColorMarkup.decode("\u{2}bold\u{2}"))
        XCTAssertNil(ColorMarkup.decode("\u{1D}it"))
        XCTAssertNil(ColorMarkup.decode("\u{4}FF0000red"))
        XCTAssertNil(ColorMarkup.decode("\u{3}42odd"))
    }

    func testResetReadsAsAColourReset() {
        XCTAssertEqual(ColorMarkup.decode("\u{3}04red\u{F}plain"), [ColorSpan("red", fg: 4), ColorSpan("plain")])
    }

    func testIsColored() {
        XCTAssertFalse(ColorMarkup.isColored([ColorSpan("a")]))
        XCTAssertFalse(ColorMarkup.isColored([ColorSpan("", fg: 3)]))
        XCTAssertTrue(ColorMarkup.isColored([ColorSpan("a", bg: 3)]))
    }
}

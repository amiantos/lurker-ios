// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

final class ColorMarkupTests: XCTestCase {

    /// What a line reads as: the parser's runs, adjacent equal runs merged, slot 99 as no colour.
    private func reads(_ line: String) -> [ColorSpan] {
        ColorMarkup.decode(line) ?? []
    }

    /// What a channel receives for a typed plain-text line: the composer's line through the send
    /// path's chat body, which is where spoilers are made.
    private func sent(_ spans: [ColorSpan]) -> String {
        ColorMarkup.chatBody(ColorMarkup.encode(spans))
    }

    private func assertRoundTrips(_ spans: [ColorSpan], file: StaticString = #filePath, line: UInt = #line) {
        let wire = ColorMarkup.encode(spans)
        XCTAssertEqual(reads(wire), spans.filter { !$0.text.isEmpty }, "wire: \(wire.debugDescription)", file: file, line: line)
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

    /// A keycap is one non-ASCII Character that opens with an ASCII digit scalar.
    func testAKeycapAfterACodeSurvives() {
        assertRoundTrips([ColorSpan("x", fg: 4), ColorSpan("1️⃣ first")])
        assertRoundTrips([ColorSpan("1️⃣", fg: 4)])
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

    // MARK: - Commands

    func testCommandHeadsStayBare() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/me waves", fg: 4)]), "/me \u{3}04waves")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/SHRUG idk", fg: 4)]), "/SHRUG \u{3}04idk")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/msg bob hi there", fg: 4)]), "/msg bob \u{3}04hi there")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/notice #c  psst", fg: 4)]), "/notice #c  \u{3}04psst")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/query bob", fg: 4)]), "/query bob")
        // The escape: both slashes stay bare, and the text after them keeps its colour.
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("//hi", fg: 4)]), "//\u{3}04hi")
    }

    /// Commands whose text is a topic or a reason: the optional channel, the nick and the flags
    /// are words of the command.
    func testReasonsAndTopicsTakeColour() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/topic Welcome", fg: 4)]), "/topic \u{3}04Welcome")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/topic #c Welcome", fg: 4)]), "/topic #c \u{3}04Welcome")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/part bye", fg: 4)]), "/part \u{3}04bye")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/kick bob out", fg: 4)]), "/kick bob \u{3}04out")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/kick #c bob out", fg: 4)]), "/kick #c bob \u{3}04out")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/away -all lunch", fg: 4)]), "/away -all \u{3}04lunch")
        // Only `-all` and `-one` are flags; anything else is the message.
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/away -_- brb", fg: 4)]), "/away \u{3}04-_- brb")
    }

    /// Any other command has no chat body, so it goes out exactly as typed.
    func testOtherCommandsTakeNoColour() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/join #chan", fg: 4)]), "/join #chan")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/ns identify ", fg: 4), ColorSpan("pw", bg: 2)]), "/ns identify pw")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("/away", fg: 4)]), "/away")
    }

    // MARK: - Spoilers

    /// The colour stops at the box and resumes after it, and the box hides what's inside whatever
    /// colour it was.
    func testBuildsSpoilersInsideColour() {
        XCTAssertEqual(reads(sent([ColorSpan("red ||secret|| more", fg: 4)])), [
            ColorSpan("red ", fg: 4), ColorSpan("secret", fg: 14, bg: 14), ColorSpan(" more", fg: 4),
        ])
        XCTAssertEqual(reads(sent([ColorSpan("a ||"), ColorSpan("x", fg: 4), ColorSpan("|| 5")])), [
            ColorSpan("a "), ColorSpan("x", fg: 14, bg: 14), ColorSpan(" 5"),
        ])
    }

    /// Two touching spoilers are two boxes, as the plain rewrite makes them.
    func testTouchingSpoilersStaySeparate() {
        let wire = sent([ColorSpan("||a||||b||", fg: 4)])
        XCTAssertEqual(wire, "\u{3}14,14a\u{3}\u{3}14,14b")
        XCTAssertEqual(IRCFormatting.strip(wire), IRCFormatting.strip(SpoilerMarkup.apply(to: "||a||||b||")))
    }

    /// The draft keeps `||` as typed — spoilers are made on the way out, not in the field.
    func testTheLineKeepsDelimitersAsTyped() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("a ||b||", fg: 4)]), "\u{3}04a ||b||")
        let spans = [ColorSpan("a "), ColorSpan("||b||", fg: 4)]
        XCTAssertEqual(ColorMarkup.decode(ColorMarkup.encode(spans)), spans)
    }

    /// Pairs and escapes are read from the characters, so a colour change between the two `|`
    /// changes nothing about them.
    func testDelimitersSplitByColourStillPair() {
        XCTAssertEqual(
            IRCFormatting.strip(sent([ColorSpan("|", fg: 4), ColorSpan("|x||", fg: 2)])), "x")
        XCTAssertEqual(
            IRCFormatting.strip(sent([ColorSpan("x\\", fg: 4), ColorSpan("||y", fg: 2)])), "x||y")
        XCTAssertEqual(
            IRCFormatting.strip(sent([ColorSpan("|", fg: 4), ColorSpan("|x", fg: 2)])), "||x")
    }

    /// A plain body is the old rewrite, byte for byte.
    func testAPlainBodyIsTheOldRewrite() {
        for body in ["||a||", "a || b", "x \\||y||", "||a||5"] {
            XCTAssertEqual(ColorMarkup.chatBody(body), SpoilerMarkup.apply(to: body))
        }
    }

    // MARK: - Line breaks

    func testRecolorsEachLine() {
        let wire = ColorMarkup.encode([ColorSpan("one\ntwo", fg: 2)])
        XCTAssertEqual(wire, "\u{3}02one\u{3}\n\u{3}02two")
        for line in wire.split(separator: "\n") {
            XCTAssertEqual(reads(String(line)).first?.fg, 2)
        }
    }

    /// A plain line after a coloured one has to read as plain in the joined text too.
    func testAPlainLineAfterAColouredOneStaysPlain() {
        assertRoundTrips([ColorSpan("red", fg: 4), ColorSpan("\nplain")])
        assertRoundTrips([ColorSpan("box", fg: 0, bg: 1), ColorSpan("\n"), ColorSpan("fg only", fg: 4)])
    }

    func testCRLFAndCRAreLineBreaks() {
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("one\r\ntwo", fg: 2)]), "\u{3}02one\u{3}\r\n\u{3}02two")
        XCTAssertEqual(ColorMarkup.encode([ColorSpan("one\rtwo", fg: 2)]), "\u{3}02one\u{3}\r\u{3}02two")
    }

    // MARK: - Decoding

    func testDecodesPaletteColors() {
        XCTAssertEqual(
            ColorMarkup.decode("a\u{3}4red\u{3} b"),
            [ColorSpan("a"), ColorSpan("red", fg: 4), ColorSpan(" b")])
        XCTAssertEqual(ColorMarkup.decode("\u{3}99,05x"), [ColorSpan("x", bg: 5)])
        XCTAssertEqual(ColorMarkup.decode("plain"), [ColorSpan("plain")])
        XCTAssertEqual(ColorMarkup.decode(""), [])
    }

    /// A reset with nothing to reset reads as the plain text it shows.
    func testDecodesAResetOnlyLineAsPlain() {
        XCTAssertEqual(ColorMarkup.decode("\u{3}99hello"), [ColorSpan("hello")])
    }

    /// Anything beyond palette colour stays raw, so nothing is lost.
    func testDeclinesWhatItCannotHold() {
        XCTAssertNil(ColorMarkup.decode("\u{2}bold\u{2}"))
        XCTAssertNil(ColorMarkup.decode("\u{1D}it"))
        XCTAssertNil(ColorMarkup.decode("\u{4}FF0000red"))
        XCTAssertNil(ColorMarkup.decode("\u{3}42odd"))
        // No text follows it, so it makes no run — but it's still the colour in effect.
        XCTAssertNil(ColorMarkup.decode("\u{3}04red\u{3}42"))
        XCTAssertNil(ColorMarkup.decode("\u{3}04,42red"))
    }

    /// Shown without its code, each of these would send as a different line.
    func testDeclinesACodeInTheHead() {
        XCTAssertNil(ColorMarkup.decode("\u{3}04/me waves"))
        XCTAssertNil(ColorMarkup.decode("/j\u{3}04oin #x"))
        XCTAssertNil(ColorMarkup.decode("/msg \u{3}04bob hi"))
        XCTAssertNotNil(ColorMarkup.decode("/me \u{3}04waves"))
        XCTAssertNotNil(ColorMarkup.decode("/msg bob \u{3}04hi"))
    }

    /// A command with no chat body can't keep colour, so a coloured one stays raw.
    func testDeclinesColourOnACommandWithoutABody() {
        XCTAssertNil(ColorMarkup.decode("/join \u{3}04#x"))
        // A reset changes no colour, but in front of the slash it's what makes the line text.
        XCTAssertNil(ColorMarkup.decode("\u{3}/join #x"))
        XCTAssertNil(ColorMarkup.decode("\u{F}/quit bye"))
        XCTAssertNil(ColorMarkup.decode("/j\u{3}oin #x"))
        XCTAssertEqual(ColorMarkup.decode("/join #x"), [ColorSpan("/join #x")])
    }

    func testResetReadsAsAColourReset() {
        XCTAssertEqual(ColorMarkup.decode("\u{3}04red\u{F}plain"), [ColorSpan("red", fg: 4), ColorSpan("plain")])
    }

    func testIsColored() {
        XCTAssertFalse(ColorMarkup.isColored([ColorSpan("a")]))
        XCTAssertFalse(ColorMarkup.isColored([ColorSpan("", fg: 3)]))
        XCTAssertTrue(ColorMarkup.isColored([ColorSpan("a", bg: 3)]))
    }

    /// The send path makes the spoilers: the parser runs the coloured body through `chatBody`.
    func testTheParserMakesSpoilersInsideColour() {
        let line = ColorMarkup.encode([ColorSpan("/me hides ||it|| ok", fg: 4)])
        guard case .command(let effects) = CommandParser.parse(line, networkId: 1, target: "#c"),
              case .action(_, let text)? = effects.first
        else { return XCTFail("expected an action") }
        XCTAssertEqual(reads(text), [
            ColorSpan("hides ", fg: 4), ColorSpan("it", fg: 14, bg: 14), ColorSpan(" ok", fg: 4),
        ])
    }
}

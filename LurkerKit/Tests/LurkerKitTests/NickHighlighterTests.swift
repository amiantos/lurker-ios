// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// In-body nick coloring, ported from the web client's `colorNicksInText`: a known nick is a
/// match only as a whole word, longest name wins, matching is case-insensitive. Self-exclusion
/// happens where the highlighter is built (the caller drops the reader's own nick), so it isn't
/// tested here.
final class NickHighlighterTests: XCTestCase {

    /// The matched substrings, in order — easier to assert on than raw NSRanges.
    private func hits(_ nicks: [String], in text: String) -> [String] {
        let ns = text as NSString
        return NickHighlighter(nicks: nicks).matches(in: text).map { ns.substring(with: $0) }
    }

    func testMatchesAWholeWordNick() {
        XCTAssertEqual(hits(["alice", "bob"], in: "hey alice and bob"), ["alice", "bob"])
    }

    func testDoesNotMatchInsideALongerWord() {
        // "bob" inside "bobby" must not match — the trailing "b" is a nick char.
        XCTAssertEqual(hits(["bob"], in: "hi bobby"), [])
    }

    func testDoesNotMatchWithATrailingNickChar() {
        // The away/alt suffix chars are nick chars, so "bob_" and "bob-" aren't a bare "bob".
        XCTAssertEqual(hits(["bob"], in: "bob_ bob- bob|"), [])
    }

    func testMatchesNextToPunctuation() {
        XCTAssertEqual(hits(["bob"], in: "hey bob! and (bob), bob."), ["bob", "bob", "bob"])
    }

    func testLongestNickWinsAtAPosition() {
        // Both could match at the same spot; the alternation must prefer the longer one.
        XCTAssertEqual(hits(["ali", "alibaba"], in: "hi alibaba"), ["alibaba"])
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(hits(["Alice"], in: "hey ALICE and alice"), ["ALICE", "alice"])
    }

    func testMatchesNicksWithSpecialChars() {
        // IRC nicks allow - _ [ ] \ ^ { | } — all inside the boundary class.
        XCTAssertEqual(hits(["[a\\b]", "{c|d}"], in: "poke [a\\b] and {c|d} now"), ["[a\\b]", "{c|d}"])
    }

    func testReturnsAccurateRanges() {
        let text = "yo bob"
        let ranges = NickHighlighter(nicks: ["bob"]).matches(in: text)
        XCTAssertEqual(ranges, [NSRange(location: 3, length: 3)])
    }

    func testEmptyNickSetMatchesNothing() {
        let highlighter = NickHighlighter(nicks: [])
        XCTAssertTrue(highlighter.isEmpty)
        XCTAssertEqual(highlighter.matches(in: "anyone home?"), [])
    }
}

/// The light-mode palette exists and lines up with the dark one, so `hashedColor` can pair
/// them by index and every nick has both variants.
final class NickPaletteTests: XCTestCase {

    func testLightPaletteParallelsDark() {
        XCTAssertEqual(IRCPalette.nickLight.count, IRCPalette.nick.count)
        XCTAssertEqual(IRCPalette.mircLight.count, IRCPalette.mirc.count)
    }

    func testMircLightKeepsTheThemeSlotsOpen() {
        // 0/1/14/15 resolve to adaptive system colors, not palette hex, in both tables.
        for slot in [0, 1, 14, 15] {
            XCTAssertNil(IRCPalette.mirc[slot])
            XCTAssertNil(IRCPalette.mircLight[slot])
        }
    }

    func testEveryLightHexParses() {
        for hex in IRCPalette.nickLight + IRCPalette.mircLight.compactMap({ $0 }) {
            XCTAssertTrue(hex.hasPrefix("#") && hex.count == 7, "malformed light hex: \(hex)")
        }
    }
}

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

    /// The four mono slots are the same colour in both tables, on purpose.
    ///
    /// These are the ones a sender pairs with a background, and re-tinting them per scheme is
    /// what broke every such pair: `^C00,01` drew the theme's near-black on black, and `^C01,00`
    /// — where slot 0 is the *background* — drew a dark box with black text in it. The type
    /// stops them being theme references at all; this stops them being re-tinted.
    func testMonoSlotsAreSchemeIndependentLiterals() {
        for (slot, hex) in [(0, "#ffffff"), (1, "#000000"), (14, "#7f7f7f"), (15, "#d2d2d2")] {
            XCTAssertEqual(IRCPalette.mirc[slot], hex, "mirc[\(slot)]")
            XCTAssertEqual(IRCPalette.mircLight[slot], hex, "mircLight[\(slot)]")
        }
    }

    func testEveryLightHexParses() {
        for hex in IRCPalette.nickLight + IRCPalette.mircLight {
            let digits = hex.dropFirst()
            XCTAssertTrue(
                hex.hasPrefix("#") && digits.count == 6 && digits.allSatisfy(\.isHexDigit),
                "malformed light hex: \(hex)"
            )
        }
    }

    /// Both palettes are copies of the web client's built-in themes, and the whole point is that
    /// they don't drift. Pinning them here means a change to either table is a change someone has
    /// to make deliberately, in two places, rather than a hex someone nudged.
    ///
    /// Source: `lurker/shared/settingsRegistry.ts` (`look.nick.colors`,
    /// `look.color.mirc_colors`) for dark, `lurker/shared/themePresets.ts` (`LIGHT_OVERRIDES`)
    /// for light.
    func testPalettesMatchTheWebPresets() {
        XCTAssertEqual(
            IRCPalette.nick,
            [
                "#ff6188", "#fc9867", "#ffd866", "#a9dc76", "#78dce8", "#ab9df2", "#ed6c89",
                "#d4996e", "#f9d978", "#b3db82", "#91dae6", "#a99dec", "#ff7494", "#ffaf75",
                "#c4e29a", "#a0f1ff", "#b6aaff", "#7ba4ff", "#6799f3",
            ]
        )
        XCTAssertEqual(
            IRCPalette.nickLight,
            [
                "#e14775", "#e16032", "#cc7a0a", "#269d69", "#1c8ca8", "#7058be", "#b52d55",
                "#9a5f30", "#a68500", "#688f2d", "#3d8f9b", "#7061b1", "#c12d5b", "#b66621",
                "#759247", "#409ba9", "#7767bd", "#4268c5", "#3163c0",
            ]
        )
        XCTAssertEqual(
            IRCPalette.mirc,
            [
                "#ffffff", "#000000", "#6799f3", "#a9dc76", "#ff6188", "#ed6c89", "#ab9df2", "#fc9867",
                "#ffd866", "#b3db82", "#78dce8", "#a0f1ff", "#7ba4ff", "#ff7494", "#7f7f7f", "#d2d2d2",
            ]
        )
        XCTAssertEqual(
            IRCPalette.mircLight,
            [
                "#ffffff", "#000000", "#3163c0", "#269d69", "#e14775", "#b52d55", "#7058be", "#e16032",
                "#cc7a0a", "#688f2d", "#1c8ca8", "#409ba9", "#4268c5", "#c12d5b", "#7f7f7f", "#d2d2d2",
            ]
        )
    }

    /// The six hues Monokai Pro Light officially defines are shared between the two light tables
    /// — a `^C04` and a nick that hash to the same slot have to be the same red. This is the
    /// pairing `mircLight` was derived from, and the half of it that drifted when the web theme
    /// adopted the official accents and iOS didn't.
    func testLightMircTracksTheLightNickPalette() {
        // The four mono slots are scheme-independent and aren't drawn from the nick palette;
        // they have their own test.
        let mono = Set([0, 1, 14, 15])
        for (slot, hex) in IRCPalette.mircLight.enumerated() where !mono.contains(slot) {
            let darkHex = IRCPalette.mirc[slot]
            guard let nickIndex = IRCPalette.nick.firstIndex(of: darkHex) else {
                XCTFail("mirc[\(slot)] = \(darkHex) is neither a mono slot nor a nick-palette hue")
                continue
            }
            XCTAssertEqual(
                hex, IRCPalette.nickLight[nickIndex],
                "mircLight[\(slot)] should be the light variant of \(darkHex)"
            )
        }
    }
}

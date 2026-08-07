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
        // 0/14/15 resolve against the palette (fg / fg-muted / 70% fg), not to a hex, in both
        // tables. Slot 1 is deliberately NOT among them — see below.
        for slot in [0, 14, 15] {
            XCTAssertNil(IRCPalette.mirc[slot])
            XCTAssertNil(IRCPalette.mircLight[slot])
        }
    }

    /// Slot 1 is "black", and the one slot whose obvious reading — "the background" — makes it
    /// disappear. Leaving it a theme slot is how it came to render as `.systemBackground`, i.e.
    /// white on white in light mode. The web registry pins it to a literal for the same reason,
    /// and this is the test that stops it drifting back.
    func testMircBlackIsALiteralInBothTables() {
        XCTAssertEqual(IRCPalette.mirc[1], "#000000")
        XCTAssertEqual(IRCPalette.mircLight[1], "#000000")
    }

    func testEveryLightHexParses() {
        for hex in IRCPalette.nickLight + IRCPalette.mircLight.compactMap({ $0 }) {
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
                nil, "#000000", "#6799f3", "#a9dc76", "#ff6188", "#ed6c89", "#ab9df2", "#fc9867",
                "#ffd866", "#b3db82", "#78dce8", "#a0f1ff", "#7ba4ff", "#ff7494", nil, nil,
            ]
        )
        XCTAssertEqual(
            IRCPalette.mircLight,
            [
                nil, "#000000", "#3163c0", "#269d69", "#e14775", "#b52d55", "#7058be", "#e16032",
                "#cc7a0a", "#688f2d", "#1c8ca8", "#409ba9", "#4268c5", "#c12d5b", nil, nil,
            ]
        )
    }

    /// The six hues Monokai Pro Light officially defines are shared between the two light tables
    /// — a `^C04` and a nick that hash to the same slot have to be the same red. This is the
    /// pairing `mircLight` was derived from, and the half of it that drifted when the web theme
    /// adopted the official accents and iOS didn't.
    func testLightMircTracksTheLightNickPalette() {
        for (slot, hex) in IRCPalette.mircLight.enumerated() {
            guard let hex, let darkHex = IRCPalette.mirc[slot] else { continue }
            guard let nickIndex = IRCPalette.nick.firstIndex(of: darkHex) else {
                // Slot 1's black isn't drawn from the nick palette; it has no light variant to
                // track and is asserted on its own above.
                XCTAssertEqual(slot, 1, "mirc[\(slot)] = \(darkHex) is not a nick-palette hue")
                continue
            }
            XCTAssertEqual(
                hex, IRCPalette.nickLight[nickIndex],
                "mircLight[\(slot)] should be the light variant of \(darkHex)"
            )
        }
    }
}

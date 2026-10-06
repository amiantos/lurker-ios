// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Ported alongside `MemberPrefix` itself, from the web client's `memberPrefix.ts`, so the
/// two clients can't drift on which glyph a mode maps to or who sorts above whom.
final class MemberPrefixTests: XCTestCase {

    private func member(_ nick: String, _ modes: [String] = [], away: Bool = false) -> Member {
        Member(nick: nick, modes: modes, away: away)
    }

    // MARK: - Glyphs

    func testEachModeMapsToItsConventionalGlyph() {
        XCTAssertEqual(MemberPrefix.of(["q"], prefix: nil), "~")
        XCTAssertEqual(MemberPrefix.of(["a"], prefix: nil), "&")
        XCTAssertEqual(MemberPrefix.of(["o"], prefix: nil), "@")
        XCTAssertEqual(MemberPrefix.of(["h"], prefix: nil), "%")
        XCTAssertEqual(MemberPrefix.of(["v"], prefix: nil), "+")
    }

    // MARK: - Your own glyph, for the composer's prompt (#135)

    func testFindingYourselfFoldsNickCase() {
        let members = [member("alice", ["o"]), member("amiantos", ["v", "o"])]
        XCTAssertEqual(members.member(named: "Amiantos")?.modes, ["v", "o"])
    }

    func testANickWhoseFoldChangesLengthIsStillFound() {
        // "İ" is two UTF-8 bytes and lowercases to three — a length check in front of the
        // fold would turn this member away, for `channelAccess` as much as the prompt.
        let members = [member("alice"), member("İzmir", ["o"])]
        XCTAssertEqual(members.member(named: "İzmir")?.modes, ["o"])
        XCTAssertEqual(members.member(named: "i̇zmir")?.modes, ["o"])
    }

    func testNobodyIsYouBeforeNamesOrWithoutANick() {
        // Another member's glyph would be a lie about you.
        XCTAssertNil([member("alice", ["o"])].member(named: "amiantos"))
        XCTAssertNil([member("", ["o"])].member(named: ""))
    }

    func testNoModesMeansNoGlyph() {
        XCTAssertEqual(MemberPrefix.of([], prefix: nil), "")
    }

    func testAnUnknownModeIsNotAGlyph() {
        // Channel modes that aren't prefix modes must not leak into the nick column.
        XCTAssertEqual(MemberPrefix.of(["z"], prefix: nil), "")
    }

    func testTheHighestHeldModeWins() {
        // A member holding several shows one glyph, the top one — not a pile.
        XCTAssertEqual(MemberPrefix.of(["v", "o"], prefix: nil), "@")
        XCTAssertEqual(MemberPrefix.of(["v", "o", "q"], prefix: nil), "~")
        XCTAssertEqual(MemberPrefix.of(["h", "v"], prefix: nil), "%")
    }

    // MARK: - Sorting

    func testRankOutranksAlphabetical() {
        let sorted = MemberPrefix.sorted([
            member("zoe", ["v"]),
            member("adam"),
            member("mallory", ["o"]),
            member("bob", ["q"]),
        ], prefix: nil)
        XCTAssertEqual(sorted.map(\.nick), ["bob", "mallory", "zoe", "adam"])
    }

    func testEqualRankSortsByNick() {
        let sorted = MemberPrefix.sorted([member("carol", ["o"]), member("alice", ["o"])], prefix: nil)
        XCTAssertEqual(sorted.map(\.nick), ["alice", "carol"])
    }

    func testNickSortIgnoresCase() {
        // A raw `<` would put every capitalized nick above every lowercase one, which reads
        // as two alphabets stacked rather than one list.
        let sorted = MemberPrefix.sorted([member("bob"), member("Alice"), member("carol")], prefix: nil)
        XCTAssertEqual(sorted.map(\.nick), ["Alice", "bob", "carol"])
    }

    func testAwayMembersHoldTheirPlace() {
        // You look for a nick where you last saw it; away is a dimming, not a re-sort.
        let sorted = MemberPrefix.sorted([member("bob"), member("alice", away: true)], prefix: nil)
        XCTAssertEqual(sorted.map(\.nick), ["alice", "bob"])
    }

    func testUnprivilegedMembersSortLast() {
        XCTAssertEqual(MemberPrefix.order(["q"], prefix: nil), 0)
        XCTAssertGreaterThan(MemberPrefix.order([], prefix: nil), MemberPrefix.order(["v"], prefix: nil))
    }

    // MARK: - The network's own PREFIX (lurker-ios#191)

    func testTheGlyphIsTheNetworksSymbolForTheTopLetterHeld() {
        // A network whose op is `!` and whose halfop doesn't exist.
        let prefix = [PrefixMode(mode: "o", symbol: "!"), PrefixMode(mode: "v", symbol: "+")]
        XCTAssertEqual(MemberPrefix.of(["o", "v"], prefix: prefix), "!")
        XCTAssertEqual(MemberPrefix.of(["h"], prefix: prefix), "", "a letter the network doesn't have")
        XCTAssertEqual(MemberPrefix.of(["v"], prefix: []), "", "a network with no prefix modes at all")
    }

    func testTheOrderFollowsTheNetworksRanks() {
        // Voice above op, on a network that says so: the sort follows it.
        let prefix = [PrefixMode(mode: "v", symbol: "+"), PrefixMode(mode: "o", symbol: "@")]
        let members = [Member(nick: "op", modes: ["o"]), Member(nick: "voice", modes: ["v"]), Member(nick: "none", modes: [])]
        XCTAssertEqual(MemberPrefix.sorted(members, prefix: prefix).map(\.nick), ["voice", "op", "none"])
        XCTAssertEqual(MemberPrefix.order([], prefix: prefix), 2, "no prefix mode sorts after every rank")
    }

    /// Coloured by the letter's role, not by symbol and not by position: on Libera's `(ov)@+` op is
    /// the top rank and must not take the owner colour; another symbol for op is still op; an
    /// unknown letter takes the nearest known letter above it, or owner.
    func testTheTierIsTheLettersRole() {
        let libera = [PrefixMode(mode: "o", symbol: "@"), PrefixMode(mode: "v", symbol: "+")]
        XCTAssertEqual(MemberPrefix.mark(["o"], prefix: libera), .init(glyph: "@", tier: .op))
        XCTAssertEqual(MemberPrefix.mark(["o"], prefix: [PrefixMode(mode: "o", symbol: "!")])?.tier, .op)
        let wide = [PrefixMode(mode: "Y", symbol: "!")] + MemberPrefix.conventional
        XCTAssertEqual(MemberPrefix.mark(["Y"], prefix: wide), .init(glyph: "!", tier: .owner))
        let between = [PrefixMode(mode: "o", symbol: "@"), PrefixMode(mode: "X", symbol: "*"), PrefixMode(mode: "v", symbol: "+")]
        XCTAssertEqual(MemberPrefix.mark(["X"], prefix: between)?.tier, .op, "the nearest known letter above")
        XCTAssertNil(MemberPrefix.mark([], prefix: libera))
    }

    func testBeforeISUPPORTTheConventionalTableStands() {
        XCTAssertEqual(MemberPrefix.mark(["h"], prefix: nil), .init(glyph: "%", tier: .halfop))
        XCTAssertEqual(MemberPrefix.mark(["q", "v"], prefix: nil), .init(glyph: "~", tier: .owner))
    }
}

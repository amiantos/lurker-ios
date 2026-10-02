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
        XCTAssertEqual(MemberPrefix.of(["q"]), "~")
        XCTAssertEqual(MemberPrefix.of(["a"]), "&")
        XCTAssertEqual(MemberPrefix.of(["o"]), "@")
        XCTAssertEqual(MemberPrefix.of(["h"]), "%")
        XCTAssertEqual(MemberPrefix.of(["v"]), "+")
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
        XCTAssertEqual(MemberPrefix.of([]), "")
    }

    func testAnUnknownModeIsNotAGlyph() {
        // Channel modes that aren't prefix modes must not leak into the nick column.
        XCTAssertEqual(MemberPrefix.of(["z"]), "")
    }

    func testTheHighestHeldModeWins() {
        // A member holding several shows one glyph, the top one — not a pile.
        XCTAssertEqual(MemberPrefix.of(["v", "o"]), "@")
        XCTAssertEqual(MemberPrefix.of(["v", "o", "q"]), "~")
        XCTAssertEqual(MemberPrefix.of(["h", "v"]), "%")
    }

    // MARK: - Sorting

    func testRankOutranksAlphabetical() {
        let sorted = MemberPrefix.sorted([
            member("zoe", ["v"]),
            member("adam"),
            member("mallory", ["o"]),
            member("bob", ["q"]),
        ])
        XCTAssertEqual(sorted.map(\.nick), ["bob", "mallory", "zoe", "adam"])
    }

    func testEqualRankSortsByNick() {
        let sorted = MemberPrefix.sorted([member("carol", ["o"]), member("alice", ["o"])])
        XCTAssertEqual(sorted.map(\.nick), ["alice", "carol"])
    }

    func testNickSortIgnoresCase() {
        // A raw `<` would put every capitalized nick above every lowercase one, which reads
        // as two alphabets stacked rather than one list.
        let sorted = MemberPrefix.sorted([member("bob"), member("Alice"), member("carol")])
        XCTAssertEqual(sorted.map(\.nick), ["Alice", "bob", "carol"])
    }

    func testAwayMembersHoldTheirPlace() {
        // You look for a nick where you last saw it; away is a dimming, not a re-sort.
        let sorted = MemberPrefix.sorted([member("bob"), member("alice", away: true)])
        XCTAssertEqual(sorted.map(\.nick), ["alice", "bob"])
    }

    func testUnprivilegedMembersSortLast() {
        XCTAssertEqual(MemberPrefix.order(["q"]), 0)
        XCTAssertGreaterThan(MemberPrefix.order([]), MemberPrefix.order(["v"]))
    }
}

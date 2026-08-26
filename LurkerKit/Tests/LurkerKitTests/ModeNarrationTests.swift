// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Mode-line narration — ported from the web's `shared/modeNarration.test.ts`, case for case,
/// so the two clients say the same thing about the same row.
final class ModeNarrationTests: XCTestCase {

    /// The narration as a plain string, for readable assertions.
    private func say(_ modes: [ModeChange], rawText: String? = nil) -> String {
        ModeNarration.describe(modes, rawText: rawText).map { segment in
            switch segment {
            case .text(let t), .arg(let t): t
            case .nick(let n): n
            }
        }.joined()
    }

    private func prefix(_ mode: String, _ param: String) -> ModeChange {
        ModeChange(mode: mode, param: param, kind: .prefix)
    }
    private func list(_ mode: String, _ param: String) -> ModeChange {
        ModeChange(mode: mode, param: param, kind: .list)
    }
    private func chan(_ mode: String, _ param: String? = nil) -> ModeChange {
        ModeChange(mode: mode, param: param, kind: .chan)
    }

    // MARK: - Member status

    func testNarratesGrantsAndRevocations() {
        XCTAssertEqual(say([prefix("+o", "alice")]), " gave op to alice")
        XCTAssertEqual(say([prefix("-o", "alice")]), " took op from alice")
        XCTAssertEqual(say([prefix("+v", "carol")]), " gave voice to carol")
        XCTAssertEqual(say([prefix("-v", "carol")]), " took voice from carol")
        XCTAssertEqual(say([prefix("+h", "dave")]), " gave half-op to dave")
        XCTAssertEqual(say([prefix("+q", "erin")]), " gave owner to erin")
        XCTAssertEqual(say([prefix("+a", "frank")]), " gave admin to frank")
    }

    func testEmitsTheTargetAsANickSegment() {
        XCTAssertEqual(
            ModeNarration.describe([prefix("+o", "alice")]),
            [.text(" gave op to "), .nick("alice")]
        )
    }

    func testFallsBackToTheTokenForAnUnnamedPrefixLetter() {
        XCTAssertEqual(say([prefix("+y", "gwen")]), " gave +y to gwen")
        XCTAssertEqual(say([prefix("-y", "gwen")]), " took +y from gwen")
    }

    // MARK: - List modes

    func testNarratesBansQuietsAndExceptions() {
        XCTAssertEqual(say([list("+b", "*!*@host")]), " banned *!*@host")
        XCTAssertEqual(say([list("-b", "*!*@host")]), " unbanned *!*@host")
        XCTAssertEqual(say([list("+q", "*!*@host")]), " quieted *!*@host")
        XCTAssertEqual(say([list("+e", "*!*@host")]), " added a ban exemption for *!*@host")
        XCTAssertEqual(say([list("-I", "*!*@host")]), " removed the invite exception for *!*@host")
    }

    func testNamesTheListForAnUnknownLetter() {
        XCTAssertEqual(say([list("+d", "mask")]), " added mask to the +d list")
        XCTAssertEqual(say([list("-d", "mask")]), " removed mask from the +d list")
    }

    func testNeverEmitsAMaskAsANick() {
        // `+b alice` is a mask that happens to look like a nick. Rendering it as one would
        // give it a colour, a nick menu, and a whois — for a ban.
        let segments = ModeNarration.describe([list("+b", "alice")])
        XCTAssertFalse(segments.contains { if case .nick = $0 { true } else { false } })
    }

    // MARK: - Channel modes

    func testNarratesTheCommonFlags() {
        XCTAssertEqual(say([chan("+t")]), " locked the topic")
        XCTAssertEqual(say([chan("-t")]), " unlocked the topic")
        XCTAssertEqual(say([chan("+m")]), " made the channel moderated")
        XCTAssertEqual(say([chan("-m")]), " removed moderation")
        XCTAssertEqual(say([chan("+i")]), " made the channel invite-only")
        XCTAssertEqual(say([chan("+s")]), " made the channel secret")
        XCTAssertEqual(say([chan("+p")]), " made the channel private")
    }

    func testGetsPlusNTheRightWayRound() {
        // +n BLOCKS messages from outside the channel. gamja narrates it as "allowed external
        // messages", which is inverted; this pins ours.
        XCTAssertEqual(say([chan("+n")]), " blocked outside messages")
        XCTAssertEqual(say([chan("-n")]), " allowed outside messages")
    }

    func testNarratesTheUserLimitWithItsValue() {
        XCTAssertEqual(say([chan("+l", "50")]), " set the user limit to 50")
        XCTAssertEqual(say([chan("-l")]), " removed the user limit")
    }

    func testNeverPrintsTheChannelKey() {
        XCTAssertEqual(say([chan("+k", "hunter2")]), " set a channel key")
        XCTAssertFalse(say([chan("+k", "hunter2")]).contains("hunter2"))
        XCTAssertEqual(say([chan("-k", "hunter2")]), " removed the channel key")
    }

    func testFallsBackToTheTokenForAnUnknownChannelLetter() {
        XCTAssertEqual(say([chan("+C")]), " set +C")
        XCTAssertEqual(say([chan("-C")]), " unset +C")
        XCTAssertEqual(say([chan("+j", "5:1")]), " set +j to 5:1")
    }

    // MARK: - Fallbacks

    func testShowsAModeStringForSeveralChanges() {
        XCTAssertEqual(
            say([prefix("+o", "alice"), list("-b", "*!*@host")]),
            " set +o alice -b *!*@host"
        )
    }

    func testWithholdsTheKeyInTheMultiChangeFormToo() {
        let said = say([chan("+k", "hunter2"), chan("+m")])
        XCTAssertEqual(said, " set +k +m")
        XCTAssertFalse(said.contains("hunter2"))
    }

    func testDoesNotNarrateAnUnstampedChange() {
        // Without `kind`, `+q alice` might grant ownership or quiet a mask. Guessing is the
        // bug the stamp exists to prevent.
        XCTAssertEqual(say([ModeChange(mode: "+q", param: "alice")]), " set +q alice")
        XCTAssertEqual(say([ModeChange(mode: "+o", param: "alice")]), " set +o alice")
    }

    func testUsesTheRowTextWhenThereIsNoParsedList() {
        XCTAssertEqual(say([], rawText: "+o alice"), " set +o alice")
        XCTAssertEqual(say([], rawText: "+nt"), " set +nt")
    }

    func testWithholdsTheKeyFromTheRawTextPathToo() {
        // Reachable, not theoretical: rows written before `modes` was persisted take this
        // path, and their text is the wire form.
        XCTAssertEqual(say([], rawText: "+k hunter2"), " set +k")
        XCTAssertEqual(say([], rawText: "+ok alice hunter2"), " set +ok")
        XCTAssertFalse(say([], rawText: "+k hunter2").contains("hunter2"))
    }

    func testLeavesAKeylessRawTextIntact() {
        XCTAssertEqual(say([], rawText: "+b *!*@host"), " set +b *!*@host")
        XCTAssertEqual(say([], rawText: "+l 50"), " set +l 50")
    }

    func testStillSaysSomethingWhenTheRowHasNothingUsable() {
        XCTAssertEqual(say([], rawText: ""), " changed the channel modes")
        XCTAssertEqual(say([], rawText: nil), " changed the channel modes")
    }

    func testIgnoresMalformedEntries() {
        XCTAssertEqual(
            say([ModeChange(mode: "", param: "x"), prefix("+o", "alice")]),
            " gave op to alice"
        )
    }
}

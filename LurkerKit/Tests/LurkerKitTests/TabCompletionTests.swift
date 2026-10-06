// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// In-place Tab completion (lurker-android#63), pinned against the web composer's Tab handler.
final class TabCompletionTests: XCTestCase {
    private let roster = ["alice", "alfred", "bob"]

    private func nicks(_ query: String) -> [String] {
        roster.filter { $0.lowercased().hasPrefix(query.lowercased()) }
    }

    private func begin(_ text: String, caret: Int? = nil, channels: [String] = [], punctuation: String = ":") -> TabCompletion? {
        TabCompletion.begin(
            text: text, caret: caret ?? text.utf16.count, nicks: nicks, channels: { channels }, punctuation: punctuation)
    }

    func testANickOpeningTheLineIsAddressed() {
        let edit = begin("al")?.edit
        XCTAssertEqual(edit?.text, "alice: ")
        XCTAssertEqual(edit?.caret, 7)
    }

    func testANickMidSentenceTakesNothing() {
        let edit = begin("thanks al")?.edit
        XCTAssertEqual(edit?.text, "thanks alice")
        XCTAssertEqual(edit?.caret, 12)
    }

    func testTheSuffixFollowsTheSetting() {
        XCTAssertEqual(begin("al", punctuation: ",")?.edit.text, "alice, ")
        // "Space only" is the empty punctuation.
        XCTAssertEqual(begin("al", punctuation: "")?.edit.text, "alice ")
    }

    func testALineStartAfterANewlineCounts() {
        XCTAssertEqual(begin("hi all\n  al")?.edit.text, "hi all\n  alice: ")
    }

    func testAnAtIsDroppedFromTheMatchAndTheInsertion() {
        XCTAssertEqual(begin("hey @al")?.edit.text, "hey alice")
        XCTAssertNil(begin("@"))
    }

    func testTheWholeWordIsReplacedNotJustUpToTheCaret() {
        // al|xyz: the token runs past the caret, so its tail goes too.
        let edit = begin("alxyz tail", caret: 2)?.edit
        XCTAssertNil(edit, "the word is alxyz, and nobody's nick starts that way")
        XCTAssertEqual(begin("al", caret: 1)?.edit.text, "alice: ")
    }

    func testTabCyclesAndShiftTabGoesBack() {
        var completion = begin("al")!
        XCTAssertEqual(completion.edit.text, "alice: ")
        XCTAssertEqual(completion.cycle(backward: false).text, "alfred: ")
        XCTAssertEqual(completion.cycle(backward: false).text, "alice: ")
        XCTAssertEqual(completion.cycle(backward: true).text, "alfred: ")
    }

    func testACompletionContinuesOnlyWhereItLeftTheCaret() {
        let completion = begin("hi al")!
        let edit = completion.edit
        XCTAssertTrue(completion.continues(text: edit.text, caret: edit.caret))
        XCTAssertFalse(completion.continues(text: edit.text, caret: 0))
        XCTAssertFalse(completion.continues(text: edit.text + "x", caret: edit.caret + 1))
    }

    func testTheTextAfterTheWordStays() {
        let edit = begin("al is here", caret: 2)?.edit
        XCTAssertEqual(edit?.text, "alice:  is here")
        XCTAssertEqual(edit?.caret, 7)
    }

    func testAHashCompletesAChannelInTheOrderGiven() {
        let channels = ["#lurker", "#linux", "#Lounge", "&local"]
        var completion = begin("join #l", channels: channels)!
        XCTAssertEqual(completion.edit.text, "join #lurker")
        XCTAssertEqual(completion.cycle(backward: false).text, "join #linux")
        // Case-insensitive, and never a suffix — even opening the line.
        XCTAssertEqual(completion.cycle(backward: false).text, "join #Lounge")
        XCTAssertEqual(begin("#lu", channels: channels)?.edit.text, "#lurker")
    }

    func testOnlyAHashCompletesChannels() {
        // `&lo` is prose as far as completion goes: it asks for nicks, and none start that way.
        XCTAssertNil(begin("&lo", channels: ["&local"]))
    }

    func testNothingUnderTheCaretOrNoMatchIsNil() {
        XCTAssertNil(begin(""))
        XCTAssertNil(begin("hi ", caret: 3))
        XCTAssertNil(begin("zz"))
        XCTAssertNil(begin("#zz", channels: ["#lurker"]))
    }

    /// Most Tabs complete a nick; the network's channels are only worth gathering for a `#`.
    func testChannelsAreAskedOnlyForAHash() {
        var asked = 0
        let channels = { () -> [String] in asked += 1; return ["#lurker"] }
        _ = TabCompletion.begin(text: "al", caret: 2, nicks: nicks, channels: channels, punctuation: ":")
        XCTAssertEqual(asked, 0)
        _ = TabCompletion.begin(text: "#lu", caret: 3, nicks: nicks, channels: channels, punctuation: ":")
        XCTAssertEqual(asked, 1)
    }

    func testOffsetsAreUTF16() {
        // An astral emoji before the word is two UTF-16 units.
        let edit = begin("😀 al")?.edit
        XCTAssertEqual(edit?.text, "😀 alice")
        XCTAssertEqual(edit?.caret, "😀 alice".utf16.count)
    }
}

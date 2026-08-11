// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// The per-buffer "who has spoken here lately" map (#63).
///
/// Pinned because every way it can be wrong is quiet: an entry that never lands, or lands under
/// the wrong casing, or gets walked backwards by a replay, shows up as a join/part line the
/// reader simply never sees — indistinguishable from the filter working.
final class SpeakersTests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_784_548_800)

    private static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Nicks fold case, like every other nick lookup in this client — servers echo whatever
    /// casing they feel like, and an event's nick rarely matches the seed's letter for letter.
    func testLookupFoldsCase() {
        let map = SpeakerMap([Speaker(nick: "AliCe", lastSpoke: Self.t0)])
        XCTAssertEqual(map["alice"], Self.t0)
        XCTAssertEqual(map["ALICE"], Self.t0)
        XCTAssertEqual(map.nicks, ["alice"])
    }

    func testAnEmptyMapKnowsNobody() {
        XCTAssertTrue(SpeakerMap().isEmpty)
        XCTAssertNil(SpeakerMap()["alice"])
    }

    /// Only forward. A backlog replay, or a server list computed before the last live message,
    /// must not make a current speaker look stale.
    func testRecordingOnlyMovesTimeForward() {
        var map = SpeakerMap()
        map.record(nick: "alice", at: Self.at(10))
        map.record(nick: "alice", at: Self.at(1))
        XCTAssertEqual(map["alice"], Self.at(10))
        map.record(nick: "alice", at: Self.at(20))
        XCTAssertEqual(map["alice"], Self.at(20))
    }

    func testAnEmptyNickIsNotAnEntry() {
        var map = SpeakerMap()
        map.record(nick: "", at: Self.t0)
        XCTAssertTrue(map.isEmpty)
    }

    func testRenameCarriesTheEntry() {
        var map = SpeakerMap([Speaker(nick: "alice", lastSpoke: Self.t0)])
        map.rename(from: "Alice", to: "alice_afk")
        XCTAssertEqual(map.nicks, ["alice_afk"])
        XCTAssertEqual(map["alice_afk"], Self.t0)
    }

    /// A rename onto a nick that already spoke keeps the later of the two: somebody reclaiming
    /// a nick they used earlier shouldn't have their recency rolled back to the old entry.
    func testRenameOntoAKnownNickKeepsTheNewerTime() {
        var map = SpeakerMap([
            Speaker(nick: "alice", lastSpoke: Self.at(0)),
            Speaker(nick: "alice_afk", lastSpoke: Self.at(10)),
        ])
        map.rename(from: "alice", to: "alice_afk")
        XCTAssertEqual(map["alice_afk"], Self.at(10))
        XCTAssertNil(map["alice"])
    }

    func testRenamingAnUnknownNickIsANoOp() {
        var map = SpeakerMap([Speaker(nick: "alice", lastSpoke: Self.t0)])
        map.rename(from: "bob", to: "bob_")
        XCTAssertEqual(map.nicks, ["alice"])
    }

    /// The map only ever grows from live traffic, so a channel left open for a day would
    /// otherwise accumulate every nick that ever said anything. Past the cap the least-recent
    /// speaker goes — the one whose absence the filter is least likely to notice.
    func testPastTheCapTheLeastRecentSpeakerIsEvicted() {
        var map = SpeakerMap()
        map.record(nick: "ancient", at: Self.at(-1))
        for index in 0..<SpeakerMap.cap {
            map.record(nick: "user\(index)", at: Self.at(Double(index)))
        }
        XCTAssertEqual(map.nicks.count, SpeakerMap.cap)
        XCTAssertNil(map["ancient"], "the oldest entry is the one that goes")
        XCTAssertNotNil(map["user0"])
    }

    /// Well clear of the server's own list of 20, so a seed can never immediately evict itself.
    func testTheCapLeavesRoomForAFullServerSeed() {
        XCTAssertGreaterThan(SpeakerMap.cap, 20)
    }
}

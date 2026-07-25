// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import LurkerKit

/// Join consolidation — the net-effect collapse ported from the web client's
/// `shared/consolidate.ts`, over the same event set.
///
/// The classification is load-bearing and easy to get subtly wrong (a join-then-part must
/// read "joined briefly", not "joined"), so the state machine is pinned here rather than
/// left to be eyeballed in the running app.
final class ConsolidationTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func msg(
        _ type: EventType,
        _ nick: String? = nil,
        newNick: String? = nil,
        modes: [ModeChange] = [],
        at offset: TimeInterval = 0
    ) -> Message {
        Message(
            id: Int(offset) + 1, type: type, nick: nick, text: nil,
            date: base.addingTimeInterval(offset), newNick: newNick, modes: modes
        )
    }

    /// The one summary in a row stream (fails the test if there isn't exactly one).
    private func onlySummary(_ rows: [Consolidation.Row]) -> ConsolidationSummary? {
        let summaries = rows.compactMap { row -> ConsolidationSummary? in
            if case .summary(let summary) = row { return summary }
            return nil
        }
        XCTAssertEqual(summaries.count, 1, "expected exactly one consolidated summary")
        return summaries.first
    }

    private func group(
        _ summary: ConsolidationSummary?, _ kind: ConsolidationSummary.IdentityGroup.Kind
    ) -> ConsolidationSummary.IdentityGroup? {
        summary?.groups.first { $0.kind == kind }
    }

    private func nicks(_ group: ConsolidationSummary.IdentityGroup?) -> [String] {
        (group?.visible ?? []).map { entry in
            switch entry {
            case .nick(let nick): nick
            case .renamed(_, let to): to
            }
        }
    }

    // MARK: - Run detection

    func testALoneJoinPassesThroughUnconsolidated() {
        let rows = Consolidation.consolidate([msg(.join, "alice")])
        XCTAssertEqual(rows.count, 1)
        guard case .passthrough = rows[0] else { return XCTFail("a single event must not consolidate") }
    }

    func testTwoJoinsConsolidate() {
        let summary = onlySummary(Consolidation.consolidate([msg(.join, "alice"), msg(.join, "bob", at: 1)]))
        XCTAssertEqual(nicks(group(summary, .joined)), ["alice", "bob"])
    }

    func testARealMessageBreaksTheRun() {
        // join, chat, join → three lone events, nothing to collapse.
        let rows = Consolidation.consolidate([
            msg(.join, "alice"), msg(.message, "alice", at: 1), msg(.join, "bob", at: 2),
        ])
        XCTAssertFalse(rows.contains { if case .summary = $0 { return true } else { return false } })
    }

    func testKickBreaksTheRun() {
        // kick is an activity line but not consolidatable — it's a discrete event that
        // terminates the run rather than folding in.
        let rows = Consolidation.consolidate([
            msg(.join, "alice"), msg(.kick, "op"), msg(.join, "bob", at: 2),
        ])
        XCTAssertFalse(rows.contains { if case .summary = $0 { return true } else { return false } })
    }

    // MARK: - Net effect classification

    func testJoinThenPartReadsAsJoinedBriefly() {
        let summary = onlySummary(Consolidation.consolidate([msg(.join, "alice"), msg(.part, "alice", at: 1)]))
        XCTAssertEqual(nicks(group(summary, .joinedAndLeft)), ["alice"])
        XCTAssertNil(group(summary, .joined))
    }

    func testPartThenJoinReadsAsReconnected() {
        let summary = onlySummary(Consolidation.consolidate([msg(.part, "alice"), msg(.join, "alice", at: 1)]))
        XCTAssertEqual(nicks(group(summary, .reconnected)), ["alice"])
    }

    func testTwoPartsReadAsLeft() {
        let summary = onlySummary(Consolidation.consolidate([msg(.quit, "alice"), msg(.part, "bob", at: 1)]))
        XCTAssertEqual(nicks(group(summary, .left)), ["alice", "bob"])
    }

    // MARK: - Renames

    func testPureRenamesReadAsRenamed() {
        let summary = onlySummary(Consolidation.consolidate([
            msg(.nick, "alice", newNick: "alice_afk"),
            msg(.nick, "bob", newNick: "bob_afk", at: 1),
        ]))
        let renamed = group(summary, .renamed)
        XCTAssertEqual(renamed?.visible.count, 2)
        // The identity carries both ends of the rename.
        guard case .renamed(let from, let to) = renamed?.visible.first else { return XCTFail("expected a rename entry") }
        XCTAssertEqual(from, "alice")
        XCTAssertEqual(to, "alice_afk")
    }

    func testARenameFollowsTheIdentityThroughAJoin() {
        // alice joins, then renames to alice2 → one identity, present under its final name.
        let summary = onlySummary(Consolidation.consolidate([
            msg(.join, "alice"), msg(.nick, "alice", newNick: "alice2", at: 1),
        ]))
        XCTAssertEqual(nicks(group(summary, .joined)), ["alice2"])
        XCTAssertNil(group(summary, .renamed))
    }

    // MARK: - Capping

    func testOverflowCollapsesToAndNOthers() {
        let joins = (0..<7).map { msg(.join, "user\($0)", at: TimeInterval($0)) }
        let summary = onlySummary(Consolidation.consolidate(joins, maxNames: 5))
        let joined = group(summary, .joined)
        XCTAssertEqual(joined?.visible.count, 5)
        XCTAssertEqual(joined?.hidden, 2)
    }

    // MARK: - Mode is not consolidatable

    func testModeBreaksTheRun() {
        // The netsplit-auto-op shape: join, +o, join. Being opped is consequential in a way
        // join churn isn't, so the mode stands on its own line and splits the run rather
        // than folding in — matching the web's CONSOLIDATABLE_TYPES.
        let rows = Consolidation.consolidate([
            msg(.join, "alice"),
            msg(.mode, "chan", modes: [ModeChange(mode: "+o", param: "alice")], at: 1),
            msg(.join, "bob", at: 2),
        ])
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(rows.contains { if case .summary = $0 { return true } else { return false } })
    }

    func testTwoModesDoNotConsolidate() {
        let rows = Consolidation.consolidate([
            msg(.mode, "chan", modes: [ModeChange(mode: "+o", param: "alice")]),
            msg(.mode, "chan", modes: [ModeChange(mode: "+o", param: "bob")], at: 1),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.contains { if case .summary = $0 { return true } else { return false } })
    }

    // MARK: - chghost

    func testTwoChghostsReadAsRehosted() {
        let summary = onlySummary(Consolidation.consolidate([
            msg(.chghost, "alice"), msg(.chghost, "bob", at: 1),
        ]))
        XCTAssertEqual(nicks(group(summary, .rehosted)), ["alice", "bob"])
    }

    func testChghostIsTransparentToAJoin() {
        // Post-netsplit each rejoining user emits JOIN then CHGHOST as they identify to
        // services. That must read as a plain "joined" — not "alice joined; alice changed
        // host", which would say the same churn twice (web #593).
        let summary = onlySummary(Consolidation.consolidate([
            msg(.join, "alice"), msg(.chghost, "alice", at: 1),
        ]))
        XCTAssertEqual(nicks(group(summary, .joined)), ["alice"])
        XCTAssertNil(group(summary, .rehosted))
    }

    func testARenameOutranksARehost() {
        // No presence change, so it comes down to which says more: "alice → alice2" does.
        let summary = onlySummary(Consolidation.consolidate([
            msg(.chghost, "alice"), msg(.nick, "alice", newNick: "alice2", at: 1),
        ]))
        XCTAssertEqual(nicks(group(summary, .renamed)), ["alice2"])
        XCTAssertNil(group(summary, .rehosted))
    }

    func testChghostJoinsARunWithJoinsAndParts() {
        let summary = onlySummary(Consolidation.consolidate([
            msg(.join, "alice"), msg(.chghost, "bob", at: 1), msg(.quit, "carol", at: 2),
        ]))
        XCTAssertEqual(nicks(group(summary, .joined)), ["alice"])
        XCTAssertEqual(nicks(group(summary, .rehosted)), ["bob"])
        XCTAssertEqual(nicks(group(summary, .left)), ["carol"])
    }

    // MARK: - Summary metadata

    func testSummaryTimestampIsTheLastEvent() {
        let summary = onlySummary(Consolidation.consolidate([
            msg(.join, "alice", at: 0), msg(.join, "bob", at: 30),
        ]))
        XCTAssertEqual(summary?.date, base.addingTimeInterval(30))
    }

    func testSummarySpansItsEventIds() {
        // The id span is what lets the scroll anchor re-find a line after a history page
        // merges it into a summary. `msg` stamps id = offset + 1, so this run spans 1…31.
        let summary = onlySummary(Consolidation.consolidate([
            msg(.join, "alice", at: 0), msg(.join, "bob", at: 30),
        ]))
        XCTAssertEqual(summary?.firstId, 1)
        XCTAssertEqual(summary?.lastId, 31)
    }
}

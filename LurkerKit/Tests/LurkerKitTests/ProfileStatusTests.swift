// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The profile's four "is this person there" answers (#12).
///
/// Ported from the web's `UserProfileModal.test.ts` rather than invented. lurker#818 was a
/// blank profile caused by answering two of these with one predicate, and it took two fixes to
/// settle because the naive correction over-reached in the opposite direction — so the cases
/// that fail in opposite directions are both here, and marked.
final class ProfileStatusTests: XCTestCase {

    private func resolve(
        peer: FriendPresence = .unknown,
        whois: WhoisResult? = nil,
        isLookingUp: Bool = false,
        isSelf: Bool = false
    ) -> ProfileStatus {
        ProfileStatus.resolve(peer: peer, whois: whois, isLookingUp: isLookingUp, isSelf: isSelf)
    }

    private let identity = WhoisResult(nick: "alice", ident: "~alice", hostname: "example.org")
    private let miss = WhoisResult(nick: "ghost", error: "not_found")

    // MARK: - The dot

    func testMonitorWinsWhereItHasAnOpinion() {
        XCTAssertEqual(resolve(peer: .online).presence, .online)
        XCTAssertEqual(resolve(peer: .away).presence, .away)
        XCTAssertEqual(resolve(peer: .offline).presence, .offline)
    }

    func testWithNoMonitorDataTheReplySettlesTheDot() {
        // The no-MONITOR case is the common one — most networks don't give us presence at all.
        XCTAssertEqual(resolve(peer: .unknown, whois: identity).presence, .online)
        XCTAssertEqual(resolve(peer: .unknown).presence, .unknown)
    }

    func testANickNobodyIsUsingReadsOfflineNotUnknown() {
        // ⚠⚠ "Unknown" is the one status a not-found lets us rule out. Rendering it there is
        // half of what made #818 look like a profile we simply had no details for.
        XCTAssertEqual(resolve(peer: .unknown, whois: miss).presence, .offline)
    }

    func testAnAwayReasonInTheReplyShowsAwayEvenWithoutMonitor() {
        let away = WhoisResult(nick: "alice", hostname: "example.org", away: "back later")
        XCTAssertEqual(resolve(peer: .unknown, whois: away).presence, .away)
        XCTAssertEqual(resolve(peer: .unknown, whois: away).awayMessage, "back later")
    }

    func testBeingAwayWithNoReasonIsStillBeingAway() {
        // ⚠ Deliberately NOT the web's `awayLabel`, which returns nothing when away is active
        // with no reason — an indicator that vanishes for the most common spelling of `/away`
        // is worse than none. The dot stands on its own; only the reason is absent.
        let status = resolve(peer: .away)
        XCTAssertEqual(status.presence, .away)
        XCTAssertNil(status.awayMessage)
    }

    // MARK: - The status line

    func testAnAnsweredMissSaysSo() {
        XCTAssertEqual(resolve(peer: .unknown, whois: miss).statusLine, .notFound)
    }

    func testACachedMissIsDemotedToWaitingWhileARefreshIsOut() {
        // ⚠⚠ A cached miss is stale the instant a refresh goes out. Without this, reopening a
        // profile seconds after that nick connected asserts they aren't on the network for a
        // whole round trip.
        XCTAssertEqual(resolve(peer: .unknown, whois: miss, isLookingUp: true).statusLine, .waiting)
    }

    func testHavingDetailsMeansTheLineHasNothingToAdd() {
        XCTAssertNil(resolve(peer: .unknown, whois: identity).statusLine)
        XCTAssertNil(resolve(peer: .online, whois: identity, isLookingUp: true).statusLine)
    }

    func testKnowingNothingYetSaysWaiting() {
        XCTAssertEqual(resolve(peer: .unknown).statusLine, .waiting)
        XCTAssertEqual(resolve(peer: .online).statusLine, .waiting)
    }

    func testAPeerMonitorCallsOfflineGetsNoSpinner() {
        // The dot already carries it; a spinner under it would claim we're unsure when we
        // aren't. This is the branch that must read MONITOR's verdict specifically.
        XCTAssertNil(resolve(peer: .offline).statusLine)
    }

    // MARK: - The two directions #818 failed in

    func testAMissBeingRecheckedDoesNotGoDownTheQuietPath() {
        // ⚠⚠ DIRECTION 1 — the original bug. If the last branch folded a not-found in with
        // MONITOR's verdict, a miss we are re-checking would return nil here and the body would
        // render nothing at all: no details, no explanation. It must say `waiting`.
        XCTAssertEqual(
            resolve(peer: .unknown, whois: miss, isLookingUp: true).statusLine,
            .waiting
        )
    }

    func testAMonitorOfflinePeerIsNotToldToWaitJustBecauseALookupIsOut() {
        // ⚠⚠ DIRECTION 2 — the over-correction, caught in review on the web's PR #819. Using
        // "a lookup is in flight" as the escape hatch gives EVERY MONITOR-offline peer
        // "Waiting for whois reply…", because a lookup is always out on open.
        XCTAssertNil(resolve(peer: .offline, isLookingUp: true).statusLine)
    }

    // MARK: - Send DM

    func testSendDmIsHiddenForYourself() {
        XCTAssertFalse(resolve(peer: .online, whois: identity, isSelf: true).canSendDirectMessage)
    }

    func testSendDmIsHiddenWhenADmWouldBounce() {
        // Here the two verdicts ARE rightly folded together: a DM bounces whether MONITOR says
        // they're gone or the lookup found nobody. This is the question `isOffline` was for.
        XCTAssertFalse(resolve(peer: .offline).canSendDirectMessage)
        XCTAssertFalse(resolve(peer: .unknown, whois: miss).canSendDirectMessage)
    }

    func testSendDmIsOfferedToSomeoneWhoMightBeThere() {
        XCTAssertTrue(resolve(peer: .online, whois: identity).canSendDirectMessage)
        // Unknown is "potentially online" — the no-MONITOR case, which is most networks. A DM
        // there is exactly what the user is trying to do.
        XCTAssertTrue(resolve(peer: .unknown).canSendDirectMessage)
        XCTAssertTrue(resolve(peer: .away, whois: identity).canSendDirectMessage)
    }

    // MARK: - hasDetails

    func testAMissIsAReplyWithNothingInIt() {
        // ⚠ Treating "there is a reply" as "there are details" would suppress the very line
        // that has to explain the miss.
        XCTAssertFalse(ProfileStatus.hasDetails(miss))
        XCTAssertFalse(ProfileStatus.hasDetails(nil))
        XCTAssertTrue(ProfileStatus.hasDetails(identity))
    }

    func testChannelsAloneCountAsDetails() {
        // A whois can come back with nothing but a channel list on a locked-down network.
        XCTAssertTrue(ProfileStatus.hasDetails(WhoisResult(nick: "alice", channelsLine: "#foo")))
        // But a channels line that names no channel does not.
        XCTAssertFalse(ProfileStatus.hasDetails(WhoisResult(nick: "alice", channelsLine: "@")))
    }
}

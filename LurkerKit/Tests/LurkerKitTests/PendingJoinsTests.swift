// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// What became of a join this device asked for (#57).
///
/// Before this, nothing tracked a join between asking and hearing back: a refusal said nothing, a
/// join that never landed said nothing, and the only thing that moved the user was a wait in the
/// chat screen that one of the four ways in used.
@Suite("Pending joins")
struct PendingJoinsTests {

    private let chan = BufferKey(networkId: 1, target: "#lurker")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("a channel-joined for a join we asked for settles it, carrying whether to open")
    func joinedSettlesTheRequest() {
        var joins = PendingJoins()
        joins.request(chan, opens: true, now: t0)
        #expect(joins.joined(chan) == .joined(chan, opens: true))
        #expect(joins.pendingCount == 0)
    }

    @Test("a join nobody here asked for moves nobody")
    func unaskedJoinsAreIgnored() {
        // A reconnect's rejoin, or a join made on another device, must not switch the screen or
        // toast a refusal this device never saw coming.
        var joins = PendingJoins()
        #expect(joins.joined(chan) == nil)
        #expect(joins.refused(chan, reason: "This channel is invite-only.") == nil)
    }

    @Test("the server's spelling answers the typed one")
    func matchingFoldsCase() {
        var joins = PendingJoins()
        joins.request(BufferKey(networkId: 1, target: "#Lurker"), opens: true, now: t0)
        #expect(joins.joined(chan) == .joined(chan, opens: true))
    }

    @Test("a refusal carries the server's reason, and is forgotten")
    func refusalCarriesTheReason() {
        var joins = PendingJoins()
        joins.request(chan, opens: true, now: t0)
        #expect(
            joins.refused(chan, reason: "This channel is invite-only.")
                == .refused(chan, reason: "This channel is invite-only.")
        )
        #expect(joins.pendingCount == 0)
    }

    @Test("a forward's part settles the join without a word")
    func forwardIsQuiet() {
        // A 470 answers under another name. Left pending, it would time out into a "No response"
        // for a join that was answered.
        var joins = PendingJoins()
        joins.request(chan, opens: true, now: t0)
        joins.parted(chan)
        #expect(joins.expire(now: t0.addingTimeInterval(PendingJoins.timeout)) == [])
    }

    @Test("a join still unanswered at the deadline times out, once")
    func timeoutFiresOnce() {
        var joins = PendingJoins()
        joins.request(chan, opens: false, now: t0)
        #expect(joins.expire(now: t0.addingTimeInterval(PendingJoins.timeout - 1)) == [])
        #expect(joins.expire(now: t0.addingTimeInterval(PendingJoins.timeout)) == [.timedOut(chan)])
        #expect(joins.expire(now: t0.addingTimeInterval(PendingJoins.timeout + 1)) == [])
    }

    @Test("asking again opens if either request wanted to, and restarts the clock")
    func repeatRequestMerges() {
        var joins = PendingJoins()
        joins.request(chan, opens: false, now: t0)
        joins.request(chan, opens: true, now: t0.addingTimeInterval(8))
        #expect(
            joins.expire(now: t0.addingTimeInterval(PendingJoins.timeout)) == [],
            "the second request restarted the clock"
        )
        #expect(joins.joined(chan) == .joined(chan, opens: true))
    }

    @Test("a dropped socket forgets every join")
    func removeAllForgets() {
        var joins = PendingJoins()
        joins.request(chan, opens: true, now: t0)
        joins.removeAll()
        #expect(joins.pendingCount == 0)
        #expect(joins.joined(chan) == nil)
    }

    @Test("a notice says what happened and names the channel")
    func noticeCopy() {
        #expect(
            JoinNotice.refused(channel: "#secret", reason: "This channel is invite-only.").message
                == "Couldn't join #secret: This channel is invite-only."
        )
        #expect(JoinNotice.noResponse(channel: "#secret").message == "No response joining #secret")
        #expect(
            JoinNotice.notConnected(channel: "#secret", network: "Libera").message
                == "Can't join #secret while Libera is offline"
        )
    }
}

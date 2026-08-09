// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LurkerKit

/// Behaviour of the client-side preview store, with the resolver stubbed.
///
/// The failure cases are the point. Two of these are regression guards for findings that made
/// links permanently blank for a whole app session — the kind of bug that reads as "the feature
/// doesn't work" rather than as an error.
@Suite("LinkPreviewStore")
@MainActor
struct LinkPreviewStoreTests {

    /// Records what was asked for, and answers with whatever the test dictates.
    final class Stub {
        var batches: [[String]] = []
        var answer: ([String]) -> [LinkPreview] = { urls in
            urls.map { LinkPreview(url: $0, status: .ok, kind: .image, src: "/proxy/\($0)") }
        }
    }

    private func makeStore(_ stub: Stub) -> LinkPreviewStore {
        LinkPreviewStore { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
    }

    /// The store coalesces on a short timer, so tests have to let it fire.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    @Test("resolves what it's asked for and serves it back")
    func resolves() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/a.png"])
        await settle()
        #expect(store.preview(for: "https://e.test/a.png")?.src == "/proxy/https://e.test/a.png")
    }

    @Test("coalesces a batch into one call rather than one per URL")
    func coalesces() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/1", "https://e.test/2", "https://e.test/3"])
        await settle()
        #expect(stub.batches.count == 1)
        #expect(stub.batches.first?.count == 3)
    }

    @Test("asks about a repeated URL only once")
    func dedupes() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/x", "https://e.test/x"])
        await settle()
        store.request(["https://e.test/x"])
        await settle()
        #expect(stub.batches.flatMap { $0 } == ["https://e.test/x"])
    }

    @Test("a failed batch is retried later, not remembered as a verdict")
    func failureIsRetryable() async {
        // ⚠⚠ Regression guard. `asked` used to retain a URL whatever came back, and the client
        // maps any non-2xx (including a 429, which the connect-time backlog burst can provoke on
        // its own) to an empty array. So one throttled batch meant those links were blank for the
        // rest of the app session. A transport failure says nothing about the URL.
        let stub = Stub()
        stub.answer = { _ in [] }
        let store = makeStore(stub)

        store.request(["https://e.test/a", "https://e.test/b"])
        await settle()
        #expect(stub.batches.count == 1)
        #expect(store.preview(for: "https://e.test/a") == nil)

        // Server recovers; the next priming pass must be allowed to ask again.
        stub.answer = { urls in
            urls.map { LinkPreview(url: $0, status: .ok, kind: .page, title: "T") }
        }
        store.request(["https://e.test/a", "https://e.test/b"])
        await settle()
        #expect(stub.batches.count == 2)
        #expect(store.preview(for: "https://e.test/a")?.title == "T")
    }

    @Test("an `unavailable` answer IS remembered, unlike a failure")
    func unavailableIsRemembered() async {
        // The distinction that matters: the server negative-caches a genuine per-URL failure
        // itself, so re-asking would be a pointless loop. Only TRANSPORT failures are retried.
        let stub = Stub()
        stub.answer = { urls in urls.map { LinkPreview(url: $0, status: .unavailable, kind: .page) } }
        let store = makeStore(stub)

        store.request(["https://e.test/gone"])
        await settle()
        store.request(["https://e.test/gone"])
        await settle()
        #expect(stub.batches.count == 1)
    }

    @Test("splits a batch past the server's per-request cap")
    func splitsLargeBatch() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request((0..<25).map { "https://e.test/\($0)" })
        // Batches after the first are paced, so this needs longer than the coalesce window.
        try? await Task.sleep(for: .milliseconds(900))
        #expect(stub.batches.count == 2)
        #expect(stub.batches[0].count == 20)
        #expect(stub.batches[1].count == 5)
    }

    @Test("reset drops everything, so a new account starts clean")
    func resetClears() async {
        let stub = Stub()
        let store = makeStore(stub)
        store.request(["https://e.test/a"])
        await settle()
        #expect(store.preview(for: "https://e.test/a") != nil)

        store.reset()
        #expect(store.preview(for: "https://e.test/a") == nil)

        // And `asked` cleared too, so the next account's server is actually consulted.
        store.request(["https://e.test/a"])
        await settle()
        #expect(stub.batches.count == 2)
    }

    // MARK: - Coming back to an answer that wasn't one

    @Test("a URL the server never mentions is not left permanently blank")
    func omittedUrlRecovers() async {
        // ⚠⚠ The state nothing could see: `asked` still held the URL so priming skipped it, and
        // no retry entry existed so nothing came back for it. Permanently blank, from a 200 that
        // looked perfectly fine — a truncated response, a batch cap out of step, an error body.
        // Reconciling against what was SENT is what closes it.
        let stub = Stub()
        stub.answer = { urls in
            urls.filter { $0.hasSuffix("a") }
                .map { LinkPreview(url: $0, status: .ok, kind: .page, title: "T") }
        }
        let store = makeStore(stub)
        store.request(["https://e.test/a", "https://e.test/ghost"])
        await settle()

        #expect(store.preview(for: "https://e.test/a")?.title == "T")
        #expect(store.preview(for: "https://e.test/ghost") == nil)
        // Not pending — nothing is coming — so it never stalls a message's reveal...
        #expect(!store.isPending("https://e.test/ghost"))
        // ...and it is armed to be asked about again rather than forgotten.
        #expect(store.retry["https://e.test/ghost"] != nil)
    }

    @Test("re-asks a SHORT-ttl unavailable once its deadline passes")
    func transientIsReasked() async {
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { urls in
            urls.map {
                LinkPreview(
                    url: $0, status: .unavailable, kind: .page,
                    expiresAt: ISOTime.string(from: clock.date.addingTimeInterval(15)))
            }
        }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/busy"])
        await settle()
        #expect(stub.batches.count == 1)
        #expect(store.retry["https://e.test/busy"] != nil)

        // Not yet due: the floor is 15s and the deadline is jittered around it.
        clock.date.addTimeInterval(5)
        #expect(!store.runDueReasks())
        #expect(stub.batches.count == 1)

        clock.date.addTimeInterval(60)
        #expect(store.runDueReasks())
        await settle()
        #expect(stub.batches.count == 2, "the URL is asked about a second time")
    }

    @Test("never re-asks a VERDICT, so a dead link is not a perpetual poller")
    func verdictIsNotReasked() async {
        // ⚠⚠ The server answers a real failure with a one-hour TTL and a transient refusal with
        // ~15s. Re-asking both turned 300 dead links scrolled past into 300 outbound fetches an
        // hour — and because the client deadline and the server row TTL start together, each one
        // landed just AFTER the row lapsed: a guaranteed cache miss and a fresh fetch to a
        // known-dead origin, forever.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { urls in
            urls.map {
                LinkPreview(
                    url: $0, status: .unavailable, kind: .page,
                    expiresAt: ISOTime.string(from: clock.date.addingTimeInterval(3600)))
            }
        }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/dead"])
        await settle()
        #expect(store.retry["https://e.test/dead"] == nil, "a verdict arms nothing")

        clock.date.addTimeInterval(600)
        #expect(!store.runDueReasks())
        #expect(stub.batches.count == 1)
    }

    @Test("a verdict IS asked again by priming, once it has genuinely expired")
    func expiredVerdictIsReopenedByPriming() async {
        // The other half of the rule above: a dead link is not polled, but neither is it
        // remembered forever — the next priming pass after the TTL lapses asks again. Before
        // this, `expiresAt` was carried on the wire and read by nobody.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { urls in
            urls.map {
                LinkPreview(
                    url: $0, status: .unavailable, kind: .page,
                    expiresAt: ISOTime.string(from: clock.date.addingTimeInterval(3600)))
            }
        }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/dead"])
        await settle()

        // Still inside the TTL: priming must NOT re-ask, or the cap achieves nothing.
        clock.date.addTimeInterval(1800)
        store.request(["https://e.test/dead"])
        await settle()
        #expect(stub.batches.count == 1)

        clock.date.addTimeInterval(1801)
        store.request(["https://e.test/dead"])
        await settle()
        #expect(stub.batches.count == 2)
    }

    // MARK: - Is an answer still coming?

    @Test("a URL nobody ever asked about is settled, not pending")
    func neverAskedIsSettled() {
        // ⚠⚠ Three states, not two. Conflating "in flight" with "nobody ever asked" blanks a
        // message forever: the gate withholds the whole block waiting for an answer that was
        // never requested.
        let store = makeStore(Stub())
        #expect(!store.isPending("https://e.test/nobody-primed-this"))
        #expect(store.allSettled(["https://e.test/nobody-primed-this"]))
    }

    @Test("a URL waiting on a re-ask is SETTLED, so one 502 cannot blank a screen")
    func awaitingReaskIsSettled() async {
        // ⚠⚠ The branch that matters most. Counting a retry as pending hid the block for the
        // whole 15s→5min ladder, and indefinitely while a server kept failing — one 502 during a
        // deploy blanked the attachments of every message that shared a batch with it, siblings
        // that had resolved perfectly well included.
        let stub = Stub()
        stub.answer = { _ in [] }
        let store = makeStore(stub)
        store.request(["https://e.test/a", "https://e.test/b"])
        await settle()

        #expect(store.retry["https://e.test/a"] != nil)
        #expect(!store.isPending("https://e.test/a"))
        #expect(store.allSettled(["https://e.test/a", "https://e.test/b"]))
    }

    @Test("a URL being re-asked RIGHT NOW is still settled, so recovery never re-hides a block")
    func reaskInFlightIsSettled() async {
        // ⚠⚠ The case the `retry`-before-`pending` ordering exists for, and it took two attempts
        // to write a test that reaches it. After a plain failure the URL sits in neither `asked`
        // nor `pending`, so the ordering is unobservable; and after an `unavailable` there is a
        // cached VALUE, so `isPending` returns on its first line and never consults `retry` at
        // all. The branch is live in exactly one state: no value (a transport failure), and
        // re-queued by `runDueReasks`. There the URL is pending in the plain sense and must
        // still read as settled, or a recovery attempt re-hides a block already on screen.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { _ in [] }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/busy"])
        await settle()
        #expect(store.preview(for: "https://e.test/busy") == nil, "no value to short-circuit on")

        clock.date.addTimeInterval(60)
        #expect(store.runDueReasks(), "the URL is now queued for a second ask")
        #expect(store.retry["https://e.test/busy"] != nil, "and still carries its retry entry")
        #expect(!store.isPending("https://e.test/busy"))
        #expect(store.allSettled(["https://e.test/busy"]))
    }

    @Test("the backoff ladder survives a re-ask, so it genuinely doubles")
    func ladderPersistsAcrossReasks() async {
        // ⚠⚠ `tries` lives in the retry entry, so deleting that entry when re-queueing re-armed
        // at tries = 1 every single time — a "backoff" that was a flat 15-second poll aimed at a
        // server already saying it was overloaded. Parking the entry at `.distantFuture` is what
        // keeps the count.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { _ in [] }  // transport failure, every time
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/flaky"])
        await settle()
        #expect(store.retry["https://e.test/flaky"]?.tries == 1)
        // jitter at its midpoint is a multiplier of exactly 1, so the first gap is the floor.
        #expect(
            store.retry["https://e.test/flaky"]?.at.timeIntervalSince(clock.date)
                == PreviewReask.floor)

        clock.date.addTimeInterval(60)
        #expect(store.runDueReasks())
        await settle()

        #expect(store.retry["https://e.test/flaky"]?.tries == 2, "the count carried across")
        #expect(
            store.retry["https://e.test/flaky"]?.at.timeIntervalSince(clock.date)
                == PreviewReask.floor * 2,
            "so the second gap is twice the first, not the floor again")
    }

    @Test("a URL in flight IS pending, which is what the gate is for")
    func inFlightIsPending() async {
        let store = makeStore(Stub())
        store.request(["https://e.test/slow"])
        // Deliberately not settled: the coalesce window has not fired, so no answer can exist.
        #expect(store.isPending("https://e.test/slow"))
        #expect(!store.allSettled(["https://e.test/slow"]))
        await settle()
        #expect(!store.isPending("https://e.test/slow"))
    }
}

/// A hand-wound clock, so the backoff can be tested as arithmetic rather than through a sleep.
@MainActor
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_750_000_000)
}

/// The re-ask rule on its own, away from the store's timers.
@Suite("PreviewReask")
struct PreviewReaskTests {

    @Test("only a SHORT ttl means come back")
    func verdictBoundary() {
        #expect(PreviewReask.delay(untilExpiry: 15, tries: 1, jitter: 0.5) != nil)
        #expect(PreviewReask.delay(untilExpiry: 60, tries: 1, jitter: 0.5) != nil)
        #expect(PreviewReask.delay(untilExpiry: 61, tries: 1, jitter: 0.5) == nil)
        #expect(PreviewReask.delay(untilExpiry: 3600, tries: 1, jitter: 0.5) == nil)
    }

    @Test("the floor RAISES a short deadline and never lowers a longer one")
    func floorIsAFloor() {
        // ⚠ A floor, not the delay. With jitter at its midpoint the multiplier is exactly 1, so
        // these read as the base value.
        #expect(PreviewReask.delay(untilExpiry: 2, tries: 1, jitter: 0.5) == 15)
        #expect(PreviewReask.delay(untilExpiry: 40, tries: 1, jitter: 0.5) == 40)
    }

    @Test("doubles per consecutive failure, up to a ceiling")
    func backoffLadder() {
        #expect(PreviewReask.delay(untilExpiry: 0, tries: 1, jitter: 0.5) == 15)
        #expect(PreviewReask.delay(untilExpiry: 0, tries: 2, jitter: 0.5) == 30)
        #expect(PreviewReask.delay(untilExpiry: 0, tries: 3, jitter: 0.5) == 60)
        #expect(PreviewReask.delay(untilExpiry: 0, tries: 99, jitter: 0.5) == 300)
    }

    @Test("spreads the return by ±25%, so the losers of one stall don't come back together")
    func jitterSpread() {
        // ⚠⚠ Not cosmetic. The server jitters its transient TTL precisely so a saturation event
        // doesn't produce a single returning wave; taking max(untilExpiry, floor) against a
        // fixed floor threw that away and re-synchronised every client onto the same
        // millisecond — a thundering herd aimed at a server that had just said it was overloaded.
        let low = PreviewReask.delay(untilExpiry: 0, tries: 1, jitter: 0)!
        let high = PreviewReask.delay(untilExpiry: 0, tries: 1, jitter: 0.999_999)!
        #expect(low == 15 * 0.75)
        #expect(high > 15 * 1.24 && high <= 15 * 1.25)
        #expect(low < high)
    }
}

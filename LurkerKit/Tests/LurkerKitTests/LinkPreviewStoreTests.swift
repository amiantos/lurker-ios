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
    ///
    /// ⚠ Right for asserting that something did NOT happen — there is no event to wait for, so a
    /// duration is the only thing to wait. For the opposite case use `eventually`: a fixed sleep
    /// there is a bet on how fast the machine is, and CI is slower and more contended than the
    /// one these were written on.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// Wait until something is true, rather than for long enough that it probably is.
    ///
    /// ⚠⚠ `failureIsRetryable` failed on CI and passed everywhere else: the store's work is paced
    /// by real sleeps (a 24ms coalesce, then a resolve), and this suite runs on the main actor
    /// with every other suite in parallel — so the 120ms `settle()` it was betting on ran out
    /// before a flush that takes ~24ms on an idle laptop. The assertion was about a rule and it
    /// was measuring a stopwatch. Polling costs nothing when the condition already holds, and the
    /// timeout is long enough that reaching it means something is genuinely wrong.
    private func eventually(
        within limit: Duration = .seconds(5), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
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

    @Test("a failed batch is retried later, not remembered as a verdict — but not instantly")
    func failureIsRetryable() async {
        // ⚠⚠ Regression guard. `asked` used to retain a URL whatever came back, and the client
        // maps any non-2xx (including a 429, which the connect-time backlog burst can provoke on
        // its own) to an empty array. So one throttled batch meant those links were blank for the
        // rest of the app session. A transport failure says nothing about the URL.
        //
        // ⚠ It must not be retried IMMEDIATELY either, which is what this asserted before.
        // `forgetForRetry` takes the URL out of `asked` while arming a deadline, so a priming
        // pass arriving right behind a 429 — a reconnect's backlog replay, a scroll-up page —
        // re-POSTed the whole failed set 24ms after the server said it was overloaded. The
        // backoff has to pace both ways back in, not just the timer.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { _ in [] }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }

        store.request(["https://e.test/a", "https://e.test/b"])
        #expect(await eventually { stub.batches.count == 1 })
        #expect(store.preview(for: "https://e.test/a") == nil)

        // Server recovers — but the ladder still holds, so priming must NOT ask yet.
        stub.answer = { urls in
            urls.map { LinkPreview(url: $0, status: .ok, kind: .page, title: "T") }
        }
        store.request(["https://e.test/a", "https://e.test/b"])
        await settle()  // a non-event: there is nothing to wait FOR
        #expect(stub.batches.count == 1, "still inside the backoff")

        // Past the deadline, the next priming pass gets through.
        clock.date.addTimeInterval(PreviewReask.floor + 1)
        store.request(["https://e.test/a", "https://e.test/b"])
        // ⚠ Waits on the VALUE, not on the batch count. The stub records its call before it
        // returns, so `batches.count == 2` is observable a moment before the answer has been
        // written into the cache — which would make the title assertion below the flake instead.
        #expect(await eventually { store.preview(for: "https://e.test/a")?.title == "T" })
        #expect(stub.batches.count == 2)
    }

    @Test("an `unavailable` with no stated expiry is a VERDICT, not an invitation")
    func unavailableWithoutExpiryIsAVerdict() async {
        // ⚠⚠ This asserted only that a second `request()` made no second batch — which passed
        // against a store that had armed a perpetual poller, because its 240ms of sleeps are
        // shorter than the 15s floor. It was measuring the sleep, not the rule.
        //
        // The rule: an absent or unreadable `expiresAt` means nothing was stated, and nothing
        // stated is a verdict. Mapping it to "zero seconds until expiry" sailed through the
        // short-TTL test and armed a ladder `retry` only ever clears on an `ok`, so the URL was
        // re-POSTed forever. `LinkPreview.expiry` documented this as the safe direction and the
        // code did the opposite of its own comment.
        let stub = Stub()
        stub.answer = { urls in
            urls.map { LinkPreview(url: $0, status: .unavailable, kind: .page) }
        }
        let store = makeStore(stub)

        store.request(["https://e.test/gone"])
        await settle()
        #expect(stub.batches.count == 1)
        #expect(store.retry["https://e.test/gone"] == nil, "nothing armed, so nothing polls")
        #expect(!store.runDueReasks(), "and nothing ever comes due")

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

    // MARK: - Sign-out, and not repopulating what it cleared

    @Test("a reset mid-flush is not undone by answers already in the air")
    func resetDuringFlushIsNotRepopulated() async {
        // ⚠⚠ Reachable with no timing luck at all: a 401 makes `resolveLinkPreviews` publish
        // `.unauthorized`, which runs `onAuthLost()` → `reset()` RE-ENTRANTLY while the flush is
        // suspended at `await resolve`. The flush then resumed on the store it had just emptied
        // and refilled it — the previous account's metadata back in `cache`, a fresh re-ask
        // timer armed — so the next account served A's previews and POSTed A's URLs under B's
        // bearer token. Exactly what the sign-out comment claims to have closed.
        let stub = Stub()
        let store = makeStore(stub)
        var storeRef: LinkPreviewStore?
        let resetting = LinkPreviewStore { urls in
            stub.batches.append(urls)
            // Stand in for the 401 → onAuthLost → reset re-entrancy, at the exact moment the
            // real one happens: while the answer is in flight.
            storeRef?.reset()
            return urls.map { LinkPreview(url: $0, status: .ok, kind: .page, title: "A") }
        }
        storeRef = resetting
        _ = store

        resetting.request(["https://e.test/a"])
        await settle()

        #expect(
            resetting.preview(for: "https://e.test/a") == nil,
            "the cleared store must stay cleared")
        #expect(resetting.retry.isEmpty, "and no timer may survive into the next account")
    }

    @Test("one flush at a time, so pacing is not multiplied by the number of priming passes")
    func flushesDoNotOverlap() async {
        // ⚠⚠ `flushTask` was released BEFORE the flush body ran, so the guard suppressing a
        // second flush stopped suppressing anything for the whole duration of one. A connect
        // burst is a continuous stream of priming passes, and each one landing mid-flight
        // spawned another loop — every loop granting itself an unpaced first batch, because the
        // 600ms delay only ever applies from index 1. N loops, N times the request rate, into
        // the account's 120/min limit whose 429s then put every URL on the ladder.
        let stub = Stub()
        var inFlight = 0
        var peak = 0
        let store = LinkPreviewStore { urls in
            stub.batches.append(urls)
            inFlight += 1
            peak = max(peak, inFlight)
            try? await Task.sleep(for: .milliseconds(60))
            inFlight -= 1
            return urls.map { LinkPreview(url: $0, status: .ok, kind: .image) }
        }

        // Five priming passes arriving while the first flush is in the air.
        for pass in 0..<5 {
            store.request((0..<30).map { "https://e.test/p\(pass)-\($0)" })
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .seconds(3))

        #expect(peak == 1, "never more than one resolve in flight; saw \(peak)")
    }

    @Test("repaints after every batch, not only when the whole flush drains")
    func repaintsPerBatch() async {
        // 200 URLs is 10 batches paced 600ms apart, so deferring the callback to the end held
        // the first batch's images unpainted for the entire drain — and at the scale this class
        // is built for ("a connect burst can prime thousands of URLs") that is about a minute of
        // resolved previews sitting in the cache with nothing told to draw them.
        let stub = Stub()
        let store = makeStore(stub)
        var updates = 0
        store.onUpdate = { _ in updates += 1 }

        store.request((0..<45).map { "https://e.test/\($0)" })
        // Long enough for two of the three batches, not all three.
        try? await Task.sleep(for: .milliseconds(800))
        #expect(updates >= 2, "each completed batch paints; saw \(updates)")
    }

    @Test("says WHICH urls moved, so a consumer can tell whether it is affected")
    func reportsTheUrlsThatMoved() async {
        // Without this the only thing a list could learn is "something, somewhere, changed" —
        // so links resolving for one buffer rebuilt every visible cell of whichever buffer the
        // reader was actually looking at, once per batch.
        let stub = Stub()
        let store = makeStore(stub)
        var reported: [Set<String>] = []
        store.onUpdate = { reported.append($0) }

        store.request(["https://e.test/a", "https://e.test/b"])
        #expect(await eventually { !reported.isEmpty })

        #expect(reported.count == 1)
        #expect(reported.first == ["https://e.test/a", "https://e.test/b"])
    }

    @Test("a repeat failure for a url already on the ladder tells the list nothing")
    func repeatFailureIsSilent() async {
        // ⚠ The other half of the re-ask being silent. Its FLUSH still runs, and reporting the
        // whole chunk there put the wasted reload straight back: the URL is mentioned by a
        // visible row, so the filter lets it through, and a dead link redraws the row it sits in
        // once per rung. The first omission is the event — it takes the URL out of `asked` and
        // settles its message's gate. The second says nothing new.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { _ in [] }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }

        var reported: [Set<String>] = []
        store.onUpdate = { reported.append($0) }
        store.request(["https://e.test/dead"])
        #expect(await eventually { !reported.isEmpty })
        #expect(reported == [["https://e.test/dead"]], "the first omission settles the gate")

        // The ladder comes due and the server fails it again.
        clock.date.addTimeInterval(PreviewReask.floor + 1)
        store.request(["https://e.test/dead"])
        #expect(await eventually { stub.batches.count == 2 }, "asked a second time")
        // ⚠ A beat AFTER the batch lands, because the stub records its call before the flush
        // decides whether to say anything — asserting the silence on the batch alone would be
        // asserting it a moment too early, which is a test that passes for the wrong reason.
        await settle()
        #expect(reported.count == 1, "and the second answer says nothing new")
    }

    @Test("a re-ask tells the list nothing, because it changes nothing on screen")
    func reaskIsSilent() async {
        // ⚠⚠ A re-ask re-queues a URL but KEEPS its retry entry (parked), and `isPending` reads
        // anything holding one as settled — so the message's gate was settled before and is
        // settled after, and no row can draw differently. Announcing it spent a full reload of
        // every visible cell per rung of the ladder: six of them for a link the server can't
        // resolve, each one discarding and rebuilding the screen to redraw nothing. The ANSWER
        // is what gets announced, from the flush that follows.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { _ in [] }  // a transport failure: arms the ladder
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/dead"])
        // The ladder has to be armed before the clock is advanced past it, or there is no rung
        // to come due and this tests nothing.
        #expect(await eventually { store.retry["https://e.test/dead"] != nil })

        var reported: [Set<String>] = []
        store.onUpdate = { reported.append($0) }
        clock.date.addTimeInterval(PreviewReask.floor + 1)
        #expect(store.runDueReasks(), "the rung is due")
        #expect(reported.isEmpty, "and it is nobody's business but the store's")
    }

    @Test("a url the server never mentioned still counts as moved")
    func reportsOmittedUrlsToo() async {
        // ⚠ The set is what MOVED, not what was answered. An omission goes onto the retry
        // ladder, and `allSettled` reads that as settled — which can be the event that completes
        // a message's reveal gate. Reporting only the answers would leave that message blank
        // until something unrelated redrew it.
        let stub = Stub()
        stub.answer = { urls in
            urls.filter { $0 != "https://e.test/b" }
                .map { LinkPreview(url: $0, status: .ok, kind: .image, src: "/proxy/\($0)") }
        }
        let store = makeStore(stub)
        var reported: [Set<String>] = []
        store.onUpdate = { reported.append($0) }

        store.request(["https://e.test/a", "https://e.test/b"])
        #expect(await eventually { !reported.isEmpty })

        #expect(reported.first?.contains("https://e.test/b") == true)
    }

    @Test("batches follow priming order, so the visible buffer is not sent to the back")
    func batchesFollowPrimingOrder() async {
        // ⚠ `Array(pending)` over a Set gave an order seeded per launch, so which batch a URL
        // landed in was random — and on a large burst the buffer actually on screen could sit
        // behind twenty paced batches for the better part of a minute, unreproducibly. Priming
        // runs outward from the frame the reader is looking at, so insertion order is the
        // useful order.
        let stub = Stub()
        let store = makeStore(stub)
        let urls = (0..<40).map { "https://e.test/\($0)" }
        store.request(urls)
        try? await Task.sleep(for: .milliseconds(800))

        #expect(stub.batches.first == Array(urls.prefix(20)))
    }

    @Test("an expiry already in the PAST is a verdict, not an invitation")
    func lapsedExpiryIsAVerdict() async {
        // ⚠⚠ The first fix closed only the nil half of its own documented bug. A stamp already
        // behind us yields a NEGATIVE untilExpiry, which sails through the short-TTL test and
        // arms the ladder — so a device whose clock runs an hour fast reads every one-hour
        // failure TTL as lapsed and turns all 300 dead links a reader scrolls past into pollers.
        // That is the scenario the comment claimed to have closed. A lapsed answer is re-opened
        // by priming, which does not need a timer as well.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { urls in
            urls.map {
                LinkPreview(
                    url: $0, status: .unavailable, kind: .page,
                    expiresAt: ISOTime.string(from: clock.date.addingTimeInterval(-3600)))
            }
        }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/skewed"])
        await settle()
        #expect(store.retry["https://e.test/skewed"] == nil)
        #expect(!store.runDueReasks())
    }

    @Test("a URL nobody ever answers is chased a bounded number of times, then let go")
    func unansweredRetriesAreBounded() async {
        // ⚠⚠ This path can never reach a verdict on its own: nothing was ANSWERED, so `delay`
        // sees a zero expiry and always says come back. PreviewReask justifies having no attempt
        // cap on the grounds that a dead URL arrives with a one-hour TTL — true of an answer,
        // false of silence. So a 502, or the operator turning the feature off mid-session, put
        // every primed URL on a permanent five-minute poll for the life of the session.
        //
        // `asked` stays clear, so a later priming pass can still try — driven by new messages
        // rather than by a timer, which is the difference between recovering and hammering.
        let clock = TestClock()
        let stub = Stub()
        stub.answer = { _ in [] }
        let store = LinkPreviewStore(now: { clock.date }, jitter: { 0.5 }) { urls in
            stub.batches.append(urls)
            return stub.answer(urls)
        }
        store.request(["https://e.test/silent"])
        await settle()

        var rounds = 0
        while store.retry["https://e.test/silent"] != nil, rounds < 20 {
            clock.date.addTimeInterval(600)
            _ = store.runDueReasks()
            await settle()
            rounds += 1
        }
        #expect(rounds < 20, "it gave up rather than polling forever")
        #expect(store.retry["https://e.test/silent"] == nil)
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

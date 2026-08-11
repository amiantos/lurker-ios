// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Instance feature flags from the public `/api/config`.
///
/// Absent means off: a server that doesn't advertise a flag doesn't have the feature. Defaults
/// are deliberately the OFF value, so a failed fetch can't conjure a feature the server may not
/// have — the settings rows would appear and then every resolve would 404.
public struct InstanceFeatures: Sendable, Equatable {
    public var linkPreviews: Bool = false
    public init(linkPreviews: Bool = false) { self.linkPreviews = linkPreviews }
}

/// The client half of link previews.
///
/// Everything expensive is on the server — the fetch, the HTML parse, the cache, the byte
/// proxy. What's left here is the thing a client is uniquely placed to do: notice that a
/// screenful of scrollback contains the same eight URLs forty times, and turn that into one
/// request.
///
/// Two layers of coalescing, catching different things:
///
///   - `cache` dedupes across TIME. Scroll past a link and back, and the second pass is free.
///   - `pending` dedupes across a TICK. A buffer opening lays out a screenful of rows at
///     once; they all want previews, and they become one POST rather than twenty.
///
/// Without the second, opening a link-heavy channel would fire a request per row and walk
/// straight into the server's per-user rate limit.
@MainActor
public final class LinkPreviewStore {

    /// Server cap per request. More than this just means a second POST.
    private static let maxBatch = 20
    /// One frame-ish: long enough that everything laid out in the same pass lands in one
    /// batch, short enough that a preview never visibly lags the scroll.
    private static let coalesceDelay = Duration.milliseconds(24)

    /// Pause between batches once there's more than one.
    ///
    /// The server allows 120 resolve requests/min per account and takes 20 URLs each. A connect
    /// burst can prime thousands of URLs across every buffer, which sails past that — so the
    /// client paces itself rather than discovering the limit. ~100 requests/min, comfortably
    /// under. Only the first batch is immediate, so the buffer you're looking at isn't delayed.
    private static let interBatchDelay = Duration.milliseconds(600)

    private var cache: [String: LinkPreview] = [:]
    /// URLs already asked about, so a redraw never re-requests one.
    ///
    /// ⚠ A URL is REMOVED from this on transport failure. Keeping it meant any batch that
    /// failed — a 429 in particular, which the connect-time backlog burst can provoke by
    /// itself once scrollback spans enough channels — was remembered as a permanent verdict,
    /// and those links stayed blank for the rest of the app session. A failure says nothing
    /// about the URL.
    private var asked = Set<String>()
    private var pending = Set<String>()
    /// Insertion order for `pending`, so batching follows priming order rather than a Set's
    /// per-launch hash seed. See `flush`.
    private var pendingOrder: [String] = []
    private var flushGeneration = 0
    private var flushTask: Task<Void, Never>?

    /// URLs due to be asked about again, and how many times they already have been.
    ///
    /// ⚠⚠ An entry here means SETTLED, not pending — see `isPending`. It holds two different
    /// situations: a short-TTL `unavailable` (which has a value) and a URL put back in play by
    /// `forgetForRetry` after a transport failure or an omitted answer (which does not). Both
    /// are "we will come back to this on our own schedule", and neither is "an answer is on its
    /// way right now".
    ///
    /// ⚠ `tries` is the only record of how many times a URL has failed, so it survives
    /// `dropIfExpired`. Discarding it reset the ladder to zero on every priming pass, which in a
    /// channel where a bot reposts a failing link meant the backoff never accumulated at all.
    var retry: [String: (at: Date, tries: Int)] = [:]
    private var reaskTask: Task<Void, Never>?

    /// Called when previews arrive, so the list can re-lay-out the rows that now have one.
    /// The list reloads rather than mutating a cell, because a preview changes a row's height.
    ///
    /// ⚠⚠ Carries WHICH URLs moved, and that is the whole point of the parameter. Without it a
    /// consumer can only answer "something changed somewhere", so a batch resolving links posted
    /// in `##videogames` rebuilt every visible cell of `#lurker` — every `CompactCell` and every
    /// `MessageAttachmentsView` subtree discarded and rebuilt, a touch in progress on a link or
    /// an image cancelled, and the reader re-pinned to the bottom. A burst is `ceil(N / 20)` of
    /// those, 600ms apart.
    ///
    /// ⚠ The set is every URL whose state MOVED, not only the ones that got a value. A URL the
    /// server omitted, or one put back on the retry ladder, moves a message's reveal gate exactly
    /// as an answer does — see `allSettled`, which is why this used to fire unconditionally.
    public var onUpdate: ((Set<String>) -> Void)?

    private let resolve: ([String]) async -> [LinkPreview]
    private let now: () -> Date
    private let jitter: () -> Double

    /// `now` and `jitter` are injected so the re-ask rule can be tested as arithmetic rather
    /// than through a sleep — production passes the real clock and a real random.
    public init(
        now: @escaping () -> Date = { Date() },
        jitter: @escaping () -> Double = { Double.random(in: 0..<1) },
        resolve: @escaping ([String]) async -> [LinkPreview]
    ) {
        self.now = now
        self.jitter = jitter
        self.resolve = resolve
    }

    /// The preview for a URL, if we already have one.
    ///
    /// Synchronous and non-committal by design: a cell asks during layout and draws whatever
    /// is there. Nil means "nothing to draw", whether that's "not asked yet", "still in
    /// flight" or "came back unusable" — three states a row has no business distinguishing.
    public func preview(for url: String) -> LinkPreview? {
        cache[url]
    }

    /// Note that a URL is on screen and should be resolved if it hasn't been.
    ///
    /// Cheap and idempotent: safe to call from `cellForRowAt` for every URL in every visible
    /// row, on every reload, which is exactly how it's used.
    public func request(_ url: String) {
        dropIfExpired(url)
        guard !asked.contains(url) else { return }
        // ⚠⚠ The backoff paces BOTH ways back in, not just the timer. `forgetForRetry` takes a
        // URL out of `asked` while arming a deadline, so without this test the very next priming
        // pass — a reconnect's backlog replay, a scroll-up history page, the settings re-walk —
        // sailed through and re-POSTed the whole failed set 24ms after a 429. `tries` kept
        // climbing while the delay it computed was enforced on one path only, which is a
        // backoff that backs off exactly when nothing is happening.
        if let deadline = retry[url]?.at, deadline > now() { return }
        asked.insert(url)
        enqueue(url)
        scheduleFlush()
    }

    /// Add to the pending set, remembering the order it arrived in.
    private func enqueue(_ url: String) {
        guard pending.insert(url).inserted else { return }
        pendingOrder.append(url)
    }

    public func request(_ urls: [String]) {
        for url in urls { request(url) }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushGeneration &+= 1
        let generation = flushGeneration
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            // ⚠ `try?` swallows the cancellation error, so a cancelled task RESUMES here.
            // Without this guard it would clear `flushTask` — clobbering the handle of any
            // newer task scheduled since the reset — and then flush with no coalescing window,
            // leaving two flushes racing.
            guard !Task.isCancelled, let self else { return }
            await self.flush(generation: generation)
            // ⚠⚠ Released AFTER the flush, not before it, and the difference is two bugs.
            //
            // `reset()` cancels through this handle, so clearing it up front left a sign-out
            // with nothing to cancel — and `flush()` is suspended at `await resolve` for the
            // whole round trip. A 401 gets there re-entrantly (`resolveLinkPreviews` publishes
            // `.unauthorized`, which runs `onAuthLost()` → `reset()`), so the flush resumed on a
            // store that had just been emptied and refilled it: the previous account's metadata
            // back in `cache`, a fresh re-ask timer armed, and the next account POSTing account
            // A's URLs under account B's token.
            //
            // It also un-suppressed the guard above for the entire duration of a flush, so every
            // priming pass arriving mid-flight — and a connect burst is a continuous stream of
            // them — spawned another flush loop that granted itself an unpaced first batch. The
            // pacing only ever applied WITHIN one loop, so N loops meant N times the request
            // rate, straight into the account rate limit whose 429s then put every URL on the
            // retry ladder: the client manufacturing the storm the pacing exists to prevent.
            //
            // ⚠ Guarded by GENERATION, not by a nil check. `reset()` bumps it, so a resumed task
            // cannot clear — or chain onto — a handle belonging to a newer one.
            guard self.flushGeneration == generation else { return }
            self.flushTask = nil
            // Anything primed while this flush was in the air is still waiting for its turn.
            if !self.pending.isEmpty { self.scheduleFlush() }
        }
    }

    private func flush(generation: Int) async {
        // ⚠ Sorted, not `Array(pending)`. A `Set`'s iteration order is seeded per launch, so the
        // batch a URL landed in was random — and with a large burst the buffer actually on
        // screen could sit behind twenty paced batches for the better part of a minute, for no
        // reason anyone could reproduce. Insertion order is the useful order: priming runs from
        // the frame the reader is looking at outwards.
        let urls = pendingOrder.filter { pending.contains($0) }
        pending.removeAll()
        pendingOrder.removeAll()
        guard !urls.isEmpty else { return }

        let batches = stride(from: 0, to: urls.count, by: Self.maxBatch).map {
            Array(urls[$0..<min($0 + Self.maxBatch, urls.count)])
        }
        for (index, chunk) in batches.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.interBatchDelay) }
            // ⚠⚠ Checked on BOTH sides of the await. A sign-out that lands mid-flight must not
            // have its cleared state refilled by answers already in the air — `reset()` bumps
            // the generation, so this is the one test that covers a cancel arriving at any point
            // in a multi-batch flush.
            guard flushGeneration == generation else { return }
            let previews = await resolve(chunk)
            guard flushGeneration == generation else { return }

            var answered = Set<String>()
            for preview in previews {
                cache[preview.url] = preview
                answered.insert(preview.url)
                if preview.status == .ok {
                    retry[preview.url] = nil
                } else {
                    noteUnusableAnswer(preview.url, expiry: preview.expiry)
                }
            }

            // ⚠⚠ Reconciled against what was SENT, not merely iterated over what came back. A
            // URL the server omits — a truncated response, a batch cap drifting out of step with
            // `maxBatch`, a 200 carrying an error body — otherwise reached a state no recovery
            // path could see: `asked` still held it so priming skipped it, and no `retry` entry
            // existed so nothing came back for it. Permanently blank, from a response that
            // looked perfectly fine. A whole-batch failure (offline, 401, 429) is the same case
            // with an empty answer, so it needs no branch of its own any more.
            for url in chunk where !answered.contains(url) { forgetForRetry(url) }

            // ⚠⚠ Per BATCH, not once per flush, and unconditional.
            //
            // Unconditional, where this used to fire only if a value landed: every path above
            // can move a URL out of the pending set, and once the reveal gate exists ANY such
            // move can complete a message's block and paint it — an `unavailable` very often is
            // the answer that finishes a gate, and so is a URL the server never mentioned.
            //
            // Per batch, because batches after the first are paced 600ms apart. Deferring to the
            // end meant a 200-URL flush (10 batches) held batch 1's images unpainted for the
            // whole drain, and at the scale this class is built for — "a connect burst can prime
            // thousands of URLs" — a 2,000-URL flush is 100 batches and roughly a minute of
            // resolved previews sitting in the cache with nothing told to draw them. The re-ask
            // timer was deferred identically, so every entry that came due during the drain was
            // re-queued in one sweep the moment it finished: precisely the synchronised wave
            // PreviewReask's jitter exists to break up.
            scheduleReask()
            // The whole chunk, not just `answered`: a URL the server omitted was moved onto the
            // retry ladder above, and that moves its message's gate too.
            onUpdate?(Set(chunk))
        }
    }

    // MARK: - Coming back to an answer that wasn't one

    /// Arm (or clear) the re-ask for a URL the server did not answer usefully.
    ///
    /// `expiry` nil means nothing was stated, which is what a transport failure produces — the
    /// backoff floor alone then decides.
    /// The server ANSWERED, and the answer was not usable.
    ///
    /// ⚠⚠ An absent or unreadable `expiresAt` is a VERDICT here, not an invitation. Mapping it
    /// to "zero seconds until expiry" made it sail through the short-TTL test and arm a poller
    /// that `retry` only ever clears on an `ok` — so a `.unavailable` with no stated expiry was
    /// re-POSTed forever on the 15s→300s ladder, and PreviewReask has no attempt cap by design.
    /// Clock skew was the same trigger from the other direction: a device an hour fast computes
    /// a negative `untilExpiry` for every one-hour failure TTL, turning all 300 dead links a
    /// reader scrolls past into pollers. `LinkPreview.expiry` already documented this as the
    /// safe direction — "the alternative turns one bad field into an unbounded re-ask loop" —
    /// and the code did the opposite of its own comment.
    private func noteUnusableAnswer(_ url: String, expiry: Date?) {
        guard let expiry else {
            retry[url] = nil
            return
        }
        // ⚠⚠ An expiry already in the PAST is a verdict too, and the first version of this only
        // closed the nil half of its own documented bug. A lapsed stamp yields a negative
        // `untilExpiry`, which sails through the short-TTL test and arms the ladder — so a device
        // whose clock runs an hour fast reads every one-hour failure TTL as expired and turns all
        // 300 dead links a reader scrolls past into pollers, which is the exact scenario the
        // comment claimed to have closed. A lapsed answer is re-opened by `dropIfExpired` on the
        // next priming pass; it does not need a timer as well.
        let untilExpiry = expiry.timeIntervalSince(now())
        guard untilExpiry > 0 else {
            retry[url] = nil
            return
        }
        arm(url, untilExpiry: untilExpiry)
    }

    /// Put a URL back in play after NO answer at all — a transport failure, or a URL the server
    /// omitted from a response it did send.
    ///
    /// Distinct from `noteUnusableAnswer` precisely because nothing was stated: there is no
    /// verdict to respect, so the backoff floor alone decides when to come back.
    ///
    /// ⚠ The cached VALUE is deliberately left alone where one exists — a stale card merely due
    /// a refresh keeps rendering rather than blanking. What changes is `asked`, which re-opens
    /// the URL to priming.
    private func forgetForRetry(_ url: String) {
        asked.remove(url)
        // ⚠⚠ Bounded, because this path can never reach a verdict on its own. `PreviewReask`
        // justifies having no attempt cap on the grounds that "a genuinely dead URL is answered
        // with the one-hour failure TTL, so it is a verdict and never reaches here" — true of
        // `noteUnusableAnswer`, false of this. Nothing was ever ANSWERED here, so `delay` sees a
        // zero expiry and always says come back. Two live triggers: the resolve endpoint 502s
        // or the operator turns the feature off mid-session, in which case every URL of every
        // chunk lands here — a connect burst having primed thousands — and polls for the life of
        // the session; or `FailableDecodable` drops a descriptor this build can't read, which
        // fails identically on every retry, forever.
        //
        // After the ladder reaches its ceiling we stop. `asked` is already clear, so the next
        // priming pass that mentions the URL asks again — driven by new messages arriving rather
        // than by a timer, which is the difference between recovering and hammering.
        let tries = (retry[url]?.tries ?? 0) + 1
        guard tries <= Self.maxUnansweredRetries else {
            retry[url] = nil
            return
        }
        arm(url, untilExpiry: 0)
    }

    /// How many times a URL nobody answered is chased before we let it go.
    ///
    /// Six lands on the 15s→300s ladder's ceiling, so the last wait is already five minutes.
    /// Past that a timer is not recovery, it is a background process.
    private static let maxUnansweredRetries = 6

    private func arm(_ url: String, untilExpiry: TimeInterval) {
        let tries = (retry[url]?.tries ?? 0) + 1
        guard
            let delay = PreviewReask.delay(
                untilExpiry: untilExpiry, tries: tries, jitter: jitter())
        else {
            // A verdict. Re-asked only by a priming pass once it has genuinely expired, which is
            // what `dropIfExpired` is for.
            retry[url] = nil
            return
        }
        retry[url] = (at: now().addingTimeInterval(delay), tries: tries)
    }

    /// Drop the "already asked" mark once the server's stated TTL has lapsed, so the next
    /// priming pass asks again.
    ///
    /// ⚠ Neither the cached value nor the backoff ladder is discarded — see `retry`.
    private func dropIfExpired(_ url: String) {
        guard let expiry = cache[url]?.expiry, expiry <= now() else { return }
        asked.remove(url)
    }

    /// Re-queue everything whose re-ask has come due. Returns WHICH URLs were queued — empty
    /// when nothing was due.
    ///
    /// ⚠ The set rather than a bool because `onUpdate` carries it now: a re-ask puts a URL back
    /// in play, which un-settles its message's gate, and a consumer deciding whether that touches
    /// anything on screen needs to know which message.
    ///
    /// Internal rather than private so a test can drive it directly: the decision is the part
    /// worth asserting, and reaching it through `reaskTask` would mean sleeping out a real
    /// backoff to see it.
    @discardableResult
    func runDueReasks() -> Set<String> {
        let moment = now()
        var queued: Set<String> = []
        for (url, state) in retry where state.at <= moment {
            // Parked as in-flight rather than deleted, and the difference IS the backoff: the
            // `tries` count lives in this entry, so removing it re-armed at tries = 1 every time
            // and the floor never doubled — a "backoff" that was a flat 15-second poll.
            // Whatever comes back re-arms it, or clears it on an `ok`.
            retry[url] = (at: .distantFuture, tries: state.tries)
            // Marked `asked` as well as queued, for state consistency rather than as a guard:
            // the URL genuinely has been asked about, and that is what the set means.
            //
            // ⚠ It does NOT carry the duplicate-resolve protection, and the drill says so — the
            // parked `.distantFuture` deadline above is what `request()` rejects, so removing
            // this line reddens nothing. Left in because a set called `asked` that excludes a
            // request currently in flight is a trap for the next reader, not because it defends
            // anything today.
            asked.insert(url)
            enqueue(url)
            queued.insert(url)
        }
        if !queued.isEmpty { scheduleFlush() }
        return queued
    }

    /// One task for the whole map, set to the earliest deadline — not a task per URL.
    private func scheduleReask() {
        reaskTask?.cancel()
        reaskTask = nil
        guard let earliest = retry.values.map(\.at).min(), earliest != .distantFuture else {
            return
        }
        let delay = max(0, earliest.timeIntervalSince(now()))
        reaskTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reaskTask = nil
            let requeued = self.runDueReasks()
            if !requeued.isEmpty { self.onUpdate?(requeued) }
            self.scheduleReask()
        }
    }

    // MARK: - Is an answer still coming?

    /// Whether an answer is still expected for `url`.
    ///
    /// ⚠⚠ FAILS OPEN in every branch, deliberately. Its consumer withholds a whole message's
    /// attachment block while this answers true, so every "not sure" turns a partial failure
    /// into a blank message — strictly worse than the layout shift the gate exists to prevent.
    /// Only a request actively in flight counts as pending:
    ///
    ///   - carries a value       → settled, whatever the value says
    ///   - nobody ever asked     → settled. A URL nothing primed must render as nothing NOW
    ///                             rather than stall its message forever.
    ///   - waiting on a re-ask   → SETTLED, and this is the branch that matters most. Counting
    ///                             it as pending hid the block for the whole 15s→5min ladder,
    ///                             and indefinitely while a server kept failing: one 502 during
    ///                             a deploy would blank the attachments of every message sharing
    ///                             a batch with it, resolved siblings included.
    ///   - queued or in flight   → pending.
    public func isPending(_ url: String) -> Bool {
        if cache[url] != nil { return false }
        // Before the `pending`/`asked` test, not after: `runDueReasks` re-queues a URL it is
        // retrying, so the retry state has to win or a recovery attempt would re-hide a block
        // that is already on screen.
        if retry[url] != nil { return false }
        return pending.contains(url) || asked.contains(url)
    }

    /// Whether every URL in a message has settled — the atomic-reveal gate.
    ///
    /// ⚠⚠ ASKED, never timed. The first version of this revealed on a 1500ms deadline, on the
    /// reasoning that a message's URLs all land together "~24ms after ingest" — which was
    /// `coalesceDelay`, the debounce before the POST is sent, mistaken for the round trip. The
    /// server allows 10s of queue plus a 30s resolve deadline PER URL, so the timer fired
    /// routinely on any cold link and revealed a partial set, re-creating the exact arrangement
    /// flip the gate exists to remove.
    public func allSettled(_ urls: [String]) -> Bool {
        !urls.contains { isPending($0) }
    }

    /// Drop everything. For sign-out, and for tests.
    public func reset() {
        cache.removeAll()
        asked.removeAll()
        pending.removeAll()
        pendingOrder.removeAll()
        retry.removeAll()
        // ⚠⚠ Bumped, not just cancelled. A flush suspended at `await resolve` resumes whatever
        // the handle says, and this is what tells it the store it is about to write into is no
        // longer the store it read from.
        flushGeneration &+= 1
        flushTask?.cancel()
        flushTask = nil
        reaskTask?.cancel()
        reaskTask = nil
    }
}

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
    public var onUpdate: (() -> Void)?

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
        asked.insert(url)
        pending.insert(url)
        scheduleFlush()
    }

    public func request(_ urls: [String]) {
        for url in urls { request(url) }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            // ⚠ `try?` swallows the cancellation error, so a cancelled task RESUMES here.
            // Without this guard it would clear `flushTask` — clobbering the handle of any
            // newer task scheduled since the reset — and then flush with no coalescing window,
            // leaving two flushes racing.
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        let urls = Array(pending)
        pending.removeAll()
        guard !urls.isEmpty else { return }

        let batches = stride(from: 0, to: urls.count, by: Self.maxBatch).map {
            Array(urls[$0..<min($0 + Self.maxBatch, urls.count)])
        }
        for (index, chunk) in batches.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.interBatchDelay) }
            let previews = await resolve(chunk)

            var answered = Set<String>()
            for preview in previews {
                cache[preview.url] = preview
                answered.insert(preview.url)
                if preview.status == .ok {
                    retry[preview.url] = nil
                } else {
                    armReask(preview.url, expiry: preview.expiry)
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
        }

        // ⚠⚠ UNCONDITIONAL, where this used to fire only if a value landed. Every path above can
        // move a URL out of the pending set, and once the reveal gate exists, ANY such move can
        // complete a message's block and paint it — an `unavailable` very often is the answer
        // that finishes a gate, and so is a URL the server never mentioned. Bumping only on a
        // stored value left those blocks hidden until something unrelated redrew the table.
        scheduleReask()
        onUpdate?()
    }

    // MARK: - Coming back to an answer that wasn't one

    /// Arm (or clear) the re-ask for a URL the server did not answer usefully.
    ///
    /// `expiry` nil means nothing was stated, which is what a transport failure produces — the
    /// backoff floor alone then decides.
    private func armReask(_ url: String, expiry: Date?) {
        let untilExpiry = expiry.map { $0.timeIntervalSince(now()) } ?? 0
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

    /// Put a URL back in play after an answer that wasn't one.
    ///
    /// ⚠ The cached VALUE is deliberately left alone where one exists — a stale card that is
    /// merely due a refresh keeps rendering rather than blanking. What changes is `asked`, which
    /// re-opens the URL to priming.
    private func forgetForRetry(_ url: String) {
        asked.remove(url)
        armReask(url, expiry: nil)
    }

    /// Drop the "already asked" mark once the server's stated TTL has lapsed, so the next
    /// priming pass asks again.
    ///
    /// ⚠ Neither the cached value nor the backoff ladder is discarded — see `retry`.
    private func dropIfExpired(_ url: String) {
        guard let expiry = cache[url]?.expiry, expiry <= now() else { return }
        asked.remove(url)
    }

    /// Re-queue everything whose re-ask has come due. Returns whether anything was queued.
    ///
    /// Internal rather than private so a test can drive it directly: the decision is the part
    /// worth asserting, and reaching it through `reaskTask` would mean sleeping out a real
    /// backoff to see it.
    @discardableResult
    func runDueReasks() -> Bool {
        let moment = now()
        var queued = false
        for (url, state) in retry where state.at <= moment {
            // Parked as in-flight rather than deleted, and the difference IS the backoff: the
            // `tries` count lives in this entry, so removing it re-armed at tries = 1 every time
            // and the floor never doubled — a "backoff" that was a flat 15-second poll.
            // Whatever comes back re-arms it, or clears it on an `ok`.
            retry[url] = (at: .distantFuture, tries: state.tries)
            // Queued directly rather than through the `asked` gate: this URL is deliberately
            // being asked about a second time.
            pending.insert(url)
            queued = true
        }
        if queued { scheduleFlush() }
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
            if self.runDueReasks() { self.onUpdate?() }
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
        retry.removeAll()
        flushTask?.cancel()
        flushTask = nil
        reaskTask?.cancel()
        reaskTask = nil
    }
}

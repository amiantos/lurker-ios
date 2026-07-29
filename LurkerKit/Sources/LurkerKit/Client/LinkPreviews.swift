// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

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

    private var cache: [String: LinkPreview] = [:]
    /// URLs already asked about — whether or not an answer arrived. Prevents a URL that
    /// resolved to `unavailable`, or whose request failed, from being re-requested on every
    /// single redraw of the row it's in.
    private var asked = Set<String>()
    private var pending = Set<String>()
    private var flushTask: Task<Void, Never>?

    /// Called when previews arrive, so the list can re-lay-out the rows that now have one.
    /// The list reloads rather than mutating a cell, because a preview changes a row's height.
    public var onUpdate: (() -> Void)?

    private let resolve: ([String]) async -> [LinkPreview]

    public init(resolve: @escaping ([String]) async -> [LinkPreview]) {
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
            guard let self else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        let urls = Array(pending)
        pending.removeAll()
        guard !urls.isEmpty else { return }

        var changed = false
        for chunk in stride(from: 0, to: urls.count, by: Self.maxBatch).map({
            Array(urls[$0..<min($0 + Self.maxBatch, urls.count)])
        }) {
            let previews = await resolve(chunk)
            for preview in previews {
                cache[preview.url] = preview
                changed = true
            }
            // A URL that came back with nothing stays in `asked`, so a failed request isn't
            // retried on every redraw. It'll be retried next launch, which is the right
            // cadence for something the server itself negative-caches for an hour.
        }
        if changed { onUpdate?() }
    }

    /// Drop everything. For sign-out, and for tests.
    public func reset() {
        cache.removeAll()
        asked.removeAll()
        pending.removeAll()
        flushTask?.cancel()
        flushTask = nil
    }
}

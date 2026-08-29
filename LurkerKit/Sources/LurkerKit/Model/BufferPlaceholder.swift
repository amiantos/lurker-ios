// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// What the chat message list shows *instead of* messages when it has none — the
/// difference between "still fetching, sit tight" and "there is genuinely nothing here",
/// which a bare blank list conflates into "the app is broken".
///
/// This is about a single buffer's content, orthogonal to `ConnectionBannerState`, which
/// is about the connection. The two coexist: an offline phone opening an unread channel
/// shows the loading spinner (we'll fill it once we can) *and* the offline banner (why it
/// hasn't yet).
public enum BufferPlaceholder: Equatable, Sendable {
    /// Messages are showing — no placeholder.
    case none
    /// History is still on its way: the socket isn't up yet, or an on-demand buffer's
    /// hydrate reply hasn't landed.
    case loading
    /// The server has told us this buffer's history, and it's empty. A real state — a
    /// channel you just joined, a DM with no messages yet — not a failure.
    case empty

    /// Resolve the placeholder for a buffer.
    ///
    /// - `hasMessages`: any renderable line is already on screen.
    /// - `hydrated`: the server has read this buffer's history (see `Buffer.hydrated`).
    /// - `hydratesOnDemand`: channels/DMs read history in reply to their own hydrate;
    ///   system/server buffers get theirs in the connect backlog (see
    ///   `BufferKind.hydratesOnDemand`).
    /// - `bufferExists`: the buffer's row is present in the store — i.e. some frame has
    ///   materialized it.
    ///
    /// The two kinds wait on different signals, so they read different fields:
    ///
    ///  - **On-demand (channel/DM)** rows arrive as *shells* before their history — the row
    ///    exists while `hydrated` is still false — so only `hydrated` tells them apart from
    ///    a loaded-but-empty buffer.
    ///  - **Off-demand (system/server)** rows are created *by* their connect backlog and
    ///    nothing else on a fresh connect, so the row's mere existence means the history has
    ///    landed. They can't key off `hydrated`: the socket reports `.connected` before that
    ///    backlog is applied (so a `connection`-keyed rule flashes `.empty` on the launch
    ///    screen in the gap), and an *empty* `:server:` backlog never sets `hydrated` at all
    ///    — the server omits `hasMoreOlder` there and the parser defaults it true, and
    ///    `:server:` can't hydrate on demand to correct it, so a `hydrated`-keyed rule would
    ///    strand it on the spinner forever.
    public static func of(
        hasMessages: Bool,
        hydrated: Bool,
        hydratesOnDemand: Bool,
        bufferExists: Bool,
        rosterSettled: Bool = false
    ) -> BufferPlaceholder {
        if hasMessages { return .none }
        return historyLanded(
            hydrated: hydrated,
            hydratesOnDemand: hydratesOnDemand,
            bufferExists: bufferExists,
            rosterSettled: rosterSettled
        ) ? .empty : .loading
    }

    /// Whether the server has told us this buffer's history — the rule spelled out above, split
    /// out because the placeholder isn't the only decision that rests on it. The unread banner's
    /// `dividerSeen` latch asks the same question (has the reader been shown the buffer's real
    /// history, or a stub that outran it?), and asking it as a bare `hydrated` strands the
    /// off-demand kinds on the wrong answer forever in both places.
    /// `rosterSettled` — the connect burst has finished (`ChatState.rosterSettled`). It only
    /// matters to the off-demand kinds, and only when their row never arrived.
    ///
    /// ⚠⚠ Without it, an off-demand buffer with no row waits forever. That used to be
    /// unreachable: the only way to *open* a server log was to tap a row, and the row existed
    /// only if the store had one. The buffer list now offers a network's log whether or not a
    /// row has arrived — the web always has, its network header being that buffer — so
    /// "no row" is now a thing a reader can be looking at, and `bufferExists` alone would
    /// park them on a spinner that nothing can ever resolve, because a server buffer can't
    /// hydrate on demand to correct it.
    ///
    /// Gated on the burst being *finished*, not on `backlogComplete` alone: that flag latches
    /// true and stays true, so mid-resync it would answer "empty" for a buffer whose row is
    /// still on its way.
    public static func historyLanded(
        hydrated: Bool,
        hydratesOnDemand: Bool,
        bufferExists: Bool,
        rosterSettled: Bool = false
    ) -> Bool {
        hydratesOnDemand ? hydrated : (bufferExists || rosterSettled)
    }
}

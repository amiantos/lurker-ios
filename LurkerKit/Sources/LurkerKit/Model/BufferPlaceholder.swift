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
    /// `open-buffer` reply hasn't landed.
    case loading
    /// The server has told us this buffer's history, and it's empty. A real state — a
    /// channel you just joined, a DM with no messages yet — not a failure.
    case empty

    /// Resolve the placeholder for a buffer.
    ///
    /// - `hasMessages`: any renderable line is already on screen.
    /// - `hydrated`: the server has read this buffer's history (see `Buffer.hydrated`).
    /// - `hydratesOnDemand`: channels/DMs read history in reply to `open-buffer`;
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
        bufferExists: Bool
    ) -> BufferPlaceholder {
        if hasMessages { return .none }
        let historyLanded = hydratesOnDemand ? hydrated : bufferExists
        return historyLanded ? .empty : .loading
    }
}

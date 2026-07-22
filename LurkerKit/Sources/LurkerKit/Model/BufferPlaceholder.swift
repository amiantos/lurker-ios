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
    /// - `connection`: the live socket, which is what an off-demand buffer waits on.
    public static func of(
        hasMessages: Bool,
        hydrated: Bool,
        hydratesOnDemand: Bool,
        connection: SocketStatus
    ) -> BufferPlaceholder {
        if hasMessages { return .none }
        // Channel/DM: loading until the server has read the history we asked for.
        if hydratesOnDemand { return hydrated ? .empty : .loading }
        // System/server: their history rides the connect backlog, so "loading" is really
        // "the socket isn't up yet". Once it is and there's still nothing, it's empty.
        return connection == .connected ? .empty : .loading
    }
}

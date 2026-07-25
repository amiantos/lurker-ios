// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// What the buffer list shows *instead of* buffers when it has none — the difference between
/// "the roster is still arriving" and "you have no networks yet", which a bare blank list
/// conflates into "the app is broken". The counterpart to `BufferPlaceholder`, which does the
/// same job one level down for a single buffer's messages.
///
/// Like that type, this is about *content* and is orthogonal to `ConnectionBannerState`, which
/// is about the connection. The two coexist and answer different questions: the placeholder
/// says what's in the list, the banner says why the connection can't fill it.
public enum BufferListPlaceholder: Equatable, Sendable {
    /// There are buffers to show — no placeholder.
    case none
    /// The snapshot hasn't landed yet, so we don't know what's there.
    case loading
    /// The server has answered and there's nothing on the account: no networks configured, or
    /// none with an open buffer. A real state — a fresh account — not a failure, and the one
    /// place the app should be pointing at "add a network".
    case empty

    /// Resolve the placeholder for the buffer list.
    ///
    /// - `hasBuffers`: at least one row is already on screen.
    /// - `snapshotLoaded`: a `snapshot` has landed this session (see `ChatState`).
    ///
    /// Deliberately *not* keyed on `connection`. The socket reports `.connected` before the
    /// snapshot is applied, so a connection-keyed rule flashes "no networks" in that gap — and
    /// on a reconnect it would blank a list that still has perfectly good content. Whether the
    /// connection is healthy is the banner's question, not this one's.
    public static func of(hasBuffers: Bool, snapshotLoaded: Bool) -> BufferListPlaceholder {
        if hasBuffers { return .none }
        return snapshotLoaded ? .empty : .loading
    }
}

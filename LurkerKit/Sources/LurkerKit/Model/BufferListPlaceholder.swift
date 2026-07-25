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
    /// The snapshot burst hasn't finished, so we don't yet know what's there.
    case loading
    /// A fresh account: nothing configured at all. The one place the app should be pointing
    /// at "add a network".
    case noNetworks
    /// Networks exist but none of them has a buffer to show — every one is disconnected, or
    /// connected with nothing joined. Distinct from `noNetworks` because telling someone to
    /// add a network they've already added reads as the app not knowing its own state.
    case noBuffers

    /// Resolve the placeholder for the buffer list.
    ///
    /// - `hasBuffers`: at least one row is already on screen.
    /// - `hasNetworks`: the account has at least one network configured.
    /// - `backlogComplete`: a snapshot burst has finished this session (see `ChatState`).
    ///
    /// Deliberately *not* keyed on `connection`, and not on the `snapshot` frame either —
    /// see `ChatState.backlogComplete` for why both of those flash the empty state on
    /// accounts where they happen to be wrong.
    public static func of(
        hasBuffers: Bool, hasNetworks: Bool, backlogComplete: Bool
    ) -> BufferListPlaceholder {
        if hasBuffers { return .none }
        guard backlogComplete else { return .loading }
        return hasNetworks ? .noBuffers : .noNetworks
    }
}

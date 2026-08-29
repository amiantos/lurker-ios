// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// An IRC network the account is configured on, as the app *renders* it: the roster's
/// name plus whatever the socket last said about the connection. The editable
/// configuration behind it — host, port, credentials — is `NetworkConfig`, fetched on
/// demand; this one is read on the hot path of every frame the store reduces.
///
/// `name` comes from REST (`GET /api/networks`); the live `state`/`nick` come from the WS
/// `snapshot` and the `state` event, and are merged in — neither carries a name.
public struct Network: Equatable, Sendable {
    public let id: Int
    /// The roster's name for this network, or nil when we haven't heard it yet.
    ///
    /// ⚠⚠ Optional rather than a placeholder string, and that is the whole of #136. The
    /// snapshot can name a network the roster doesn't hold — a failed roster fetch, or a
    /// network added from another client mid-session — and the row it materialized used the
    /// literal `"network"`, which is indistinguishable from a real name by anything
    /// downstream. So the app said "network" where a name belonged and no code could tell
    /// it was lying. Nil is the honest reading, and it's what triggers the roster re-read
    /// (`ChatViewModel.refreshRosterIfAnyNetworkIsNameless`).
    public var name: String?
    public var state: ConnectionState
    public var nick: String
    /// Your own away state, as this network last reported it (#68).
    ///
    /// Held per network because that's how the server broadcasts it, though the state itself
    /// is user-scoped — every connected network carries the same value. Nil means the server
    /// hasn't reported one, which is also what it sends for a user who has never been away.
    public var away: AwayState?

    public init(
        id: Int,
        name: String?,
        state: ConnectionState = .disconnected,
        nick: String = "",
        away: AwayState? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.nick = nick
        self.away = away
    }

    /// What to call this network wherever the user sees one named.
    ///
    /// Shared so the fallback can't drift between the join menu, the networks screen and
    /// anything later: an unnamed network is a transient state (the re-fetch closes it) but
    /// it still has to render as *something*, and every site inventing its own word is how
    /// #136's placeholder got mistaken for a name in the first place.
    public var displayName: String { name ?? "Unnamed network" }
}

/// Mirrors the server's per-network `state` string.
public enum ConnectionState: String, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected

    public static func from(_ raw: String?) -> ConnectionState {
        switch raw {
        case "connecting": return .connecting
        case "connected": return .connected
        case "reconnecting": return .reconnecting
        default: return .disconnected
        }
    }
}

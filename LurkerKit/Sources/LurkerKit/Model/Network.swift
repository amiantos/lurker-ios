// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// An IRC network the account is configured on. `name` comes from REST
/// (`GET /api/networks`); the live `state`/`nick` come from the WS `snapshot` and
/// are merged in — the snapshot itself carries no name.
public struct Network: Equatable, Sendable {
    public let id: Int
    public var name: String
    public var state: ConnectionState
    public var nick: String

    public init(
        id: Int,
        name: String,
        state: ConnectionState = .disconnected,
        nick: String = ""
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.nick = nick
    }
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

// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A channel member. `modes` are prefix-mode letters (q a o h v), highest first —
/// NOT the sigil symbols (~ & @ % +). Matches the server's ChannelMember.
public struct Member: Equatable, Sendable {
    public let nick: String
    public let modes: [String]
    public let away: Bool
    public let user: String?
    public let host: String?

    public init(
        nick: String,
        modes: [String] = [],
        away: Bool = false,
        user: String? = nil,
        host: String? = nil
    ) {
        self.nick = nick
        self.modes = modes
        self.away = away
        self.user = user
        self.host = host
    }
}

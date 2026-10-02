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

    /// This member's `nick!user@host`, when the server sent both halves — the form an ignore
    /// rule's mask is matched against.
    ///
    /// Nil unless both are present: a half-mask would be matched against a rule's `user` and
    /// `host` globs as if the missing half were empty, quietly failing a rule that would have
    /// matched. Absent is the honest answer, and the matcher already knows what to do with it.
    /// Same rule the web applies inline in its nicklist filter (`MemberList.vue:173`).
    public var userhost: String? {
        guard let user, let host, !user.isEmpty, !host.isEmpty else { return nil }
        return "\(nick)!\(user)@\(host)"
    }
}

extension Array where Element == Member {
    /// The entry for `nick`, folding case — the one place "which of these is me?" is asked
    /// (`ChatState.channelAccess`, the composer's prompt). Nil for an empty nick, and before
    /// NAMES lands.
    ///
    /// Cheap enough to run on every state frame: the length check (O(1) on a native string)
    /// turns away almost every member before the fold allocates. Lowercasing never changes an
    /// ASCII nick's length, and IRC casemapping is ASCII.
    public func member(named nick: String) -> Member? {
        guard !nick.isEmpty else { return nil }
        let folded = nick.lowercased()
        let length = folded.utf8.count
        return first { $0.nick.utf8.count == length && $0.nick.lowercased() == folded }
    }
}

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
    /// Runs on every state frame (the composer's prompt), so the exact spelling is tried first:
    /// the server lists us as it knows us, which is how `Network.nick` has it too, and that
    /// match costs no allocation. The fold is the fallback, not the path.
    ///
    /// ⚠ No length shortcut in front of the fold. Lowercasing can change a nick's UTF-8 length
    /// (`İ` is two bytes, its fold three), so one would turn away the very member it's looking for.
    public func member(named nick: String) -> Member? {
        guard !nick.isEmpty else { return nil }
        if let exact = first(where: { $0.nick == nick }) { return exact }
        let folded = nick.lowercased()
        return first { $0.nick.lowercased() == folded }
    }
}

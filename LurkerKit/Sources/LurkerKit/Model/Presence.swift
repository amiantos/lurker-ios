// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Your *own* away state — the self half of this file's subject, where `PresenceState` below
/// is the peer half.
///
/// User-scoped rather than network-scoped (`/away` hits every connection, see lurker's
/// `user_away_state`), but broadcast per network, so each network carries an identical copy
/// and reading any one of them reads the user's state.
///
/// `since` and `message` deliberately survive `/back` — the completed away→back pair is what
/// the message-list dividers render, so clearing them on return would erase the marker at
/// the moment it becomes drawable.
public struct AwayState: Equatable, Sendable {
    /// Whether the user is away *right now*. Note this is not `backAt == nil`: the server
    /// keeps both, and a client that inferred one from the other would get the window
    /// between a re-`/away` and its broadcast wrong.
    public let active: Bool
    /// The away reason, if one was given.
    public let message: String?
    /// When the current (or most recent) away began.
    ///
    /// Not optional, because an away with no beginning is not a state this client can do
    /// anything with — both markers are placed from it — and the server treats it as the
    /// existence test too, sending `away: null` outright when there's no `since`. `FrameParser`
    /// refuses a blob it can't read one out of, so the two agree.
    public let since: Date
    /// Whether the server set this from idle rather than the user typing `/away`.
    public let autoSet: Bool
    /// When the user came back, or nil while still away.
    public let backAt: Date?

    public init(
        active: Bool,
        message: String? = nil,
        since: Date,
        autoSet: Bool = false,
        backAt: Date? = nil
    ) {
        self.active = active
        self.message = message
        self.since = since
        self.autoSet = autoSet
        self.backAt = backAt
    }
}

/// The raw peer-presence state the server reports for a watched nick, over the MONITOR rails.
/// One transition at a time: `back` is the AFK-cleared counterpart of `away` and reads as
/// online. Fed by the connect snapshot's `peerPresence` blob and live `peer-presence` events.
public enum PresenceState: String, Equatable, Sendable {
    case online
    case offline
    case away
    case back
}

/// The derived, disconnected-aware status a friend row shows. `unknown` is a real state, not
/// an error: a network with no MONITOR support (or a peer we share no channel with) simply
/// can't be resolved, and "potentially online" is the honest reading — distinct from a known
/// `offline`.
public enum FriendPresence: Equatable, Sendable {
    case online
    case away
    case offline
    case unknown
}

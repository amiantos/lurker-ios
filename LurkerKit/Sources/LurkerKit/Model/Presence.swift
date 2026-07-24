// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

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

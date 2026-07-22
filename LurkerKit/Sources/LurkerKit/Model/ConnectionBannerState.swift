// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// The connection banner shown across the top of the chat screen — the loud, worded
/// counterpart to the title pill's `StatusLight` dot. The dot is always-on ambient; this
/// only appears when something is wrong, and says so in words a glance can read.
///
/// It keys off the same two truths the dot's outer layers do — the OS network path and the
/// Lurker socket — and in the same order: no path beats everything, because it's the one
/// failure the user can act on and the socket's own state is meaningless underneath it.
/// The IRC network layer is deliberately absent: a single disconnected network is the
/// title dot's job, not a screen-wide banner claiming the whole app is offline.
public enum ConnectionBannerState: Equatable, Sendable {
    /// Connected and reachable — the banner is gone.
    case hidden
    /// The first connect of the session hasn't landed yet (launch, or a fresh sign-in).
    case connecting
    /// The socket dropped and we're backing off toward it — reachable, so it's ours to fix.
    case reconnecting
    /// No network path at all. Nothing else can be true, and it's the user's to fix.
    case offline

    /// Resolve the banner from the device path and the live socket.
    ///
    /// `reachable` is checked first for the same reason `StatusLight` checks it first: the
    /// socket can only ever report connecting/connected/reconnecting, so a stale
    /// `.reconnecting` under a dead path would otherwise read as "we're on it" when the
    /// honest message is "you have no internet".
    public static func of(reachable: Bool, connection: SocketStatus) -> ConnectionBannerState {
        guard reachable else { return .offline }
        switch connection {
        case .connected: return .hidden
        case .connecting: return .connecting
        case .reconnecting: return .reconnecting
        }
    }

    /// Whether this state is one we're actively working on (so the view spins). Offline is
    /// not — there's nothing to spin about until the user brings a path back.
    public var isWorking: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        case .hidden, .offline: return false
        }
    }
}

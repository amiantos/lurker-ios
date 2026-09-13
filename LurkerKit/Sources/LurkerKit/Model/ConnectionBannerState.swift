// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// The connection banner shown across the top of the chat screen — the loud, worded
/// counterpart to the title pill's `StatusLight` dot. The dot is always-on ambient; this
/// only appears when something is wrong, and says so in words a glance can read.
///
/// It keys off the same two truths the dot's outer layers do — the OS network path and the
/// Lurker socket — and in the same order: no path beats everything, because it's the one
/// failure the user can act on and the socket's own state is meaningless underneath it.
/// The exception is a server that can't take this build (#17), which outranks even that.
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
    /// The server and this build can't talk (#17). Nothing is retrying, and one side needs
    /// an update.
    case incompatible(Incompatibility)

    /// Resolve the banner from the device path and the live socket.
    ///
    /// `reachable` is checked before the socket's progress for the same reason `StatusLight`
    /// checks it first: the socket has no way to report "no internet", so a stale
    /// `.reconnecting` under a dead path would otherwise read as "we're on it" when the
    /// honest message is "you have no internet".
    ///
    /// An incompatible server comes before both. The app learned that from the server rather
    /// than guessing it from a dead path, and coming back online won't change it.
    public static func of(reachable: Bool, connection: SocketStatus) -> ConnectionBannerState {
        switch connection {
        case .incompatible(let incompatibility): return .incompatible(incompatibility)
        case _ where !reachable: return .offline
        case .connected: return .hidden
        case .connecting: return .connecting
        case .reconnecting: return .reconnecting
        }
    }

    /// Whether this state is one we're actively working on (so the view spins). Offline is
    /// not — there's nothing to spin about until the user brings a path back — and neither is
    /// an incompatible server, which nothing retries.
    public var isWorking: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        case .hidden, .offline, .incompatible: return false
        }
    }
}
